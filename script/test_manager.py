"""Regression tests run without root, real panel credentials or service mutations."""
import copy
import base64
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import socket
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("manager", Path(__file__).with_name("v2node-manager.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def route(domain="a.example.com", port=10001, path="/a", node_id=1):
    return {"ApiHost": "https://panel.example.com", "NodeID": node_id, "domain": domain,
            "path": path, "port": port, "tls": "self-signed", "nginx_dir": "/etc/nginx/conf.d",
            "cert": "/etc/v2node/proxy-certs/" + domain + ".cer", "key": "/etc/v2node/proxy-certs/" + domain + ".key"}


def panel_info(r):
    return {"protocol": "trojan", "network": "ws", "network_settings": {"path": r["path"]},
            "listen_ip": "127.0.0.1", "server_port": r["port"], "tls": 1,
            "tls_settings": {"terminate_tls_at_proxy": "1", "server_name": r["domain"], "cert_mode": "file",
                             "cert_file": r["cert"], "key_file": r["key"]},
            "base_config": {"certificate_report": True, "certificate_revision": "revision"}}


class ValidationTests(unittest.TestCase):
    def test_multi_domain_and_multi_path(self):
        a, b = route(), route("b.example.com", 10002, "/b", 2)
        c = route("b.example.com", 10003, "/c", 3)
        before = m.render(a["domain"], [a])
        self.assertEqual(before, m.render(a["domain"], [a, b, c]))
        rendered = m.render(b["domain"], [a, b, c])
        self.assertIn("location = /b", rendered)
        self.assertIn("location = /c", rendered)
        self.assertNotIn("a.example.com", rendered)
        self.assertIn("127.0.0.1:10002", rendered)
        self.assertIn("127.0.0.1:10003", rendered)
        self.assertIn("proxy_set_header Host $host", rendered)

    def test_domain_path_injection_rejected(self):
        for field, values in {"domain": ["x;server", "-a.example.com", "a..example.com", "https://a.com", "x\n.com"],
                              "path": ["/", "/x;}", "/../secret", "/x/..", "/a//b", "/a?b"],
                              "port": [0, 443, 65536]}.items():
            for value in values:
                r = route()
                r[field] = value
                with self.subTest(field=field, value=value), self.assertRaises(m.Error):
                    m.validate_route(r)

    def test_validate_panel_all_ws_protocols(self):
        for protocol in ("vmess", "vless", "trojan"):
            info = panel_info(route())
            info["protocol"] = protocol
            self.assertEqual([], m.panel_errors(info, route()))

    def test_proxy_tls_plaintext_backend_mismatch(self):
        info = panel_info(route())
        info["tls_settings"]["terminate_tls_at_proxy"] = "0"
        info["listen_ip"] = "0.0.0.0"
        info["server_port"] = 443
        info["network_settings"]["path"] = "/wrong"
        self.assertEqual(4, len(m.panel_errors(info, route())))

    def test_detect_baota_include(self):
        dump = 'http {\n include /www/server/panel/vhost/nginx/*.conf;\n}\n'
        self.assertEqual(Path("/www/server/panel/vhost/nginx"), m.discover_nginx_dir(dump))
        with self.assertRaises(m.Error):
            m.discover_nginx_dir(dump, "/etc/nginx/conf.d")

    def test_nginx_missing_include_fails(self):
        with self.assertRaises(m.Error):
            m.discover_nginx_dir("http {}")

    def test_backend_collision(self):
        with self.assertRaises(m.Error):
            m.assert_available(route("b.example.com", 10001, "/b", 2), [route()], None, "")

    def test_foreign_vhost_not_overwritten(self):
        dump = "# configuration file /etc/nginx/other.conf:\nserver_name a.example.com;\n"
        with self.assertRaises(m.Error):
            m.assert_available(route(), [], None, dump)

    def test_invalid_api_urls(self):
        for value in ("http://panel.com", "https://user:secret@panel.com", "https://panel.com?token=x", "https://panel.com/admin"):
            with self.assertRaises(m.Error):
                m.validate_host(value)

    def test_secret_not_in_prompt(self):
        with patch.object(m.sys.stdin, "isatty", return_value=True), patch.object(m.getpass, "getpass", return_value="") as prompt:
            self.assertEqual("SECRET", m.ask(None, "API key", "SECRET", secret=True))
            self.assertNotIn("SECRET", prompt.call_args[0][0])

    def test_https_redirect_not_followed(self):
        self.assertIsNone(m.NoRedirect().redirect_request(None, None, 302, "", {}, "https://attacker.example"))

    def test_legacy_import_rejects_custom_directives(self):
        # Construct the legacy generator's output using its documented directives.
        r = route()
        text = m.render(r["domain"], [r])
        text = text.replace(m.MARKER, "# Managed by v2nodePro setup-wss-proxy.sh")
        text = text.replace("    listen 443 ssl;", "    listen 443 ssl;\n    listen [::]:443 ssl;")
        # render() can already emit IPv6 on Linux.
        text = text.replace("    listen [::]:443 ssl;\n    listen [::]:443 ssl;", "    listen [::]:443 ssl;")
        text = text.replace('"', '')  # Restore the legacy unquoted certificate paths.
        text = text.replace("Connection upgrade;", 'Connection "upgrade";')
        text = text.replace("shared:V2NODE_MANAGER", "shared:V2NODE_WSS")
        imported = m.legacy_routes(text, "legacy.conf")
        self.assertEqual(("a.example.com", "/a", 10001), (imported[0]["domain"], imported[0]["path"], imported[0]["port"]))
        with self.assertRaises(m.Error):
            m.legacy_routes(text.replace("return 404;", "return 403;"), "legacy.conf")


class FilesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.patches = []
        paths = {"CONFIG": "etc/v2node/config.json", "STATE": "etc/v2node/manager.json", "CERTS": "etc/v2node/proxy-certs",
                 "BACKUPS": "backups", "BINARY": "usr/local/v2node/v2node", "UNIT": "etc/systemd/v2node.service",
                 "OPENRC": "etc/init.d/v2node", "TIMER": "etc/systemd/renew.timer", "RENEW_UNIT": "etc/systemd/renew.service",
                 "SYSCTL": "etc/sysctl.d/99.conf", "MANAGER": "usr/lib/manager.py", "LAUNCHER": "usr/bin/manager"}
        for key, value in paths.items():
            p = patch.object(m, key, self.root / value)
            self.patches.append(p)
            p.start()
        p = patch.object(m, "service", return_value=subprocess.CompletedProcess([], 0, b"", b""))
        self.patches.append(p)
        p.start()
        p = patch.object(m, "restore_service_state")
        self.patches.append(p)
        p.start()

    def tearDown(self):
        for p in reversed(self.patches):
            p.stop()
        self.temp.cleanup()

    def test_backup_restore_preserves_unrelated_files(self):
        m.write_json(m.CONFIG, {"Nodes": [], "custom": True})
        foreign = self.root / "foreign.conf"
        foreign.write_text("website")
        new_file = self.root / "new.conf"
        snapshot = m.backup({m.CONFIG, new_file})
        m.write_json(m.CONFIG, {"Nodes": ["modified"]})
        new_file.write_text("new")
        m.restore_files(snapshot)
        self.assertEqual({"Nodes": [], "custom": True}, m.read_json(m.CONFIG, {}))
        self.assertFalse(new_file.exists())
        self.assertEqual("website", foreign.read_text())

    def test_corrupted_backup_fails_before_writes(self):
        m.atomic(m.CONFIG, "original")
        snapshot = m.backup({m.CONFIG})
        (snapshot / "0").write_text("tampered")
        m.atomic(m.CONFIG, "current")
        with self.assertRaises(m.Error):
            m.restore_files(snapshot)
        self.assertEqual("current", m.CONFIG.read_text())

    def test_transaction_rolls_back_on_reload_failure(self):
        m.write_json(m.CONFIG, {"Nodes": [], "custom": True})
        with patch.object(m, "nginx_binary", side_effect=m.Error("none")):
            with self.assertRaises(m.Error):
                with m.transaction({m.CONFIG}):
                    m.write_json(m.CONFIG, {"Nodes": ["modified"]})
                    raise m.Error("nginx reload failed")
        self.assertEqual({"Nodes": [], "custom": True}, m.read_json(m.CONFIG, {}))

    def test_remove_one_route_preserves_other_path_and_domain(self):
        a = route()
        b = route("a.example.com", 10002, "/b", 2)
        c = route("c.example.com", 10003, "/c", 3)
        for r in (a, b, c):
            r["nginx_dir"] = str(self.root / "nginx")
        m.write_vhosts([], [a, b, c])
        other_before = m.vhost(c).read_bytes()
        m.write_vhosts([a, b, c], [b, c])
        self.assertNotIn("location = /a", m.vhost(b).read_text())
        self.assertIn("location = /b", m.vhost(b).read_text())
        self.assertEqual(other_before, m.vhost(c).read_bytes())

    def test_do_not_adopt_foreign_file(self):
        a = route()
        a["nginx_dir"] = str(self.root)
        m.vhost(a).write_text("server { # user config }")
        with self.assertRaises(m.Error):
            m.write_vhosts([], [a])
        self.assertEqual("server { # user config }", m.vhost(a).read_text())

    def test_add_preserves_other_nodes_and_config_options(self):
        existing = {"ApiHost": "https://other.example.com", "NodeID": 1, "ApiKey": "OTHER", "custom": "keep"}
        m.write_json(m.CONFIG, {"Nodes": [existing], "Log": {"Level": "warn"}, "PprofPort": 12345})
        m.atomic(m.BINARY, "fake")
        args = m.parser().parse_args(["add", "--api-host", "https://panel.example.com", "--node-id", "1", "--api-key", "SECRET",
                                     "--domain", "a.example.com", "--path", "/a", "--backend-port", "10001", "--yes"])
        with patch.object(m, "check_panel"), patch.object(m, "nginx_dump", return_value=""), \
                patch.object(m, "discover_nginx_dir", return_value=self.root / "nginx"), patch.object(m, "assert_available"), \
                patch.object(m, "new_certificate"), patch.object(m, "cert_validate"), patch.object(m, "nginx_apply"), \
                patch.object(m, "health"), patch.object(m, "install_manager"):
            m.add_node(args)
            m.add_node(args)  # Re-running must not duplicate the node or location.
        config = m.load_config()
        self.assertEqual(2, len(config["Nodes"]))
        self.assertEqual(existing, config["Nodes"][0])
        self.assertEqual(12345, config["PprofPort"])
        self.assertEqual({"Level": "warn"}, config["Log"])
        self.assertEqual(1, len(m.load_state()["routes"]))

    def test_dry_run_does_not_write_configuration(self):
        args = m.parser().parse_args(["add", "--api-host", "https://panel.example.com", "--node-id", "1", "--api-key", "SECRET",
                                     "--domain", "a.example.com", "--path", "/a", "--backend-port", "10001", "--dry-run"])
        with patch.object(m, "check_panel"), patch.object(m, "nginx_dump", return_value=""), \
                patch.object(m, "discover_nginx_dir", return_value=self.root / "nginx"), patch.object(m, "assert_available"):
            m.add_node(args)
        self.assertFalse(m.CONFIG.exists())
        self.assertFalse(m.STATE.exists())
        self.assertFalse(m.BACKUPS.exists())

    def test_checksum_failure_never_replaces_binary(self):
        args = m.parser().parse_args(["update"])
        m.atomic(m.BINARY, "old")
        def fake_download(url, destination):
            if url.endswith("/latest"):
                m.write_json(Path(destination), {"tag_name": "v1", "assets": [
                    {"name": "v2node-linux-64.zip", "browser_download_url": "https://example/zip"},
                    {"name": "v2node-linux-64.zip.sha256", "browser_download_url": "https://example/sha"}]})
            else:
                Path(destination).write_text("0" * 64 if url.endswith("sha") else "bad archive")
        with patch.object(m.platform, "machine", return_value="x86_64"), patch.object(m, "download", side_effect=fake_download):
            with self.assertRaises(m.Error):
                m.install_binary(args)
        self.assertEqual("old", m.BINARY.read_text())

    def test_install_places_both_geo_assets_next_to_binary_and_in_config_directory(self):
        payload = {}
        for name in ("v2node", "geoip.dat", "geosite.dat"):
            path = self.root / name
            path.write_bytes(("payload-" + name).encode())
            payload[name] = path
        with patch.object(m, "release_payload", return_value=(payload, {"tag": "v-test"})), \
                patch.object(m, "ensure_unit"), patch.object(m, "install_manager"):
            m.install_binary(m.parser().parse_args(["install"]))
        self.assertEqual(b"payload-v2node", m.BINARY.read_bytes())
        for name in ("geoip.dat", "geosite.dat"):
            self.assertEqual(("payload-" + name).encode(), (m.BINARY.parent / name).read_bytes())
            self.assertEqual(("payload-" + name).encode(), (m.CONFIG.parent / name).read_bytes())

    def test_list_json_has_no_credentials(self):
        m.write_json(m.CONFIG, {"Nodes": [{"ApiHost": "https://panel.example.com", "NodeID": 1, "ApiKey": "SECRET"}]})
        output = io.StringIO()
        with patch.object(m.sys, "stdout", output):
            m.list_nodes(m.parser().parse_args(["list", "--json"]))
        self.assertNotIn("SECRET", output.getvalue())
        self.assertNotIn("ApiKey", output.getvalue())

    @unittest.skipUnless(shutil.which("openssl"), "openssl required")
    def test_real_certificate_report_has_panel_compatible_spki(self):
        r = route()
        r["cert"], r["key"] = str(m.CERTS / "test.cer"), str(m.CERTS / "test.key")
        m.new_certificate(r)
        m.cert_validate(r)
        node = {"ApiHost": r["ApiHost"], "NodeID": r["NodeID"], "ApiKey": "secret"}
        captured = {}
        def panel(node, endpoint="config", payload=None):
            if endpoint == "config":
                return panel_info(r)
            captured.update(payload)
            return {"data": True}
        with patch.object(m, "panel", side_effect=panel):
            m.certificate_report(node, r)
        self.assertEqual(32, len(base64.b64decode(captured["tls_public_key_sha256"], validate=True)))
        self.assertRegex(captured["tls_certificate_sha256"], r"^[0-9a-f]{64}$")
        self.assertEqual("revision", captured["revision"])
        self.assertTrue(captured["tls_enabled"])

    def test_renew_failure_restores_cert_and_reports_old_pin_to_all_panels(self):
        a, b = route(), route("a.example.com", 10002, "/b", 2)
        for r in (a, b):
            r.update(cert=str(m.CERTS / "a.cer"), key=str(m.CERTS / "a.key"), nginx_dir=str(self.root / "nginx"))
        m.atomic(a["cert"], "old-cert")
        m.atomic(a["key"], "old-key")
        m.write_json(m.STATE, {"version": 1, "routes": [a, b]})
        m.write_json(m.CONFIG, {"Nodes": [dict(ApiHost=r["ApiHost"], NodeID=r["NodeID"], ApiKey="secret") for r in (a, b)]})
        reported = []
        def report(node, r):
            value = Path(r["cert"]).read_text()
            reported.append((node["NodeID"], value))
            if node["NodeID"] == 2 and value == "new-cert":
                raise m.Error("Panel HTTP 409")
        def new_cert(r):
            m.atomic(r["cert"], "new-cert")
            m.atomic(r["key"], "new-key")
        with patch.object(m, "check_panel"), patch.object(m, "cert_validate"), patch.object(m, "health"), \
                patch.object(m, "nginx_apply"), patch.object(m, "nginx_binary", return_value="nginx"), \
                patch.object(m, "new_certificate", side_effect=new_cert), patch.object(m, "certificate_report", side_effect=report):
            with self.assertRaises(m.Error):
                m.renew(m.parser().parse_args(["renew", "--force", "--yes"]))
        self.assertEqual("old-cert", Path(a["cert"]).read_text())
        self.assertEqual("old-key", Path(a["key"]).read_text())
        self.assertEqual([(1, "new-cert"), (2, "new-cert"), (1, "old-cert"), (2, "old-cert")], reported)


if __name__ == "__main__":
    unittest.main()
