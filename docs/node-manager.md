# Quản lý v2nodePro + Nginx WSS 443

## Cài nhanh

Yêu cầu Linux, root, Python >=3.8 và systemd hoặc OpenRC. Bootstrap cài Python/curl
nếu thiếu. WSS cần Nginx và OpenSSL >=1.1.1; `install --wss` cài các gói thiếu.
Debian/Ubuntu, RHEL có dnf/yum, Alpine được nhận diện. Trình quản lý không thay thế
Nginx của aaPanel/BT hoặc OpenResty đã có.

```bash
wget -N https://raw.githubusercontent.com/fsh2502/v2nodePro/main/script/caidatserver.sh && bash caidatserver.sh
```

Chọn **2** để cài hoàn chỉnh; **3** để thêm WSS khi binary đã có. Script hỏi URL panel,
Node ID, API key, domain kết nối, path và cổng backend. API key được ẩn khi nhập.
Panel và domain kết nối có thể khác nhau. Mỗi node được nhận diện bằng cặp
`ApiHost + NodeID`, nên hai panel đều có Node ID 1 vẫn hoạt động độc lập.

Trình quản lý lưu ở `/usr/local/lib/v2node-manager/manager.py`; lệnh mở lại là
`v2node-manager`. Chạy lại bootstrap tải manager mới từ cùng một commit GitHub.
`V2NODE_MANAGER_REF=<commit-or-tag>` chọn bản manager cụ thể. HTTPS/commit cố định
đảm bảo tải nhất quán; bootstrap hiện chưa có chữ ký phát hành độc lập.

## Cấu hình panel và nhiều domain

Ví dụ hai node:

| Thiết lập | Node A | Node B |
|---|---|---|
| API panel | https://panel-a.example.com | https://panel-b.example.com |
| Node ID | 1 | 1 |
| Host, SNI, WS Host | node-a.example.com | node-b.example.com |
| Cổng kết nối | 443 | 443 |
| Listen IP | 127.0.0.1 | 127.0.0.1 |
| Cổng dịch vụ | 10001 | 10002 |
| WS path | /panel-a | /panel-b |
| TLS / TLS tại Nginx | Bật / Bật | Bật / Bật |
| Chế độ chứng chỉ | File | File |
| Cert File | /etc/v2node/proxy-certs/node-a.example.com.cer | /etc/v2node/proxy-certs/node-b.example.com.cer |
| Key File | /etc/v2node/proxy-certs/node-a.example.com.key | /etc/v2node/proxy-certs/node-b.example.com.key |

Tắt Disable SNI và Accept Proxy Protocol. Bật vân tay tự động khi dùng cert tự ký.
Domain node trỏ trực tiếp về IP VPS; dịch vụ CDN kết thúc TLS sẽ đưa chứng chỉ khác
cho ứng dụng và không khớp pin tự ký tại VPS.

Trình cài kiểm tra API `/api/v2/server/config` trước khi ghi cấu hình. Nếu chưa khớp,
lưu panel theo các giá trị in ra rồi Enter để kiểm tra lại. Node API key không có
quyền chỉnh admin nên script không tự sửa panel. Những lựa chọn chỉ nằm trong dữ
liệu subscription (cổng kết nối, Disable SNI, tùy chọn ghim) vẫn cần kiểm tra ở panel/app.
Chỉ VMess/VLESS/Trojan qua WebSocket được thêm vào WSS. Các giao thức khác trong
`config.json` vẫn được giữ và tiếp tục do panel cấp cấu hình.

```bash
v2node-manager add --api-host https://panel-b.example.com --node-id 1 \
  --domain node-b.example.com --path /panel-b --backend-port 10002

# Xem trước cấu hình, không ghi file hay restart.
v2node-manager edit --api-host https://panel-b.example.com --node-id 1 \
  --path /new-path --backend-port 10003 --dry-run

# Lệnh không tương tác: khóa đọc từ file quyền 600 thay vì lịch sử shell.
v2node-manager add --api-host https://panel-b.example.com --node-id 1 \
  --api-key-file /root/node-api-key --domain node-b.example.com \
  --path /panel-b --backend-port 10002 --yes
```

`--dry-run` vẫn đọc API và cấu hình Nginx để kiểm tra tính hợp lệ. Tùy chọn cổng/path
do panel điều khiển; khi sửa chúng trên panel, v2node đang chạy có thể tự reload ngay.
Backup/rollback của manager chỉ khôi phục VPS; nếu đã sửa panel, cần đưa panel về
giá trị cũ tương ứng khi quay lại. Nên thực hiện đổi cấu hình trong thời gian bảo trì.

Nginx được dò từ PATH, `/www/server/nginx/sbin/nginx` hoặc OpenResty. Script đọc
`nginx -T`, chọn thư mục đang include `/*.conf`; có thể chỉ định `--nginx-dir DIR`.
Vhost mới tên `v2node-managed-<domain>.conf`. Script kiểm tra Nginx thực sự nạp file,
từ chối server_name trùng và khôi phục khi kiểm tra/reload lỗi. Cùng domain có thể
chứa nhiều path nhưng phải dùng chung cert/key; mỗi route có backend port riêng.

## Nhập cấu hình WSS cũ

```bash
bash caidatserver.sh migrate --dry-run
bash caidatserver.sh migrate
```

Chỉ nhập file `v2node-wss-*.conf` đang được Nginx nạp, có marker của
`setup-wss-proxy.sh` và nội dung đúng mẫu của script. Cần tất cả route trong các
vhost đó ánh xạ được tới các node có sẵn trong `config.json`. Trên panel chuyển
chế độ chứng chỉ sang **File**, giữ nguyên đường dẫn cert/key, port/path và SNI.
Import giữ thời hạn/chứng chỉ cũ, ghi nhận là `existing`; không tự gia hạn chúng.
Có thể dùng `edit --tls self-signed` sau nếu muốn manager quản lý gia hạn cặp cert
ở đường dẫn mặc định `/etc/v2node/proxy-certs/<domain>.cer/.key`.

Vhost tùy biến không được tự chuyển. Menu NAT cũ, thao tác ghi đè `nginx.conf`,
gỡ toàn bộ Nginx, flush NAT và tắt firewall đã được bỏ khỏi các entry point mới.
`setup-wss-proxy.sh` cũ vẫn giữ để tương thích; dùng manager cho cài đặt mới.

## Chứng chỉ

```bash
v2node-manager certificates
v2node-manager renew --dry-run
v2node-manager renew --yes
v2node-manager auto-renew
```

Cert tự ký mới có SAN cho domain, RSA 2048, SHA-256, hạn 365 ngày. Manager giữ cặp
cert/key có sẵn nếu hợp lệ và không ghi đè cặp thiếu một file. Gia hạn khi còn tối
đa 30 ngày; `--force` chỉ dùng khi chủ động thay cert. `auto-renew` tạo systemd timer
kiểm tra hàng ngày; không bật mặc định vì thay cert làm đổi pin của ứng dụng.

Gia hạn sao lưu cert/key, tạo cặp mới, kiểm tra Nginx, reload Nginx, restart v2node,
kiểm tra WS/WSS và gửi vân tay đúng revision tới tất cả panel dùng chung domain.
Nếu một bước lỗi, khôi phục bản trước và cố gắng báo lại pin cũ tới các panel.
Panel không truy cập được sẽ cần v2node báo lại sau khi kết nối phục hồi.
Sau thay cert, ứng dụng ghim cert cần cập nhật subscription; manager không thể tự
cập nhật subscription trên điện thoại. Không có cam kết thay pin không gián đoạn.

Cert đã có, bao gồm Let's Encrypt:

```bash
v2node-manager add --api-host https://panel.example.com --node-id 1 \
  --domain node.example.com --path /ws --backend-port 10001 \
  --tls existing --cert-file /etc/letsencrypt/live/node.example.com/fullchain.pem \
  --key-file /etc/letsencrypt/live/node.example.com/privkey.pem
```

Công cụ ACME hiện có tiếp tục cấp/gia hạn cert; manager không cài hay chiếm cổng 80
để chạy ACME. Sau ACME renew, hook cần `nginx -t && nginx -s reload` và restart
v2node để nạp/báo cert mới. Nếu dùng Nginx của panel, dùng đúng binary của panel.

## Cập nhật, sao lưu, khôi phục

```bash
v2node-manager backup
v2node-manager update                    # Binary release latest
v2node-manager update --version v0.3.5   # Chọn tag cụ thể
v2node-manager restore BACKUP_ID
```

Binary ZIP phải có `.sha256`, chứa đủ `v2node`, `geoip.dat`, `geosite.dat`. Trình cài
xác minh SHA-256 (và digest GitHub nếu có), thử chạy `version` trong thư mục tạm,
sau đó sao lưu và thay file. Thao tác đọc/chép ZIP và backup theo khối để hạn chế RAM.
Nếu startup/WS/WSS lỗi thì khôi phục. `version` là kết quả binary thực; trình quản lý
không sửa chuỗi phiên bản Xray và không cập nhật riêng Xray bên trong binary.

Backup nằm tại `/var/lib/v2node-manager/backups/<ID>/`, quyền 700, gồm manifest có
checksum, cấu hình/cert trong `/etc/v2node`, binary, service unit và vhost do manager
quản lý. Backup có API key/private key, chỉ root được đọc. Giữ backup này khi chuyển
máy nếu cần khôi phục. Không nhập tar tùy ý hoặc ghi đè symlink/file đặc biệt.
Backup không bao gồm cơ sở dữ liệu panel, cert ACME ở ngoài `/etc/v2node`, firewall
của nhà cung cấp hay toàn bộ cấu hình Nginx. Các gói hệ thống cài mới không bị gỡ khi rollback.

## Kiểm tra và vận hành

```bash
v2node-manager list
v2node-manager list --json               # Metadata không chứa API key
v2node-manager doctor --public
v2node-manager doctor --domain node-b.example.com
v2node-manager firewall                 # Thêm allow TCP 443 vào UFW/firewalld đang chạy
v2node-manager tune --profile balanced --dry-run
v2node-manager tune --profile balanced
v2node-manager remove --api-host https://panel-b.example.com --node-id 1
v2node-manager uninstall
```

Doctor xác minh cấu hình panel, handshake WS backend, WSS qua Nginx với SNI và cert;
`--public` thử thêm đường DNS từ VPS. `101` chưa chứng minh xác thực proxy hoặc truy
cập Internet; cuối cùng vẫn cần thử từ Happ/Incy bằng tài khoản của đúng panel.
HTTP 409 khi báo cert thường là revision panel đã đổi; lấy lại cấu hình rồi báo lại.

`tune` chỉ đặt `somaxconn` và `tcp_max_syn_backlog` trong file riêng
`/etc/sysctl.d/99-v2node-manager.conf`; không ghi đè `/etc/sysctl.conf`, không dùng
`tcp_tw_recycle` và không hứa hẹn số lượng người dùng theo RAM. Unit mới có
`LimitNOFILE=65536`; unit đã có được giữ lại. Cổng backend không mở ra Internet.

`uninstall` dừng v2node, bỏ binary/unit/timer và vhost do manager tạo. Giữ config,
cert, manager và backup để khôi phục. Không gỡ gói Nginx, không xóa website khác.

## Kiểm thử

```bash
for script in script/*.sh; do bash -n "$script"; done
bash script/test-wss-proxy.sh
python3 -m unittest discover -s script -p 'test_*.py' -v
```

Bộ Python kiểm tra bảo toàn cấu hình, idempotency, checksum, rollback, bí mật API,
gia hạn/pin và migration. Test Nginx thật chạy trên cổng localhost tạm, xác minh
hai domain/ba route, SNI/cert riêng và giữ route khác sau reload; cần nginx/openssl.
