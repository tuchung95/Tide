# Tide

macOS menu bar app: hiển thị tốc độ tải xuống/tải lên theo thời gian thực, kèm công cụ chụp ảnh màn hình (vùng chọn / cửa sổ / toàn màn hình) ngay trong menu.

## Tính năng

- Hiển thị tốc độ mạng dạng `↓ 1.2 MB/s  ↑ 128 KB/s` trực tiếp trên thanh menu bar, cập nhật mỗi giây.
- Tổng hợp lưu lượng từ các card mạng vật lý (Wi-Fi/Ethernet, `en*`), bỏ qua loopback và các interface ảo (VPN, bridge...) để tránh đếm trùng.
- Chụp ảnh màn hình từ menu:
  - **Selected Area…** — kéo chọn vùng để chụp.
  - **Window…** — nhấp vào một cửa sổ để chụp (kèm bóng đổ).
  - **Full Screen** — chụp toàn bộ màn hình ngay lập tức.
  - Mỗi lần chụp được lưu vào `~/Pictures/Tide Screenshots/` **và** tự động copy vào clipboard.
  - **Open Screenshots Folder** — mở thư mục lưu ảnh trong Finder.
- **Launch at Login** — bật/tắt tự khởi động cùng macOS (chỉ hoạt động khi chạy từ `.app` đã đóng gói, xem bên dưới).
- Không hiện icon trên Dock (`LSUIElement`), chỉ có mặt trên menu bar.

## Yêu cầu

- macOS 13 (Ventura) trở lên.
- Xcode Command Line Tools (có `swift`, `swiftc`, `codesign`).

> Lưu ý: mã nguồn này được viết trong môi trường không phải macOS nên chưa thể build/chạy thử tại đây. Hãy build trên máy Mac của bạn theo hướng dẫn dưới.

## Build & chạy nhanh (không cần Xcode UI)

```bash
swift run
```

Chạy trực tiếp bằng `swift run` sẽ hiện icon trên menu bar, nhưng **Launch at Login** sẽ không hoạt động (cần bundle identifier từ file `.app`).

## Đóng gói thành ứng dụng .app (khuyến nghị)

```bash
./Scripts/build_app.sh
```

Script sẽ:
1. Build bản release (`swift build -c release`).
2. Đóng gói thành `Tide.app` (kèm `Info.plist` với `LSUIElement=1`).
3. Ký ad-hoc bằng `codesign` để macOS cho phép chạy.

Sau đó kéo `Tide.app` vào `/Applications` và mở lên. Có thể bật **Launch at Login** ngay trong menu của app.

## Cấp quyền chụp màn hình

Lần đầu chụp ảnh, macOS sẽ hỏi quyền **Screen Recording** cho Tide (System Settings → Privacy & Security → Screen Recording). Bấm cho phép rồi thử chụp lại — không cần khởi động lại app trên macOS bản mới, nhưng nếu ảnh vẫn trống, hãy tắt/bật lại app.

## Cấu trúc mã nguồn

```
Sources/Tide/
  main.swift              # điểm khởi động, thiết lập NSApplication
  AppDelegate.swift        # status item, menu, vòng lặp cập nhật tốc độ
  NetworkMonitor.swift     # đọc getifaddrs, tính delta byte theo interface
  SpeedFormatter.swift     # định dạng B/s → KB/s → MB/s → GB/s
  ScreenshotManager.swift  # bọc lệnh /usr/sbin/screencapture
  LoginItemManager.swift   # bật/tắt Launch at Login qua SMAppService
Resources/Info.plist       # metadata bundle, LSUIElement=1 (ẩn Dock icon)
Scripts/build_app.sh       # build release + đóng gói .app + ký ad-hoc
```

## Tùy biến

- Đổi khoảng cập nhật tốc độ: sửa `withTimeInterval: 1.0` trong `AppDelegate.swift`.
- Đổi thư mục lưu ảnh chụp: sửa `screenshotsDirectory` trong `ScreenshotManager.swift`.
- Đổi bộ lọc interface mạng (mặc định chỉ tính `en*`): sửa `interfacePrefix` trong `NetworkMonitor.swift`.
