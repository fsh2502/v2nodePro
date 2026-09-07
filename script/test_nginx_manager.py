"""Real TLS/SNI/WebSocket routing regression. Requires nginx and openssl on PATH.

Runs an isolated Nginx on an ephemeral localhost port. No root, system service,
panel credentials or /etc configuration is used. NGINX_BINARY can override PATH.
"""
import concurrent.futures
import hashlib
import http.server
import importlib.util
import os
from pathlib import Path
import shutil
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import unittest

spec = importlib.util.spec_from_file_location("manager", Path(__file__).with_name("v2node-manager.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
NGINX = os.environ.get("NGINX_BINARY") or shutil.which("nginx")
OPENSSL = os.environ.get("OPENSSL_BINARY") or shutil.which("openssl")


class Backend(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != self.server.ws_path or self.headers.get("Upgrade", "").lower() != "websocket":
            self.send_error(404)
            return
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
        self.send_header("X-Backend", self.server.label)
        self.end_headers()

    def log_message(self, *args):
        pass


@unittest.skipUnless(NGINX and OPENSSL, "nginx and openssl are required")
class RealNginxTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="v2node-nginx-")
        self.root = Path(self.temp.name)
        (self.root / "logs").mkdir()
        (self.root / "temp").mkdir()
        self.routes, self.servers = [], []
        self.proc = None
        self.addCleanup(self.cleanup)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            self.port = sock.getsockname()[1]
        for index, domain, path in ((1, "a.example.com", "/panel-a"), (2, "b.example.com", "/panel-b"),
                                    (3, "b.example.com", "/panel-c")):
            backend = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Backend)
            backend.daemon_threads = True
            backend.ws_path, backend.label = path, str(index)
            self.servers.append(backend)
            threading.Thread(target=backend.serve_forever, daemon=True).start()
            cert, key = self.root / (domain + ".cer"), self.root / (domain + ".key")
            if not cert.exists():
                self.command(OPENSSL, "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes", "-days", "1",
                             "-subj", "/CN=" + domain, "-addext", "subjectAltName=DNS:" + domain,
                             "-keyout", key, "-out", cert)
            self.routes.append({"ApiHost": "https://panel%s.example.com" % index, "NodeID": 1,
                                "domain": domain, "port": backend.server_port, "path": path, "tls": "self-signed",
                                "cert": cert.as_posix(), "key": key.as_posix(), "nginx_dir": self.root.as_posix()})
        self.write_config(self.routes)
        self.command(NGINX, "-p", self.root.as_posix() + "/", "-c", "nginx.conf", "-t")
        self.proc = subprocess.Popen([NGINX, "-p", self.root.as_posix() + "/", "-c", "nginx.conf",
                                      "-e", (self.root / "logs/error.log").as_posix()],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                     creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        for attempt in range(30):
            try:
                with socket.create_connection(("127.0.0.1", self.port), timeout=0.2):
                    return
            except OSError:
                time.sleep(0.1)
        self.fail("Isolated Nginx did not start")

    def cleanup(self):
        if (self.root / "logs/nginx.pid").exists():
            self.command(NGINX, "-p", self.root.as_posix() + "/", "-c", "nginx.conf", "-s", "quit")
        if self.proc:
            self.proc.wait(timeout=10)
        for server in self.servers:
            server.shutdown()
            server.server_close()
        time.sleep(0.2)
        self.temp.cleanup()

    def command(self, *args):
        if args[0] == NGINX:
            args = (*args, "-e", (self.root / "logs/error.log").as_posix())
        p = subprocess.run([str(x) for x in args], capture_output=True, timeout=20,
                           creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        self.assertEqual(0, p.returncode, p.stderr.decode(errors="replace"))
        return p

    def write_config(self, routes):
        rendered = []
        for domain in sorted({r["domain"] for r in routes}):
            text = m.render(domain, routes)
            text = text.replace("listen 443 ssl;", "listen 127.0.0.1:%s ssl;" % self.port)
            text = text.replace("    listen [::]:443 ssl;", "")
            rendered.append(text)
        config = """daemon off;
worker_processes 1;
pid logs/nginx.pid;
error_log logs/error.log;
events { worker_connections 256; }
http {
    access_log off;
    client_body_temp_path temp/client;
    proxy_temp_path temp/proxy;
    fastcgi_temp_path temp/fastcgi;
    uwsgi_temp_path temp/uwsgi;
    scgi_temp_path temp/scgi;
""" + "\n".join(rendered) + "\n}\n"
        (self.root / "nginx.conf").write_text(config, encoding="utf-8")

    def request(self, route, path=None, trust=None):
        context = ssl.create_default_context(cafile=trust or route["cert"])
        with socket.create_connection(("127.0.0.1", self.port), timeout=3) as raw:
            with context.wrap_socket(raw, server_hostname=route["domain"]) as conn:
                peer = hashlib.sha256(conn.getpeercert(binary_form=True)).hexdigest()
                der = ssl.PEM_cert_to_DER_cert(Path(route["cert"]).read_text())
                self.assertEqual(hashlib.sha256(der).hexdigest(), peer)
                conn.sendall(("GET %s HTTP/1.1\r\nHost: %s\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n"
                              "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n" %
                              (path or route["path"], route["domain"])).encode())
                result = b""
                while b"\r\n\r\n" not in result:
                    chunk = conn.recv(4096)
                    if not chunk:
                        break
                    result += chunk
                return result.decode("latin1")

    def test_concurrent_domains_paths_sni_and_reload(self):
        def verify(index):
            result = self.request(self.routes[index])
            self.assertIn("101 Switching Protocols", result)
            self.assertIn("X-Backend: " + str(index + 1), result)
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            list(pool.map(verify, [0, 1, 2] * 5))
        self.assertIn("404", self.request(self.routes[1], path=self.routes[0]["path"]))
        with self.assertRaises(ssl.SSLCertVerificationError):
            self.request(self.routes[1], trust=self.routes[0]["cert"])
        # Removing one path on domain B must preserve domain A and B's other path.
        self.write_config([self.routes[0], self.routes[2]])
        self.command(NGINX, "-p", self.root.as_posix() + "/", "-c", "nginx.conf", "-t")
        self.command(NGINX, "-p", self.root.as_posix() + "/", "-c", "nginx.conf", "-s", "reload")
        time.sleep(0.5)
        verify(0)
        verify(2)
        self.assertIn("404", self.request(self.routes[1]))


if __name__ == "__main__":
    unittest.main()
