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

Menu mới quản lý **Node + Nginx WSS 443**, thay menu NAT Proxy cũ:

- **2**: cài hoàn chỉnh binary (đủ geoip/geosite), node và WSS.
- **3/4/5**: thêm/sửa/xóa một website/node; giữ các node và tùy chọn khác.
- **6/7**: danh sách/trạng thái và Doctor kiểm tra API, WS, WSS, SNI/chứng chỉ.
- **8/9/10**: xem chứng chỉ, gia hạn và bật lịch tự gia hạn.
- **11/12/13**: cập nhật binary có SHA-256, sao lưu và khôi phục.
- **14/15/16/17**: tối ưu hàng đợi kết nối, gỡ node, nhập WSS cũ, mở TCP 443.

Sau lần cài đầu, dùng `v2node-manager` để mở menu. Xem hướng dẫn đầy đủ tại
[docs/node-manager.md](docs/node-manager.md).

```bash
# Cài hoàn chỉnh; API key được hỏi và ẩn khi nhập.
bash caidatserver.sh install --wss \
  --api-host https://panel-a.example.com --node-id 1 \
  --domain node-a.example.com --path /panel-a --backend-port 10001

# Thêm website thứ hai, dùng chung VPS/cổng công khai 443.
v2node-manager add \
  --api-host https://panel-b.example.com --node-id 1 \
  --domain node-b.example.com --path /panel-b --backend-port 10002

v2node-manager list
v2node-manager doctor --public
```

Panel phải lưu đúng cấu hình mà trình cài in ra: TLS bật, **TLS tại Nginx** bật,
WebSocket, Listen IP `127.0.0.1`, cổng dịch vụ riêng, cổng kết nối `443`, SNI/Host
đúng domain. Chọn chứng chỉ **File** và dùng cert/key trình quản lý tạo. Trình cài
đối chiếu qua API trước khi ghi cấu hình; API key node không có quyền sửa trang admin.

Chứng chỉ tự ký mới có hạn **365 ngày**. Tự gia hạn trước 30 ngày chỉ được bật khi
chọn menu 10 / `auto-renew`; ứng dụng ghim chứng chỉ cần cập nhật subscription khi
cert đổi. Chứng chỉ cũ được giữ nguyên. Chứng chỉ Let's Encrypt có sẵn được hỗ trợ
qua `--tls existing --cert-file ... --key-file ...`; công cụ ACME hiện có tiếp tục gia hạn.

VPS đang dùng `setup-wss-proxy.sh`: chọn **16** / `migrate` để nhập các vhost đúng mẫu
cũ sau khi chuyển chế độ cert trên panel sang File. Cổng, path, cert và thời hạn
được giữ nguyên. Vhost có chỉnh sửa riêng sẽ được giữ để kiểm tra thủ công.

Kiểm tra `101` xác nhận đường truyền WebSocket; chưa xác minh tài khoản proxy hay
khả năng truy cập Internet qua node. Firewall của nhà cung cấp cần cho phép TCP 443.

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
/usr/local/v2node/v2node version
```

Chạy server:

```bash
/usr/local/v2node/v2node server -c /etc/v2node/config.json
```

Tắt chế độ theo dõi file cấu hình nếu cần:

```bash
/usr/local/v2node/v2node server -c /etc/v2node/config.json -w=false
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
v2node-manager
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
