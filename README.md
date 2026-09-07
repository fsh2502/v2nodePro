# v2nodePro

`v2nodePro` là backend node cho V2Board, được xây dựng trên nền `xray-core` đã được chỉnh sửa.

Tên repository là `v2nodePro`, nhưng tên binary và service hệ thống hiện tại vẫn là `v2node`.

## Tổng quan

Project này kết nối node với panel V2Board tương thích, lấy cấu hình node và danh sách người dùng từ panel, sau đó khởi tạo và quản lý tiến trình Xray ở phía máy chủ.

Các chức năng chính:

- Lấy cấu hình node từ API của panel
- Lấy danh sách người dùng và trạng thái online
- Báo cáo lưu lượng và người dùng online về panel
- Tự động reload khi file cấu hình thay đổi
- Hỗ trợ `pprof` để debug khi cần
- Có sẵn script cài đặt và quản lý service trên Linux

## Giao thức hỗ trợ

Theo phần triển khai hiện tại trong code, panel có thể trả về các giao thức sau:

- `vmess`
- `vless`
- `trojan`
- `shadowsocks`
- `hysteria2`
- `tuic`
- `anytls`

Runtime hiện tại cũng hỗ trợ các thiết lập liên quan đến TLS, Reality và chứng chỉ được điều khiển từ panel.

## Yêu cầu

- Go `1.26+` nếu build từ source
- Một panel V2Board tương thích
- Máy chủ Linux nếu bạn dùng script cài đặt đi kèm

Lưu ý:

- Project này đang gọi các endpoint như `/api/v2/server/config` và `/api/v1/server/UniProxy/*`
- Vì vậy trên thực tế bạn nên dùng panel tương thích hoặc bản V2Board đã được chỉnh sửa phù hợp với API này

## Cài đặt nhanh

Cài bằng script đi kèm:

```bash
wget -N https://raw.githubusercontent.com/fsh2502/v2nodePro/main/script/install.sh && bash install.sh
```

## Cài đặt nâng cao

```bash
wget -N https://raw.githubusercontent.com/fsh2502/v2nodePro/main/script/caidatserver.sh && bash caidatserver.sh
```

Trong menu, chọn **17** để cấu hình nhanh một domain WSS dùng cổng công khai `443`.
Script sẽ tạo chứng chỉ tự ký 30 năm, cấu hình Nginx và in đúng các giá trị cần nhập
trong v2Pro. Mỗi website dùng một domain, một WebSocket path và một cổng nội bộ riêng.

Cũng có thể chạy thẳng, không cần nhập qua menu:

```bash
curl -fsSL https://raw.githubusercontent.com/fsh2502/v2nodePro/main/script/setup-wss-proxy.sh \
  -o /tmp/setup-wss-proxy.sh && \
bash /tmp/setup-wss-proxy.sh node-a.example.com /node-a 10001
```

Chạy lại lệnh với domain, path và cổng khác để thêm website thứ hai. Trong v2Pro,
giữ cổng kết nối `443`, bật TLS, chọn WebSocket và bật **TLS tại Nginx**. v2node
chỉ lắng nghe WS tại `127.0.0.1:<cổng nội bộ>` nhưng vẫn báo vân tay của đúng chứng
chỉ mà Nginx đang sử dụng.

**Với nhiều domain:** nhập Server Name (SNI) và WebSocket Host đúng domain kết nối
của từng node; tắt Disable SNI và `acceptProxyProtocol`. Mỗi domain dùng đúng cặp
cert/key mà script in ra. Domain API của panel không phải domain kết nối node.
Thiếu SNI có thể làm client nhận chứng chỉ của domain đầu tiên trên cổng 443.

Script mới giữ các path đã tạo khi thêm path khác trên cùng domain, kiểm tra
trùng cổng trong các cấu hình do script quản lý và dừng nếu Nginx báo trùng
`server_name`. Mỗi panel/node vẫn phải được thêm vào mảng `Nodes` trong
`/etc/v2node/config.json` (menu 11).

Chẩn đoán một node (chỉ đọc cấu hình và kiểm tra kết nối):

```bash
curl -fsSL https://raw.githubusercontent.com/fsh2502/v2nodePro/main/script/diagnose-wss.sh -o /tmp/diagnose-wss.sh && \
bash /tmp/diagnose-wss.sh node-b.example.com /node-b 10002
```

Hai bước trả `101` xác nhận WS backend và WSS qua Nginx. Lệnh chưa kiểm tra tài
khoản VPN hay đường DNS/CDN từ thiết bị người dùng.

Cài và tạo luôn file cấu hình:

```bash
bash install.sh --api-host https://your-panel.example.com --node-id 1 --api-key your_api_key
```

Đường dẫn cấu hình mặc định sau khi cài đặt:

```bash
/etc/v2node/config.json
```

## Cấu hình

Ví dụ cấu hình tối thiểu:

```json
{
  "Log": {
    "Level": "warning",
    "Output": "",
    "Access": "none"
  },
  "Nodes": [
    {
      "ApiHost": "https://your-panel.example.com",
      "NodeID": 1,
      "ApiKey": "your_api_key",
      "Timeout": 15
    }
  ],
  "PprofPort": 0
}
```

Giải thích các trường:

- `Log.Level`: mức log như `debug`, `info`, `warn`, `error`
- `Log.Output`: đường dẫn file log, để trống sẽ ghi ra stdout
- `Log.Access`: access log của Xray, dùng `none` để tắt
- `Nodes`: danh sách node cần tải từ panel
- `Nodes[].ApiHost`: địa chỉ panel
- `Nodes[].NodeID`: ID node trên panel
- `Nodes[].ApiKey`: API key của node
- `Nodes[].Timeout`: thời gian timeout request tính bằng giây
- `PprofPort`: cổng debug local, đặt `0` để tắt

## Chạy thủ công

Xem phiên bản:

```bash
v2node version
```

Chạy server:

```bash
v2node server -c /etc/v2node/config.json
```

Tắt chế độ theo dõi file cấu hình nếu cần:

```bash
v2node server -c /etc/v2node/config.json -w=false
```

## Build từ source

Build theo đúng module path hiện tại của repository:

```bash
GOEXPERIMENT=jsonv2 go build -v -o build_assets/v2node -trimpath -ldflags "-X 'github.com/fsh2502/v2nodePro/cmd.version=$version' -s -w -buildid="
```

Build đơn giản ở local:

```bash
GOEXPERIMENT=jsonv2 go build -o v2node .
```

## Quản lý service

Nếu bạn cài bằng script đi kèm, có thể quản lý nhanh bằng:

```bash
v2node
```

Hoặc thao tác trực tiếp bằng `systemd`:

```bash
systemctl status v2node
systemctl restart v2node
journalctl -u v2node.service -e --no-pager -f
```

## Cấu trúc project

- `cmd/`: điểm vào CLI
- `conf/`: nạp cấu hình và theo dõi thay đổi file
- `api/v2board/`: client giao tiếp với panel
- `core/`: khởi tạo runtime Xray và handler động
- `node/`: logic điều phối node
- `script/`: script cài đặt và quản lý

## Ghi chú

- Module path hiện tại là `github.com/fsh2502/v2nodePro`
- Runtime vẫn gửi `node_type=v2node`
- Đường dẫn cấu hình mặc định trên môi trường chạy thực tế là `/etc/v2node/config.json`

## Giấy phép

Xem tại [LICENSE](LICENSE).
