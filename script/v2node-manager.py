#!/usr/bin/env python3
"""Linux lifecycle manager, Python 3.8+, standard library only.

Panel is the source of protocol/listener settings. Validate its node API before
applying local WSS routes; never write undocumented panel admin APIs.
"""
import argparse
import base64
import contextlib
import copy
import datetime
import getpass
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import shlex
import socket
import ssl
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zipfile

REPO = "https://api.github.com/repos/fsh2502/v2nodePro"
MARKER = "# Managed by v2nodePro manager"
CONFIG = Path("/etc/v2node/config.json")
STATE = Path("/etc/v2node/manager.json")
CERTS = Path("/etc/v2node/proxy-certs")
BACKUPS = Path("/var/lib/v2node-manager/backups")
BINARY = Path("/usr/local/v2node/v2node")
MANAGER = Path("/usr/local/lib/v2node-manager/manager.py")
LAUNCHER = Path("/usr/local/bin/v2node-manager")
UNIT = Path("/etc/systemd/system/v2node.service")
OPENRC = Path("/etc/init.d/v2node")
TIMER = Path("/etc/systemd/system/v2node-cert-renew.timer")
RENEW_UNIT = Path("/etc/systemd/system/v2node-cert-renew.service")
SYSCTL = Path("/etc/sysctl.d/99-v2node-manager.conf")


class Error(Exception):
    pass


def run(*args, check=True, data=None):
    result = subprocess.run([str(a) for a in args], input=data, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=180)
    if check and result.returncode:
        # Commands/output can contain credentials. Never echo them on failure.
        raise Error("Lệnh %s thất bại (mã %s)." % (Path(str(args[0])).name, result.returncode))
    return result


def atomic(path, data, mode=0o600):
    path = Path(path)
    if path.is_symlink():
        raise Error("Từ chối ghi đè symlink: %s" % path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".v2node-", dir=str(path.parent))
    try:
        os.chmod(name, mode)
        if path.exists() and hasattr(os, "chown"):
            previous = path.stat()
            os.chown(name, previous.st_uid, previous.st_gid)
        with os.fdopen(fd, "wb") as stream:
            if isinstance(data, Path):
                with data.open("rb") as source:
                    shutil.copyfileobj(source, stream, 1024 * 1024)
            else:
                stream.write(data.encode() if isinstance(data, str) else data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def read_json(path, default):
    if not path.exists():
        return copy.deepcopy(default)
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except (ValueError, UnicodeError):
        raise Error("JSON không hợp lệ: %s. Hãy sửa trước khi chạy lại." % path)


def write_json(path, value):
    atomic(path, json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def file_sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_state():
    state = read_json(STATE, {"version": 1, "routes": []})
    if state.get("version") != 1 or not isinstance(state.get("routes"), list):
        raise Error("Định dạng manager.json không được hỗ trợ.")
    return state


def load_config():
    config = read_json(CONFIG, {"Log": {"Level": "info", "Access": "none"}, "Nodes": []})
    if not isinstance(config.get("Nodes"), list):
        raise Error("config.json phải có mảng Nodes.")
    return config


def identity(node):
    return (node["ApiHost"].rstrip("/"), int(node["NodeID"]))


def validate_host(value):
    url = urllib.parse.urlsplit(value)
    if (url.scheme != "https" or not url.hostname or url.username or url.password
            or url.query or url.fragment or url.path not in ("", "/")):
        raise Error("API panel phải là https://domain[:port], không chứa tài khoản/path/query.")
    return value.rstrip("/")


def validate_route(route):
    domain = route["domain"].lower()
    if len(domain) > 253 or "." not in domain or any(
            not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", part)
            for part in domain.split(".")):
        raise Error("Domain kết nối không hợp lệ; chỉ nhập tên domain, không nhập URL.")
    if not re.fullmatch(r"/[A-Za-z0-9_~./-]+", route["path"]) or any(
            x in route["path"] for x in ("//", "/../", "/./")) or route["path"].endswith(("/..", "/.")):
        raise Error("Path WS phải bắt đầu bằng /, khác / và không chứa ký tự cấu hình.")
    if not 1024 <= int(route["port"]) <= 65535:
        raise Error("Cổng backend phải trong 1024–65535; cổng kết nối luôn là 443.")
    validate_host(route["ApiHost"])
    if int(route["NodeID"]) < 1:
        raise Error("Node ID phải lớn hơn 0.")
    route["domain"] = domain


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def panel(node, endpoint="config", payload=None):
    query = urllib.parse.urlencode({"node_type": "v2node", "node_id": node["NodeID"], "token": node["ApiKey"]})
    url = node["ApiHost"].rstrip("/") + "/api/v2/server/" + endpoint + "?" + query
    request = urllib.request.Request(url, data=None if payload is None else json.dumps(payload).encode(),
                                     headers={"Accept": "application/json", "Content-Type": "application/json"})
    try:
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=20) as response:
            return json.loads(response.read(1024 * 1024))
    except urllib.error.HTTPError as exc:
        raise Error("API panel HTTP %s (Node ID %s)." % (exc.code, node["NodeID"])) from None
    except (OSError, ValueError):
        raise Error("Không đọc được API panel (DNS/TLS/kết nối/JSON); URL và token đã ẩn.") from None


def truth(value):
    return str(value).lower() in ("true", "1", "yes", "on")


def panel_errors(info, route):
    tls = info.get("tls_settings") or {}
    network = info.get("network_settings") or {}
    if isinstance(network, str):
        try:
            network = json.loads(network)
        except ValueError:
            network = {}
    expected = [
        (info.get("protocol") in ("vmess", "vless", "trojan"), "Giao thức phải hỗ trợ WS: VMess/VLESS/Trojan"),
        (info.get("network") == "ws", "Giao thức truyền tải = WebSocket"),
        (info.get("listen_ip") == "127.0.0.1", "Listen IP = 127.0.0.1"),
        (str(info.get("server_port")) == str(route["port"]), "Cổng dịch vụ = %s" % route["port"]),
        (str(info.get("tls")) == "1", "TLS = Bật (TLS công khai tại Nginx)"),
        (truth(tls.get("terminate_tls_at_proxy")), "TLS tại Nginx = Bật"),
        (network.get("path") == route["path"], "WebSocket path = " + route["path"]),
        (tls.get("server_name") == route["domain"], "Server Name/SNI = " + route["domain"]),
        (not truth(network.get("acceptProxyProtocol")), "Accept Proxy Protocol = Tắt"),
        (tls.get("cert_file") == route["cert"], "Cert File = " + route["cert"]),
        (tls.get("key_file") == route["key"], "Key File = " + route["key"]),
        (tls.get("cert_mode") == "file", "Chế độ chứng chỉ = File (dùng cert/key do trình quản lý tạo)"),
    ]
    if route["tls"] == "self-signed":
        expected.append((truth((info.get("base_config") or {}).get("certificate_report")), "Vân tay chứng chỉ (tự động) = Bật"))
    return [message for ok, message in expected if not ok]


def instructions(route):
    print("\nCấu hình trên panel trước khi áp dụng:")
    print("  Host / SNI / WebSocket Host: %s; cổng kết nối: 443" % route["domain"])
    print("  Listen IP: 127.0.0.1; cổng dịch vụ: %s; WebSocket path: %s" % (route["port"], route["path"]))
    print("  TLS: Bật; TLS tại Nginx: Bật; Accept Proxy Protocol: Tắt; Disable SNI: Tắt")
    print("  Chế độ chứng chỉ: File; Cert File: %s; Key File: %s" % (route["cert"], route["key"]))
    print("  Vân tay chứng chỉ (tự động): Bật nếu dùng chứng chỉ tự ký.")
    print("  DNS domain node trỏ trực tiếp về VPS; API panel và domain node là hai giá trị riêng.")


def active_nginx():
    found = set()
    proc = Path("/proc")
    if proc.exists():
        for entry in proc.iterdir():
            if not entry.name.isdigit():
                continue
            try:
                if (entry / "comm").read_text().strip() != "nginx":
                    continue
                command = (entry / "cmdline").read_bytes().replace(b"\x00", b" ").decode().strip()
                if "nginx: master process " not in command:
                    continue
                binary = str((entry / "exe").resolve())
                argv = shlex.split(command.split("nginx: master process ", 1)[1])
                options = []
                for index, value in enumerate(argv[:-1]):
                    if value in ("-c", "-p"):
                        options.extend((value, argv[index + 1]))
                found.add((binary, tuple(options)))
            except (OSError, ValueError, UnicodeError):
                continue
    if len(found) > 1:
        raise Error("Có nhiều Nginx master/cấu hình đang chạy; cần hợp nhất hoặc quản lý riêng trước khi dùng wizard.")
    return next(iter(found)) if found else None


def nginx_binary():
    active = active_nginx()
    if active:
        if not Path(active[0]).is_file():
            raise Error("Binary của Nginx đang chạy đã bị thay/xóa; cần khởi động lại Nginx trước.")
        return active[0]
    for value in (shutil.which("nginx"), "/www/server/nginx/sbin/nginx", "/usr/local/openresty/nginx/sbin/nginx"):
        if value and Path(value).is_file():
            return value
    raise Error("Không tìm thấy Nginx. Cài Nginx hoặc chạy install --wss trước.")


def nginx_command():
    active = active_nginx()
    return [active[0], *active[1]] if active else [nginx_binary()]


def nginx_dump():
    result = run(*nginx_command(), "-T")
    if b"conflicting server name" in result.stderr:
        raise Error("Nginx đang có server_name trùng; cần xử lý trước khi thêm node.")
    return result.stdout.decode(errors="replace")


def discover_nginx_dir(dump, override=None):
    includes = re.findall(r'^\s*include\s+["\']?(/[^;"\'\s]+/\*\.conf)["\']?\s*;', dump, re.M)
    candidates = list(dict.fromkeys(str(Path(x).parent) for x in includes))
    if override:
        if str(Path(override)) not in candidates:
            raise Error("--nginx-dir phải là thư mục /*.conf đang được Nginx include.")
        return Path(override)
    for candidate in ("/www/server/panel/vhost/nginx", "/www/server/nginx/conf/vhost", "/etc/nginx/conf.d",
                      "/usr/local/openresty/nginx/conf/conf.d"):
        if candidate in candidates:
            return Path(candidate)
    if len(candidates) == 1:
        return Path(candidates[0])
    raise Error("Không xác định được include HTTP của Nginx. Dùng --nginx-dir DIR đã được include /*.conf.")


def render(domain, routes):
    selected = [r for r in routes if r["domain"] == domain]
    cert, key = selected[0]["cert"], selected[0]["key"]
    for route in selected:
        validate_route(route)
        if (route["cert"], route["key"]) != (cert, key):
            raise Error("Các path cùng domain phải dùng chung chứng chỉ.")
    locations = []
    for route in sorted(selected, key=lambda x: x["path"]):
        locations.append("""    location = %s {
        proxy_pass http://127.0.0.1:%s;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
        proxy_buffering off;
    }
""" % (route["path"], route["port"]))
    return """%s
server {
    listen 443 ssl;
%s
    server_name %s;
    ssl_certificate "%s";
    ssl_certificate_key "%s";
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:V2NODE_MANAGER:10m;
    ssl_session_timeout 1d;
%s
    location / { return 404; }
}
""" % (MARKER, "    listen [::]:443 ssl;" if socket.has_ipv6 and Path("/proc/net/if_inet6").exists() else "",
       domain, cert, key, "\n".join(locations))


def vhost(route):
    return Path(route["nginx_dir"]) / ("v2node-managed-" + route["domain"] + ".conf")


def service(action, name="v2node", check=True):
    if Path("/run/systemd/system").exists():
        return run("systemctl", action, name, check=check)
    if shutil.which("rc-service"):
        return run("rc-service", name, "status" if action == "is-active" else action, check=check)
    raise Error("Cần systemd hoặc OpenRC để quản lý dịch vụ.")


def nginx_apply(routes):
    dump = nginx_dump()
    for route in routes:
        if "# configuration file %s:" % vhost(route) not in dump:
            raise Error("Nginx chưa nạp vhost: %s" % vhost(route))
    command = nginx_command()
    if run(*command, "-s", "reload", check=False).returncode:
        if len(command) == 1 and Path("/run/systemd/system").exists():
            unit = run("systemctl", "show", "nginx", "--property=ExecStart", "--value", check=False)
            if command[0] in unit.stdout.decode(errors="replace"):
                run("systemctl", "enable", "--now", "nginx")
                return
        elif len(command) == 1 and shutil.which("rc-service") and Path("/etc/init.d/nginx").exists():
            run("rc-update", "add", "nginx", "default")
            run("rc-service", "nginx", "start")
            return
        run(*command)


def tracked_files(state):
    files = {CONFIG, STATE, BINARY, BINARY.parent / "version.json", UNIT, OPENRC, TIMER, RENEW_UNIT, SYSCTL,
             CONFIG.parent / "geoip.dat", CONFIG.parent / "geosite.dat", BINARY.parent / "geoip.dat", BINARY.parent / "geosite.dat"}
    for folder in (CONFIG.parent, BINARY.parent):
        if folder.exists():
            files.update(p for p in folder.rglob("*") if p.is_file())
    for route in state["routes"]:
        files.add(vhost(route))
        if route["tls"] == "self-signed":
            files.update((Path(route["cert"]), Path(route["key"])))
    return files


def backup(paths=None):
    BACKUPS.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(BACKUPS, 0o700)
    folder = BACKUPS / (datetime.datetime.now().strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:8])
    folder.mkdir(mode=0o700)
    manifest = {"version": 1, "files": [], "service_active": service("is-active", check=False).returncode == 0}
    if Path("/run/systemd/system").exists():
        manifest["service_enabled"] = run("systemctl", "is-enabled", "v2node", check=False).returncode == 0
        manifest["timer_enabled"] = run("systemctl", "is-enabled", TIMER.name, check=False).returncode == 0
        manifest["timer_active"] = run("systemctl", "is-active", TIMER.name, check=False).returncode == 0
    for index, path in enumerate(sorted(paths or tracked_files(load_state()), key=str)):
        path = Path(path)
        if path.is_symlink() or (path.exists() and not path.is_file()):
            raise Error("Không sao lưu file đặc biệt/symlink: %s" % path)
        item = {"path": str(path), "exists": path.exists(), "blob": str(index)}
        if path.exists():
            item["mode"] = stat.S_IMODE(path.stat().st_mode)
            shutil.copyfile(path, folder / str(index))
            os.chmod(folder / str(index), 0o600)
            item["sha256"] = file_sha256(folder / str(index))
        manifest["files"].append(item)
    write_json(folder / "manifest.json", manifest)
    print("Sao lưu: %s (chứa API key/cert, chỉ root được đọc)" % folder)
    return folder


def restore_files(folder):
    folder = Path(folder).resolve()
    if folder.parent != BACKUPS.resolve():
        raise Error("Chỉ khôi phục bản sao lưu bên trong %s." % BACKUPS)
    manifest = read_json(folder / "manifest.json", {})
    if manifest.get("version") != 1 or not isinstance(manifest.get("files"), list):
        raise Error("Manifest sao lưu không hợp lệ.")
    for item in manifest["files"]:
        if not re.fullmatch(r"[0-9]+", item["blob"]):
            raise Error("Tên blob sao lưu không hợp lệ.")
        if item["exists"] and file_sha256(folder / item["blob"]) != item["sha256"]:
            raise Error("Checksum bản sao lưu không khớp; chưa khôi phục.")
    for item in manifest["files"]:
        path = Path(item["path"])
        if item["exists"]:
            atomic(path, folder / item["blob"], item["mode"])
        elif path.exists():
            if path.is_symlink() or not path.is_file():
                raise Error("Từ chối xóa file đặc biệt: %s" % path)
            path.unlink()
    return manifest


def restore_service_state(manifest):
    if Path("/run/systemd/system").exists():
        run("systemctl", "daemon-reload")
        for unit, exists, enabled in (("v2node", UNIT.exists(), manifest.get("service_enabled")),
                                      (TIMER.name, TIMER.exists(), manifest.get("timer_enabled"))):
            if enabled is not None:
                run("systemctl", "enable" if enabled and exists else "disable", unit, check=exists)
        run("systemctl", "start" if manifest.get("timer_active") and TIMER.exists() else "stop", TIMER.name, check=False)
    elif shutil.which("rc-update") and OPENRC.exists() and manifest["service_active"]:
        run("rc-update", "add", "v2node", "default")
    service("restart" if manifest["service_active"] else "stop", check=manifest["service_active"])


@contextlib.contextmanager
def transaction(paths):
    folder = backup(paths)
    try:
        yield folder
    except BaseException:
        print("Thao tác thất bại; đang khôi phục %s" % folder.name, file=sys.stderr)
        try:
            manifest = restore_files(folder)
            restore_service_state(manifest)
            if any("/v2node-managed-" in str(path).replace("\\", "/") or "/v2node-wss-" in str(path).replace("\\", "/") for path in paths):
                nginx_apply(load_state()["routes"])
        except Exception as exc:
            print("Khôi phục cần kiểm tra thủ công: %s; bản sao lưu: %s" % (exc, folder), file=sys.stderr)
        raise


def cert_validate(route):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    try:
        context.load_cert_chain(route["cert"], route["key"])
    except (OSError, ssl.SSLError):
        raise Error("Cert/key không đọc được hoặc không khớp.") from None
    result = run("openssl", "x509", "-in", route["cert"], "-noout", "-checkhost", route["domain"])
    if b"does NOT match" in result.stdout:
        raise Error("Chứng chỉ không khớp domain.")
    run("openssl", "x509", "-in", route["cert"], "-noout", "-checkend", "0")


def new_certificate(route):
    CERTS.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.TemporaryDirectory(prefix=".cert-", dir=str(CERTS)) as temp:
        cert, key = Path(temp) / "cert.pem", Path(temp) / "key.pem"
        run("openssl", "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes", "-days", "365",
            "-subj", "/CN=" + route["domain"], "-addext", "subjectAltName=DNS:" + route["domain"],
            "-keyout", key, "-out", cert)
        atomic(route["cert"], cert.read_bytes(), 0o644)
        atomic(route["key"], key.read_bytes())


def ws_probe(route, tls=False, public=False):
    try:
        with socket.create_connection((route["domain"] if public else "127.0.0.1", 443 if tls else route["port"]), timeout=5) as raw:
            conn = ssl.create_default_context(cafile=route["cert"]).wrap_socket(raw, server_hostname=route["domain"]) if tls else raw
            with conn:
                request = ("GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                           "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n")
                conn.sendall((request % (route["path"], route["domain"])).encode())
                response = b""
                while b"\r\n\r\n" not in response and len(response) < 16384:
                    chunk = conn.recv(4096)
                    if not chunk:
                        break
                    response += chunk
                lines = response.decode("latin1").split("\r\n")
                headers = {k.lower(): v.strip() for k, sep, v in (x.partition(":") for x in lines[1:]) if sep}
                return (len(lines[0].split()) >= 2 and lines[0].split()[1] == "101"
                        and headers.get("sec-websocket-accept") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    except (OSError, ssl.SSLError):
        return False


def health(routes):
    for attempt in range(10):
        if service("is-active", check=False).returncode == 0 and all(ws_probe(r) and ws_probe(r, tls=True) for r in routes):
            return
        time.sleep(1)
    raise Error("Dịch vụ hoặc WS/WSS chưa hoạt động sau khi áp dụng; tự khôi phục cấu hình cũ.")


def check_panel(node, route, interactive=False):
    while True:
        errors = panel_errors(panel(node), route)
        if not errors:
            return
        print("Panel chưa khớp:\n  - " + "\n  - ".join(errors))
        if not interactive:
            raise Error("Lưu cấu hình trên panel theo hướng dẫn rồi chạy lại. Chưa sửa cấu hình VPS.")
        if input("Sau khi lưu panel, Enter để kiểm tra lại; q để hủy: ").lower() == "q":
            raise Error("Đã hủy; chưa áp dụng cấu hình.")


def assert_available(route, old_routes, previous, dump, registered=False):
    for other in old_routes:
        if previous is not None and identity(other) == identity(previous):
            continue
        if other["port"] == route["port"] or (other["domain"], other["path"]) == (route["domain"], route["path"]):
            raise Error("Cổng backend hoặc domain/path đã được node khác sử dụng.")
        if other["domain"] == route["domain"] and (other["cert"], other["key"], other["tls"], other["nginx_dir"]) != (
                route["cert"], route["key"], route["tls"], route["nginx_dir"]):
            raise Error("Cùng domain phải dùng chung cert/key, chế độ chứng chỉ và thư mục Nginx.")
    selected_files = {str(vhost(r)) for r in old_routes}
    current_file = ""
    for line in dump.splitlines():
        if line.startswith("# configuration file "):
            current_file = line[len("# configuration file "):].rstrip(":")
        if re.match(r"\s*server_name\s", line) and route["domain"] in line.replace(";", "").split()[1:]:
            if current_file not in selected_files:
                raise Error("Domain đang có vhost ngoài trình quản lý: %s. Hãy di chuyển vhost cũ trước." % current_file)
    if not previous or previous["port"] != route["port"]:
        with socket.socket() as probe:
            try:
                probe.bind(("127.0.0.1", route["port"]))
            except OSError:
                # A registered node may already have pulled its new port from the
                # panel. Accept only a matching live WS listener on loopback.
                if registered and ws_probe(route) and loopback_listener(route["port"]):
                    return
                raise Error("Cổng backend đang có dịch vụ nghe; chọn cổng khác.") from None


def loopback_listener(port):
    if not shutil.which("ss"):
        return False
    lines = run("ss", "-H", "-lnt", "sport = :%s" % port).stdout.decode().splitlines()
    addresses = [line.split()[3] for line in lines if len(line.split()) >= 4]
    return bool(addresses) and all(address == "127.0.0.1:%s" % port for address in addresses)


def write_vhosts(old_routes, routes):
    for filename, route in {str(vhost(r)): r for r in old_routes + routes}.items():
        path = Path(filename)
        if path.exists() and not path.read_text().startswith(MARKER + "\n"):
            raise Error("Từ chối sửa vhost không do trình quản lý tạo: " + filename)
        selected = [r for r in routes if str(vhost(r)) == filename]
        if selected:
            atomic(path, render(route["domain"], selected), 0o644)
        elif path.exists():
            path.unlink()


def ask(value, label, default=None, secret=False):
    if value is not None:
        return value
    if not sys.stdin.isatty():
        if default is not None:
            return default
        raise Error("Thiếu tham số: " + label)
    # Never display a secret as the default prompt value.
    prompt = label + (" [giữ khóa hiện tại]" if secret and default else " [%s]" % default if default is not None else "") + ": "
    result = getpass.getpass(prompt) if secret else input(prompt)
    return result or default


def node_args(args):
    host = validate_host(ask(args.api_host, "URL API panel"))
    node_id = int(ask(args.node_id, "Node ID"))
    existing = next((n for n in load_config()["Nodes"] if identity(n) == (host, node_id)), {})
    key = Path(args.api_key_file).read_text().strip() if args.api_key_file else args.api_key
    key = ask(key, "API key (ẩn khi nhập)", existing.get("ApiKey"), secret=True)
    if not key or node_id < 1:
        raise Error("Cần API key và Node ID hợp lệ.")
    node = copy.deepcopy(existing)
    node.update(ApiHost=host, NodeID=node_id, ApiKey=key)
    node.setdefault("Timeout", 15)
    return node


def add_node(args):
    node = node_args(args)
    state, config = load_state(), load_config()
    old_routes = copy.deepcopy(state["routes"])
    previous = next((r for r in old_routes if identity(r) == identity(node)), None)
    if args.command == "edit" and previous is None:
        raise Error("Node chưa được trình quản lý quản lý; dùng add.")
    defaults = previous or {}
    route = {"ApiHost": node["ApiHost"], "NodeID": node["NodeID"],
             "domain": ask(args.domain, "Domain kết nối node", defaults.get("domain")).lower(),
             "path": ask(args.path, "WebSocket path", defaults.get("path", "/ws-" + str(node["NodeID"]))),
             "port": int(ask(args.backend_port, "Cổng backend riêng", defaults.get("port", suggest_port(old_routes)))),
             "tls": args.tls or defaults.get("tls", "self-signed")}
    validate_route(route)
    if route["tls"] == "self-signed":
        route.update(cert=str(CERTS / (route["domain"] + ".cer")), key=str(CERTS / (route["domain"] + ".key")))
    else:
        for field, arg in (("cert", args.cert_file), ("key", args.key_file)):
            path = str(Path(ask(arg, field + " file", defaults.get(field))).absolute())
            if not re.fullmatch(r"/[A-Za-z0-9_./-]+", path):
                raise Error("Đường dẫn cert/key chứa ký tự không được hỗ trợ.")
            route[field] = path
        cert_validate(route)
    instructions(route)
    check_panel(node, route, interactive=not args.yes and sys.stdin.isatty())
    dump = nginx_dump()
    route["nginx_dir"] = str(discover_nginx_dir(dump, args.nginx_dir or defaults.get("nginx_dir")))
    assert_available(route, old_routes, previous, dump, registered=any(identity(n) == identity(node) for n in config["Nodes"]))
    state["routes"] = [r for r in old_routes if identity(r) != identity(node)] + [route]
    config["Nodes"] = [n for n in config["Nodes"] if identity(n) != identity(node)] + [node]
    if args.dry_run:
        print(render(route["domain"], state["routes"]))
        print("Dry-run hoàn tất; không ghi file hoặc khởi động lại dịch vụ.")
        return
    if not BINARY.exists():
        raise Error("Chưa cài binary v2nodePro. Chạy install trước hoặc chọn cài hoàn chỉnh.")
    with transaction(tracked_files(load_state()) | tracked_files(state)):
        if route["tls"] == "self-signed":
            if Path(route["cert"]).exists() != Path(route["key"]).exists():
                raise Error("Cặp cert/key không đầy đủ; không tự ghi đè.")
            if not Path(route["cert"]).exists():
                new_certificate(route)
        cert_validate(route)
        write_vhosts(old_routes, state["routes"])
        nginx_apply(state["routes"])
        write_json(CONFIG, config)
        write_json(STATE, state)
        service("restart")
        health(state["routes"])
    install_manager()
    print("Đã áp dụng; kiểm tra WS nội bộ và WSS qua Nginx thành công.")
    print("Cập nhật subscription trên ứng dụng; doctor --public kiểm tra thêm DNS/đường truyền công khai.")


def suggest_port(routes):
    used = {r["port"] for r in routes}
    for port in range(10001, 65536):
        if port in used:
            continue
        with socket.socket() as sock:
            try:
                sock.bind(("127.0.0.1", port))
                return port
            except OSError:
                continue
    raise Error("Không tìm được cổng backend trống.")


def install_manager():
    source = Path(__file__).read_bytes()
    atomic(MANAGER, source, 0o755)
    atomic(LAUNCHER, '#!/bin/sh\nexec python3 "%s" "$@"\n' % MANAGER, 0o755)


def legacy_routes(text, filename):
    """Import only the exact legacy generator, not hand-edited Nginx configs."""
    header = "# Managed by v2nodePro setup-wss-proxy.sh"
    if not text.startswith(header):
        raise Error("Không phải vhost setup-wss-proxy.sh: " + str(filename))
    def field(name):
        found = re.findall(r"^\s*" + name + r"\s+([^;\s]+);", text, re.M)
        if len(found) != 1:
            raise Error("Vhost cũ không đúng mẫu: " + str(filename))
        return found[0]
    domain, cert, key = field("server_name"), field("ssl_certificate"), field("ssl_certificate_key")
    locations = re.findall(r"    location = ([^\s]+) \{\n(.*?)\n    }", text, re.S)
    routes, rendered = [], []
    for path, body in locations:
        match = re.search(r"proxy_pass http://127\.0\.0\.1:([0-9]+);", body)
        if not match:
            raise Error("Backend vhost cũ không phải loopback.")
        port = int(match[1])
        rendered.append("""    location = %s {
        proxy_pass http://127.0.0.1:%s;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
        proxy_buffering off;
    }""" % (path, port))
        routes.append({"domain": domain, "path": path, "port": port, "cert": cert, "key": key})
    expected = """%s
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name %s;
    ssl_certificate %s;
    ssl_certificate_key %s;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:V2NODE_WSS:10m;
    ssl_session_timeout 1d;
    %s
    location / {
        return 404;
    }
}
""" % (header, domain, cert, key, "\n".join(rendered))
    if not routes or re.sub(r"\s+", " ", expected).strip() != re.sub(r"\s+", " ", text).strip():
        raise Error("Vhost cũ đã sửa ngoài mẫu; giữ nguyên để kiểm tra thủ công: " + str(filename))
    return routes


def migrate(args):
    dump = nginx_dump()
    files = [Path(x) for x in re.findall(r"^# configuration file (.+/v2node-wss-[^/]+\.conf):$", dump, re.M)]
    if not files:
        raise Error("Không có vhost setup-wss-proxy.sh cũ đang được Nginx nạp.")
    state = load_state()
    old_routes = copy.deepcopy(state["routes"])
    nodes = load_config()["Nodes"]
    info = {identity(node): panel(node) for node in nodes}
    for file in files:
        for route in legacy_routes(file.read_text(), file):
            matches = [node for node in nodes if str(info[identity(node)].get("server_port")) == str(route["port"])
                       and (info[identity(node)].get("tls_settings") or {}).get("server_name") == route["domain"]]
            if len(matches) != 1:
                raise Error("Không xác định duy nhất panel/node cho %s%s; chưa sửa file." % (route["domain"], route["path"]))
            node = matches[0]
            route.update(ApiHost=node["ApiHost"], NodeID=node["NodeID"], nginx_dir=str(file.parent), tls="existing")
            # Migration preserves certificate lifetime and leaves renewal with its existing owner.
            validate_route(route)
            instructions(route)
            check_panel(node, route, interactive=not args.yes and sys.stdin.isatty())
            cert_validate(route)
            if any(identity(r) == identity(route) or r["port"] == route["port"]
                   or (r["domain"], r["path"]) == (route["domain"], route["path"]) for r in state["routes"]):
                raise Error("Route cũ trùng dữ liệu manager; chưa di chuyển.")
            state["routes"].append(route)
    if args.dry_run:
        print("Sẽ nhập %s route và thay %s vhost cũ; giữ nguyên cert, port, path." % (len(state["routes"]) - len(old_routes), len(files)))
        return
    confirm(args, "Nhập các vhost setup-wss-proxy.sh cũ vào trình quản lý?")
    with transaction(tracked_files(load_state()) | tracked_files(state) | set(files)):
        write_vhosts(old_routes, state["routes"])
        for file in files:
            file.unlink()
        nginx_apply(state["routes"])
        write_json(STATE, state)
        health(state["routes"])
    install_manager()
    print("Đã nhập cấu hình WSS cũ. Chứng chỉ giữ nguyên và được ghi nhận là existing.")


def packages(wss=False):
    missing = []
    if wss:
        try:
            nginx_binary()
        except Error:
            if active_nginx():
                raise
            # Never install a second Nginx over a control-panel installation.
            if Path("/www/server/nginx").exists():
                raise Error("Có thư mục Nginx của panel nhưng thiếu binary; cần sửa cài đặt Nginx hiện có.")
            missing.append("nginx")
        if not shutil.which("openssl"):
            missing.append("openssl")
    if not missing:
        return
    print("Cài gói còn thiếu: " + ", ".join(missing))
    if shutil.which("apt-get"):
        run("apt-get", "update")
        run("apt-get", "install", "-y", *missing)
    elif shutil.which("dnf"):
        run("dnf", "install", "-y", *missing)
    elif shutil.which("yum"):
        run("yum", "install", "-y", *missing)
    elif shutil.which("apk"):
        run("apk", "add", "--no-cache", *missing)
    else:
        raise Error("Cần cài thủ công: " + ", ".join(missing))


def download(url, destination):
    if not url.startswith("https://"):
        raise Error("Chỉ tải qua HTTPS.")
    for attempt in range(3):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "v2nodePro-manager"})
            with urllib.request.urlopen(request, timeout=60) as response, open(destination, "wb") as output:
                shutil.copyfileobj(response, output)
            return
        except OSError:
            if attempt == 2:
                raise Error("Không tải được tài nguyên GitHub; chưa thay binary hiện tại.") from None
            time.sleep(1)


def release_payload(args, temp):
    tag = getattr(args, "version", None)
    if tag and not re.fullmatch(r"[A-Za-z0-9._-]+", tag):
        raise Error("Tên phiên bản không hợp lệ.")
    arch = {"x86_64": "64", "amd64": "64", "aarch64": "arm64-v8a", "arm64": "arm64-v8a",
            "s390x": "s390x", "riscv64": "riscv64", "ppc64le": "ppc64le"}.get(platform.machine().lower())
    if not arch:
        raise Error("Kiến trúc chưa được trình cài hỗ trợ: " + platform.machine())
    metadata = Path(temp) / "release.json"
    download(REPO + ("/releases/tags/" + tag if tag else "/releases/latest"), metadata)
    info = read_json(metadata, {})
    name = "v2node-linux-" + arch + ".zip"
    assets = {asset["name"]: asset for asset in info.get("assets", [])}
    if name not in assets or name + ".sha256" not in assets:
        raise Error("Release phải có %s và file .sha256; không cài gói không xác minh được." % name)
    archive, checksum = Path(temp) / name, Path(temp) / (name + ".sha256")
    download(assets[name]["browser_download_url"], archive)
    download(assets[name + ".sha256"]["browser_download_url"], checksum)
    expected = checksum.read_text().strip().split()[0]
    digest = file_sha256(archive)
    if not re.fullmatch(r"[0-9a-fA-F]{64}", expected) or digest.lower() != expected.lower():
        raise Error("SHA-256 không khớp; chưa thay binary.")
    # GitHub's asset digest is an additional check when supplied by its API.
    api_digest = assets[name].get("digest")
    if api_digest and api_digest != "sha256:" + digest:
        raise Error("SHA-256 không khớp digest của GitHub.")
    payload = {}
    with zipfile.ZipFile(archive) as bundle:
        for item in ("v2node", "geoip.dat", "geosite.dat"):
            matches = [entry for entry in bundle.infolist() if entry.filename in (item, "./" + item)]
            if len(matches) != 1 or matches[0].file_size == 0 or matches[0].file_size > 512 * 1024 * 1024:
                raise Error("ZIP thiếu/trùng/quá lớn: " + item)
            destination = Path(temp) / item
            with bundle.open(matches[0]) as source, destination.open("wb") as output:
                shutil.copyfileobj(source, output, 1024 * 1024)
            payload[item] = destination
    test_binary = Path(temp) / "v2node"
    os.chmod(test_binary, 0o755)
    version_output = run(test_binary, "version").stdout.decode(errors="replace").strip()
    print("Binary đã xác minh: " + version_output)
    return payload, {"tag": info["tag_name"], "archive_sha256": digest, "binary_version": version_output}


def ensure_unit():
    if Path("/run/systemd/system").exists():
        if not UNIT.exists():
            atomic(UNIT, """[Unit]
Description=v2nodePro Service
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
WorkingDirectory=/usr/local/v2node
ExecStart=/usr/local/v2node/v2node server --config /etc/v2node/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
UMask=0077
[Install]
WantedBy=multi-user.target
""", 0o644)
        run("systemctl", "daemon-reload")
        run("systemctl", "enable", "v2node")
    elif shutil.which("rc-service"):
        if not OPENRC.exists():
            atomic(OPENRC, """#!/sbin/openrc-run
name="v2node"
command="/usr/local/v2node/v2node"
command_args="server --config /etc/v2node/config.json"
command_background="yes"
pidfile="/run/v2node.pid"
directory="/usr/local/v2node"
depend() { need net; }
""", 0o755)
        run("rc-update", "add", "v2node", "default")
    else:
        raise Error("Cần systemd hoặc OpenRC.")


def install_binary(args):
    state = load_state()
    if args.command == "update" and not BINARY.exists():
        raise Error("Chưa cài v2nodePro; dùng install.")
    if args.dry_run:
        print("Sẽ tải release %s, xác minh ZIP + geoip/geosite, sao lưu và thay binary." % (args.version or "latest"))
        return
    with tempfile.TemporaryDirectory(prefix="v2node-release-") as temp:
        payload, version = release_payload(args, temp)
        with transaction(tracked_files(state)):
            for name, contents in payload.items():
                # Xray's default asset lookup uses the executable directory. Keep
                # /etc copies too for existing configurations that set an asset path.
                atomic(BINARY.parent / name, contents, 0o755 if name == "v2node" else 0o644)
                if name != "v2node":
                    atomic(CONFIG.parent / name, contents, 0o644)
            write_json(BINARY.parent / "version.json", version)
            if not CONFIG.exists():
                write_json(CONFIG, load_config())
            ensure_unit()
            if load_config()["Nodes"]:
                service("restart")
                # Also require that the process survives its initial startup.
                time.sleep(3)
                health(state["routes"])
    install_manager()
    print("Đã cài binary và đủ geoip.dat/geosite.dat; cấu hình node hiện có được giữ lại.")


def selected_routes(args):
    routes = load_state()["routes"]
    if getattr(args, "api_host", None):
        routes = [r for r in routes if r["ApiHost"] == args.api_host.rstrip("/")]
    if getattr(args, "node_id", None):
        routes = [r for r in routes if r["NodeID"] == args.node_id]
    if getattr(args, "domain", None):
        routes = [r for r in routes if r["domain"] == args.domain.lower()]
    if not routes:
        raise Error("Không có node WSS phù hợp được trình quản lý quản lý.")
    return routes


def confirm(args, message):
    if args.yes:
        return
    if not sys.stdin.isatty() or input(message + " [y/N]: ").lower() != "y":
        raise Error("Đã hủy. Dùng --yes nếu chạy không tương tác.")


def remove_node(args):
    args.api_host = ask(args.api_host, "URL API panel")
    args.node_id = int(ask(args.node_id, "Node ID"))
    routes = selected_routes(args)
    if len(routes) != 1:
        raise Error("Phải chọn chính xác một node bằng --api-host và --node-id.")
    selected = routes[0]
    if args.dry_run:
        print("Sẽ xóa node %s/%s và route %s%s." % (*identity(selected), selected["domain"], selected["path"]))
        return
    confirm(args, "Xóa node khỏi config.json và xóa route WSS tương ứng?")
    state, config = load_state(), load_config()
    old_routes = copy.deepcopy(state["routes"])
    with transaction(tracked_files(state)):
        state["routes"] = [r for r in old_routes if identity(r) != identity(selected)]
        config["Nodes"] = [n for n in config["Nodes"] if identity(n) != identity(selected)]
        write_vhosts(old_routes, state["routes"])
        nginx_apply(state["routes"])
        write_json(CONFIG, config)
        write_json(STATE, state)
        service("restart" if config["Nodes"] else "stop")
        if config["Nodes"]:
            health(state["routes"])
    print("Đã xóa node/route. Chứng chỉ được giữ để khôi phục nếu cần.")


def list_nodes(args):
    state = load_state()
    managed = {identity(r): r for r in state["routes"]}
    if args.json:
        print(json.dumps({"routes": state["routes"], "nodes": [
            {"ApiHost": n["ApiHost"], "NodeID": n["NodeID"], "managed": identity(n) in managed}
            for n in load_config()["Nodes"]]}, indent=2))
        return
    print("PANEL | NODE ID | DOMAIN:443/PATH | BACKEND | QUẢN LÝ")
    for node in load_config()["Nodes"]:
        route = managed.get(identity(node))
        print("%s | %s | %s | %s | %s" % (node["ApiHost"], node["NodeID"],
              route["domain"] + ":443" + route["path"] if route else "—",
              "127.0.0.1:" + str(route["port"]) if route else "—", "WSS" if route else "Cấu hình có sẵn"))
    if BINARY.exists():
        print(run(BINARY, "version").stdout.decode(errors="replace").strip())
    print("v2node: " + ("đang chạy" if service("is-active", check=False).returncode == 0 else "đã dừng"))
    if Path("/proc/loadavg").exists():
        print("Load: " + Path("/proc/loadavg").read_text().strip())
    if shutil.which("ss"):
        print("TCP established :443: %s" % len(run("ss", "-Hnt", "state", "established", "sport = :443").stdout.splitlines()))


def certificate_details(route):
    result = run("openssl", "x509", "-in", route["cert"], "-noout", "-enddate", "-issuer", "-fingerprint", "-sha256")
    return result.stdout.decode(errors="replace").strip()


def doctor(args):
    nodes = {identity(n): n for n in load_config()["Nodes"]}
    failed = False
    nginx_dump()
    for route in selected_routes(args):
        print("\n%s:%s  %s%s → 127.0.0.1:%s" % (*identity(route), route["domain"], route["path"], route["port"]))
        try:
            info = panel(nodes[identity(route)])
            errors = panel_errors(info, route)
            print("Panel: " + ("OK" if not errors else "; ".join(errors)))
            failed |= bool(errors)
        except Error as exc:
            print(str(exc))
            failed = True
        for label, tls, public in [("Backend WS", False, False), ("Nginx WSS + SNI/cert", True, False)] + (
                [("WSS qua DNS công khai", True, True)] if args.public else []):
            ok = ws_probe(route, tls, public)
            print(label + ": " + ("101 OK" if ok else "LỖI"))
            failed |= not ok
        try:
            print(certificate_details(route))
        except Error as exc:
            print(str(exc))
            failed = True
    print("101 xác minh đường truyền WebSocket; chưa xác minh tài khoản hay khả năng truy cập Internet qua proxy.")
    print("Nếu pin/app lỗi: cập nhật subscription; HTTP 409 báo chứng chỉ thường là revision cấu hình đã đổi.")
    if failed:
        raise Error("Doctor phát hiện lỗi. Kiểm tra panel, listener, DNS và vhost tương ứng.")


def certificate_report(node, route):
    info = panel(node)
    if panel_errors(info, route):
        raise Error("Panel thay đổi cấu hình; không gửi vân tay chứng chỉ khác cấu hình.")
    der = run("openssl", "x509", "-in", route["cert"], "-outform", "DER").stdout
    pem_key = run("openssl", "x509", "-in", route["cert"], "-pubkey", "-noout").stdout
    der_key = run("openssl", "pkey", "-pubin", "-outform", "DER", data=pem_key).stdout
    dates = run("openssl", "x509", "-in", route["cert"], "-enddate", "-noout").stdout.decode().strip().split("=", 1)[1]
    issuer = run("openssl", "x509", "-in", route["cert"], "-issuer", "-noout").stdout.decode().strip().split("=", 1)[1]
    payload = {"revision": info["base_config"]["certificate_revision"], "tls_enabled": True,
               "tls_certificate_sha256": hashlib.sha256(der).hexdigest(),
               "tls_public_key_sha256": base64.b64encode(hashlib.sha256(der_key).digest()).decode(),
               "tls_not_after": int(ssl.cert_time_to_seconds(dates)), "tls_issuer": issuer.strip()}
    if panel(node, "certificate", payload).get("data") is not True:
        raise Error("Panel không chấp nhận báo chứng chỉ.")


def renew(args):
    if not load_state()["routes"]:
        print("Không có chứng chỉ WSS được quản lý để gia hạn.")
        return
    routes = selected_routes(args)
    nodes = {identity(n): n for n in load_config()["Nodes"]}
    domains = sorted({r["domain"] for r in routes if r["tls"] == "self-signed"})
    for domain in domains:
        # All panels sharing a certificate must be included in renewal/reporting.
        affected = [r for r in load_state()["routes"] if r["domain"] == domain]
        route = affected[0]
        if not args.force and run("openssl", "x509", "-in", route["cert"], "-noout", "-checkend", str(30 * 86400), check=False).returncode == 0:
            print(domain + ": chưa cần gia hạn (còn hơn 30 ngày).")
            continue
        if args.dry_run:
            print(domain + ": sẽ gia hạn và báo vân tay tới %s panel/node." % len(affected))
            continue
        for item in affected:
            check_panel(nodes[identity(item)], item)
        try:
            with transaction(tracked_files(load_state())):
                new_certificate(route)
                cert_validate(route)
                nginx_apply(load_state()["routes"])
                service("restart")
                health(load_state()["routes"])
                for item in affected:
                    certificate_report(nodes[identity(item)], item)
        except BaseException:
            # Some panels may have accepted the new pin before another failed.
            # Restore their old pin too after the local cert transaction rolls back.
            for item in affected:
                try:
                    certificate_report(nodes[identity(item)], item)
                except Error:
                    print("Cần đồng bộ lại pin: %s/%s" % identity(item), file=sys.stderr)
            raise
        print(domain + ": đã gia hạn và panel đã nhận vân tay. Ứng dụng cần cập nhật subscription.")


def auto_renew(args):
    if not any(r["tls"] == "self-signed" for r in load_state()["routes"]):
        raise Error("Chưa có chứng chỉ tự ký do manager quản lý.")
    if not Path("/run/systemd/system").exists():
        raise Error("Timer tự gia hạn cần systemd; OpenRC có thể lên lịch lệnh renew --yes bằng cron.")
    if args.dry_run:
        print("Sẽ bật timer kiểm tra hàng ngày; gia hạn cert tự ký còn tối đa 30 ngày.")
        return
    confirm(args, "Bật tự gia hạn? Khi cert đổi, ứng dụng ghim cert phải cập nhật subscription để nhận pin mới")
    with transaction(tracked_files(load_state())):
        install_manager()
        atomic(RENEW_UNIT, "[Unit]\nDescription=Renew managed v2node certificates\n[Service]\nType=oneshot\nExecStart=%s renew --yes\n" % LAUNCHER, 0o644)
        atomic(TIMER, "[Unit]\nDescription=Check v2node certificate expiry daily\n[Timer]\nOnCalendar=daily\nRandomizedDelaySec=1h\nPersistent=true\n[Install]\nWantedBy=timers.target\n", 0o644)
        run("systemctl", "daemon-reload")
        run("systemctl", "enable", "--now", TIMER.name)
    print("Đã bật timer. Chứng chỉ có sẵn/Let's Encrypt do công cụ cấp chứng chỉ của bạn gia hạn.")


def firewall(args):
    if shutil.which("ufw") and "Status: active" in run("ufw", "status").stdout.decode(errors="replace"):
        if not args.dry_run:
            run("ufw", "allow", "443/tcp", "comment", "v2node WSS")
        print("UFW: %s cho phép TCP 443." % ("sẽ" if args.dry_run else "đã"))
    elif shutil.which("firewall-cmd") and run("firewall-cmd", "--state", check=False).returncode == 0:
        if not args.dry_run:
            run("firewall-cmd", "--add-port=443/tcp")
            run("firewall-cmd", "--permanent", "--add-port=443/tcp")
        print("firewalld: %s cho phép TCP 443 tại default zone." % ("sẽ" if args.dry_run else "đã"))
    else:
        print("Không phát hiện UFW/firewalld hoạt động. Nếu dùng nftables/iptables, cho phép TCP 443 theo bộ luật hiện có.")
    print("Firewall của nhà cung cấp VPS cần cho phép TCP 443. Backend chỉ nghe 127.0.0.1, không mở cổng backend.")


def restore(args):
    folder = Path(ask(args.backup_id, "ID hoặc đường dẫn bản sao lưu"))
    if not folder.is_absolute():
        folder = BACKUPS / folder
    if args.dry_run:
        print("Sẽ khôi phục " + str(folder))
        return
    confirm(args, "Khôi phục cấu hình/binary từ " + folder.name + "?")
    target = read_json(folder / "manifest.json", {})
    paths = tracked_files(load_state()) | {Path(x["path"]) for x in target.get("files", [])}
    with transaction(paths):
        # Remove only routes created since this snapshot; config restoration is exact.
        old_routes = load_state()["routes"]
        manifest = restore_files(folder)
        state = load_state()
        write_vhosts(old_routes, state["routes"])
        restore_service_state(manifest)
        if old_routes or state["routes"]:
            nginx_apply(state["routes"])
        if manifest["service_active"]:
            health(state["routes"])
    print("Đã khôi phục. Nếu chứng chỉ đổi, cập nhật subscription sau khi node báo lại pin.")


def tune(args):
    profiles = {"small": 4096, "balanced": 8192, "large": 16384}
    backlog = profiles[args.profile]
    content = MARKER + "\nnet.core.somaxconn = %s\nnet.ipv4.tcp_max_syn_backlog = %s\n" % (backlog, backlog)
    if args.dry_run:
        print(content)
        return
    confirm(args, "Áp dụng profile %s cho hàng đợi kết nối kernel?" % args.profile)
    if SYSCTL.exists() and not SYSCTL.read_text().startswith(MARKER):
        raise Error("File sysctl đã tồn tại và không thuộc trình quản lý.")
    keys = ("net.core.somaxconn", "net.ipv4.tcp_max_syn_backlog")
    previous = {key: run("sysctl", "-n", key).stdout.decode().strip() for key in keys}
    try:
        with transaction(tracked_files(load_state())):
            atomic(SYSCTL, content, 0o644)
            run("sysctl", "-p", SYSCTL)
    except BaseException:
        for key, value in previous.items():
            run("sysctl", "-w", key + "=" + value, check=False)
        raise
    print("Đã áp dụng profile. Không tăng băng thông/CPU thực của VPS; dùng list để theo dõi tải.")


def uninstall(args):
    state = load_state()
    if args.dry_run:
        print("Sẽ dừng v2node, xóa unit/binary và các vhost do manager quản lý; giữ config/cert/backup.")
        return
    confirm(args, "Gỡ v2nodePro và các route WSS do manager quản lý? Các node sẽ dừng kết nối")
    with transaction(tracked_files(state)):
        service("stop", check=False)
        if Path("/run/systemd/system").exists():
            run("systemctl", "disable", "v2node", check=False)
            run("systemctl", "disable", "--now", TIMER.name, check=False)
        elif shutil.which("rc-update"):
            run("rc-update", "del", "v2node", "default", check=False)
        write_vhosts(state["routes"], [])
        if state["routes"]:
            nginx_apply([])
        for path in (BINARY, UNIT, OPENRC, TIMER, RENEW_UNIT):
            if path.exists():
                path.unlink()
        state["routes"] = []
        write_json(STATE, state)
        if Path("/run/systemd/system").exists():
            run("systemctl", "daemon-reload")
    print("Đã gỡ dịch vụ/binary và WSS do manager tạo. Config, cert và backup được giữ để khôi phục.")


def parser():
    root = argparse.ArgumentParser(description="v2nodePro: quản lý node, Nginx WSS :443, backup/rollback.")
    sub = root.add_subparsers(dest="command")
    for command in ("menu", "install", "update", "add", "edit", "remove", "list", "doctor", "certificates", "renew", "auto-renew",
                    "backup", "restore", "tune", "uninstall", "migrate", "firewall", "start", "stop", "restart", "status", "version"):
        p = sub.add_parser(command)
        p.add_argument("--yes", action="store_true", help="Không hỏi xác nhận")
        p.add_argument("--dry-run", action="store_true", help="Xem trước, không ghi cấu hình")
        if command in ("install", "update"):
            p.add_argument("--version", help="Release tag; mặc định latest")
        if command in ("install", "add", "edit"):
            p.add_argument("--api-key", help="Ưu tiên nhập ẩn hoặc --api-key-file để tránh lịch sử shell")
            p.add_argument("--api-key-file")
            p.add_argument("--path")
            p.add_argument("--backend-port", type=int)
            p.add_argument("--tls", choices=("self-signed", "existing"))
            p.add_argument("--cert-file")
            p.add_argument("--key-file")
            p.add_argument("--nginx-dir")
        if command in ("install", "add", "edit", "remove", "doctor", "certificates", "renew"):
            p.add_argument("--api-host")
            p.add_argument("--node-id", type=int)
            p.add_argument("--domain")
        if command == "install":
            p.add_argument("--wss", action="store_true", help="Cài hoàn chỉnh Node + Nginx WSS")
        if command == "list":
            p.add_argument("--json", action="store_true", help="Xuất metadata, không có API key")
        if command == "doctor":
            p.add_argument("--public", action="store_true")
        if command == "renew":
            p.add_argument("--force", action="store_true")
        if command == "restore":
            p.add_argument("backup_id", nargs="?")
        if command == "tune":
            p.add_argument("--profile", choices=("small", "balanced", "large"), default="balanced")
    return root


def dispatch(args):
    command = args.command
    if command == "install":
        if not args.dry_run:
            packages(args.wss)
        install_binary(args)
        if args.wss:
            firewall(args)
            add_node(args)
        elif args.api_host or args.node_id:
            node = node_args(args)
            # Basic installs also preserve all other nodes and top-level options.
            panel(node)
            if not args.dry_run:
                with transaction(tracked_files(load_state())):
                    config = load_config()
                    config["Nodes"] = [n for n in config["Nodes"] if identity(n) != identity(node)] + [node]
                    write_json(CONFIG, config)
                    service("restart")
                    time.sleep(3)
                    health(load_state()["routes"])
    elif command == "update":
        install_binary(args)
    elif command in ("add", "edit"):
        add_node(args)
    elif command == "remove":
        remove_node(args)
    elif command == "migrate":
        migrate(args)
    elif command == "firewall":
        firewall(args)
    elif command == "list":
        list_nodes(args)
    elif command == "doctor":
        doctor(args)
    elif command == "certificates":
        for route in selected_routes(args):
            print(route["domain"] + "\n" + certificate_details(route))
    elif command == "renew":
        renew(args)
    elif command == "auto-renew":
        auto_renew(args)
    elif command == "backup":
        if not args.dry_run:
            backup()
    elif command == "restore":
        restore(args)
    elif command == "tune":
        tune(args)
    elif command == "uninstall":
        uninstall(args)
    elif command in ("start", "stop", "restart", "status"):
        if not args.dry_run:
            result = service("is-active" if command == "status" else command, check=False)
            print("v2node đang chạy" if command == "status" and result.returncode == 0 else "Mã kết quả: %s" % result.returncode)
            if result.returncode:
                raise Error("Dịch vụ không ở trạng thái yêu cầu.")
    elif command == "version":
        print(run(BINARY, "version").stdout.decode(errors="replace"))


def menu():
    choices = {"1": ["install"], "2": ["install", "--wss"], "3": ["add"], "4": ["edit"], "5": ["remove"],
               "6": ["list"], "7": ["doctor", "--public"], "8": ["certificates"], "9": ["renew"],
               "10": ["auto-renew"], "11": ["update"], "12": ["backup"], "13": ["restore"],
               "14": ["tune"], "15": ["uninstall"], "16": ["migrate"], "17": ["firewall"]}
    while True:
        print("""\nV2NODEPRO — NODE + NGINX WSS 443
1. Cài/cập nhật binary v2nodePro
2. Cài hoàn chỉnh Node + WSS 443
3. Thêm website/node WSS
4. Sửa website/node WSS
5. Xóa website/node WSS
6. Danh sách node và trạng thái
7. Doctor: kiểm tra kết nối
8. Xem chứng chỉ/vân tay/hạn
9. Gia hạn chứng chỉ sắp hết hạn
10. Bật tự gia hạn chứng chỉ (systemd)
11. Cập nhật binary có backup/rollback
12. Sao lưu
13. Khôi phục bản sao lưu
14. Tối ưu hàng đợi kết nối
15. Gỡ v2nodePro
16. Nhập cấu hình setup-wss-proxy.sh cũ
17. Cho phép TCP 443 trong UFW/firewalld
0. Thoát""")
        choice = input("Chọn chức năng: ").strip()
        if choice == "0":
            return
        if choice not in choices:
            continue
        try:
            dispatch(parser().parse_args(choices[choice]))
        except (Error, OSError, ValueError, KeyError, TypeError, AttributeError, zipfile.BadZipFile, subprocess.TimeoutExpired) as exc:
            print("Lỗi: " + safe_error(exc), file=sys.stderr)


def safe_error(exc):
    if isinstance(exc, Error):
        return str(exc)
    # Avoid tracebacks leaking credentials in malformed JSON/HTTP/command errors.
    return "Dữ liệu, file hoặc lệnh hệ thống không hợp lệ (%s)." % type(exc).__name__


def main():
    args = parser().parse_args()
    if platform.system() != "Linux" or os.geteuid() != 0:
        raise Error("Chạy trên Linux bằng quyền root.")
    os.umask(0o077)
    os.environ["LC_ALL"] = "C"
    import fcntl
    with open("/run/v2node-manager.lock", "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Error("Một phiên trình quản lý khác đang chạy.") from None
        if args.command in (None, "menu"):
            menu()
        else:
            dispatch(args)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("Đã hủy.", file=sys.stderr)
        sys.exit(130)
    except (Error, OSError, ValueError, KeyError, TypeError, AttributeError, zipfile.BadZipFile, subprocess.TimeoutExpired) as exc:
        print("Lỗi: " + safe_error(exc), file=sys.stderr)
        sys.exit(1)
