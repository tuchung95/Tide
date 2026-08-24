# Tide

macOS menu bar app: hiển thị tốc độ tải xuống/tải lên theo thời gian thực, kèm công cụ chụp ảnh màn hình (vùng chọn / cửa sổ / toàn màn hình) ngay trong menu.

## Tính năng

- Hiển thị tốc độ mạng dạng 2 dòng xếp chồng (`↑ 13 KB/s` trên, `↓ 1.6 MB/s` dưới) trực tiếp trên thanh menu bar, cập nhật mỗi giây.
- Tổng hợp lưu lượng từ các card mạng vật lý (Wi-Fi/Ethernet, `en*`), bỏ qua loopback và các interface ảo (VPN, bridge...) để tránh đếm trùng.
- Đầu menu hiển thị **tên nhà mạng + địa chỉ IP công cộng** hiện tại, dạng `{{tên nhà mạng}} {{IP}}` (vd. `VNPT Corp 14.161.12.83`) — đây là IP WAN do ISP cấp, không phải IP LAN nội bộ. Lấy qua API công khai `ipinfo.io` (HTTPS), chỉ gọi 1 lần mỗi lần mở app (retry ở lần mở menu kế tiếp nếu lần đầu lỗi) để hạn chế gửi request. Lưu ý: việc tra cứu này gửi IP công khai của bạn tới `ipinfo.io`.
- Chụp ảnh màn hình từ menu:
  - **Selected Area…** — kéo chọn vùng để chụp.
  - **Window…** — nhấp vào một cửa sổ để chụp (kèm bóng đổ).
  - **Full Screen** — chụp toàn bộ màn hình ngay lập tức.
  - Mỗi lần chụp được lưu vào `~/Desktop` **và** tự động copy vào clipboard.
  - Sau khi copy thành công, menu bar nhấp nháy **"✓ Copied"** kèm âm thanh ngắn trong ~1.2s rồi tự trở về hiển thị tốc độ mạng.
  - Mỗi mục hiển thị luôn phím tắt hiện tại của nó bên cạnh tên (vd. `Selected Area…    ⌃⇧4`).
- **Keyboard Shortcuts…** — cài phím tắt **toàn cục** riêng cho từng chức năng chụp ảnh (Selected Area / Window / Full Screen), bấm được ở bất kỳ đâu trên macOS mà không cần mở menu Tide trước, không cần cấp quyền Accessibility. Mặc định: `⌃⇧3` (Full Screen), `⌃⇧4` (Selected Area), `⌃⇧5` (Window) — chọn tổ hợp Control thay vì Command để không đụng phím tắt chụp ảnh có sẵn của macOS. Bấm vào ô để ghi lại tổ hợp mới, Esc để huỷ, Delete để xoá, hoặc "Restore Defaults" để khôi phục.
- **Launch at Login** — bật/tắt tự khởi động cùng macOS (chỉ hoạt động khi chạy từ `.app` đã đóng gói, xem bên dưới).
- Không hiện icon trên Dock (`LSUIElement`), chỉ có mặt trên menu bar.

## Yêu cầu

- macOS 13 (Ventura) trở lên.
- Xcode Command Line Tools (có `swift`, `swiftc`, `codesign`) — **không cần** cài Xcode.app đầy đủ.

> Đã build và chạy thử thành công trên macOS thật (chỉ có Command Line Tools, không có Xcode.app).

## Đóng gói thành ứng dụng .app (khuyến nghị)

```bash
./Scripts/build_app.sh
```

Script sẽ:
1. Compile trực tiếp bằng `swiftc` (không dùng `swift build`).
2. Đóng gói thành `Tide.app` (kèm `Info.plist` với `LSUIElement=1`).
3. Ký ad-hoc bằng `codesign` để macOS cho phép chạy.

Sau đó `open Tide.app` để chạy thử ngay tại chỗ, hoặc kéo vào `/Applications`.

> **Vì sao không dùng `swift build` / `swift run`?** SwiftPM cần `xcrun --show-sdk-platform-path`, chỉ có khi cài Xcode.app đầy đủ (không có trong Command Line Tools riêng lẻ). Nếu máy bạn có Xcode.app, `swift run` vẫn dùng được bình thường để chạy nhanh khi phát triển — nhưng khi đó **Launch at Login** sẽ không hoạt động vì thiếu bundle identifier từ file `.app`.

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
  KeyCombo.swift           # model phím tắt + lưu trữ UserDefaults
  HotKeyManager.swift      # đăng ký phím tắt toàn cục qua Carbon Event Manager
  ShortcutRecorderControl.swift  # ô ghi phím tắt (click rồi bấm tổ hợp)
  ShortcutsWindowController.swift # cửa sổ "Keyboard Shortcuts…"
  PublicNetworkInfo.swift  # tra cứu IP công cộng + tên nhà mạng qua ipinfo.io
Resources/Info.plist       # metadata bundle, LSUIElement=1 (ẩn Dock icon)
Resources/AppIcon.icns     # icon ứng dụng (hiện trong Finder/Launchpad)
Scripts/build_app.sh       # build release + đóng gói .app + ký ad-hoc
```

## Tùy biến

- Đổi khoảng cập nhật tốc độ: sửa `withTimeInterval: 1.0` trong `AppDelegate.swift`.
- Đổi cỡ chữ / kiểu hiển thị stack: sửa `statusFont` và hàm `stackedTitle(up:down:font:)` trong `AppDelegate.swift`.
- Đổi thư mục lưu ảnh chụp: sửa `screenshotsDirectory` trong `ScreenshotManager.swift`.
- Đổi bộ lọc interface mạng (mặc định chỉ tính `en*`): sửa `interfacePrefix` trong `NetworkMonitor.swift`.
