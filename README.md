# Tide

macOS menu bar app: hiển thị tốc độ tải xuống/tải lên theo thời gian thực, kèm công cụ chụp ảnh màn hình (vùng chọn / cửa sổ / toàn màn hình) ngay trong menu.

Tạo bởi **Louis Chung**.

## Tính năng

- Hiển thị tốc độ mạng dạng 2 dòng xếp chồng (`↑ 13 KB/s` trên, `↓ 1.6 MB/s` dưới) trực tiếp trên thanh menu bar, cập nhật mỗi giây.
- Tổng hợp lưu lượng từ các card mạng vật lý (Wi-Fi/Ethernet, `en*`), bỏ qua loopback và các interface ảo (VPN, bridge...) để tránh đếm trùng.
- Đầu menu hiển thị **tên nhà mạng + địa chỉ IP công cộng** hiện tại, dạng `{{tên nhà mạng}} {{IP}}` (vd. `VNPT Corp 14.161.12.83`) — đây là IP WAN do ISP cấp, không phải IP LAN nội bộ. Lấy qua API công khai `ipinfo.io` (HTTPS), chỉ gọi 1 lần mỗi lần mở app (retry ở lần mở menu kế tiếp nếu lần đầu lỗi) để hạn chế gửi request. Lưu ý: việc tra cứu này gửi IP công khai của bạn tới `ipinfo.io`.
- Chụp ảnh màn hình từ menu — **Selected Area… / Window… / Full Screen**:
  - Mỗi chức năng có 2 đích **độc lập, dùng song song được**: lưu file `.png` vào `~/Desktop` và/hoặc copy vào clipboard. Bật cả hai thì chụp 1 lần ra cả file lẫn clipboard; chỉ bật 1 trong 2 thì chỉ làm đúng việc đó (không tạo file thừa khi chỉ muốn copy — dùng thẳng `screencapture -c`). Bật/tắt trong **Settings…**.
  - Sau khi chụp thành công, menu bar nhấp nháy **"✓ Saved"**, **"✓ Copied"**, hoặc **"✓ Saved & Copied"** (tuỳ đích nào đang bật) kèm âm thanh ngắn (`Resources/CaptureSound.mp3`) trong ~1.2s rồi tự trở về hiển thị tốc độ mạng.
  - Mỗi mục hiển thị luôn phím tắt hiện tại của nó bên cạnh tên (vd. `Selected Area…    ⌃⇧4`).
- **Settings…** — cửa sổ cài đặt dạng sidebar-tabs (giống System Settings), chia theo chức năng:
  - **General**: **Launch at Login** — bật/tắt tự khởi động cùng macOS (chỉ hoạt động khi chạy từ `.app` đã đóng gói, xem bên dưới); hiển thị version hiện tại + nút **Check for Updates…**.
  - **Screenshot**: với mỗi chức năng (Selected Area / Window / Full Screen) — 2 checkbox **Save**/**Copy** độc lập (không cho tắt cả hai cùng lúc), "Restore Defaults" riêng cho nhóm này.
  - **Shortcuts**: ô ghi phím tắt **toàn cục** cho từng chức năng, bấm được ở bất kỳ đâu trên macOS mà không cần mở menu Tide trước, không cần cấp quyền Accessibility. Mặc định `⌃⇧3/4/5` (Full Screen/Selected Area/Window) — chọn Control thay vì Command để không đụng phím tắt chụp ảnh có sẵn của macOS. Bấm vào ô để ghi lại tổ hợp mới, Esc để huỷ, Delete để xoá, "Restore Defaults" riêng cho nhóm này.
- **Tự động cập nhật**: mỗi lần mở app tự kiểm tra ngầm bản mới trên GitHub Releases (im lặng nếu đã là bản mới nhất); có bản mới thì hỏi cài luôn — tải file `.zip` đính kèm release, giải nén, thay thế `/Applications/Tide.app`, và tự khởi động lại. Cũng kiểm tra được thủ công qua nút **Check for Updates…** trong Settings → General. Xem mục "Phát hành & tự động cập nhật" bên dưới.
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
2. **Tự tăng version patch** (đọc/ghi `Resources/VERSION`, vd. `1.0.1` → `1.0.2`) và ghi vào `CFBundleShortVersionString`/`CFBundleVersion` của bundle.
3. Đóng gói thành `Tide.app` (kèm `Info.plist` với `LSUIElement=1`).
4. Ký bằng `codesign` — dùng certificate `Tide Local Dev` nếu máy đã có (xem mục dưới), nếu không thì tự rơi về ký ad-hoc.
5. **Tự động cài đè vào `/Applications`** (quit bản đang chạy nếu có, copy, mở lại). Không tự chạy script này thì `/Applications/Tide.app` sẽ là bản cũ — quan trọng vì macOS gắn quyền Screen Recording theo đúng file `.app` đang chạy, chạy nhầm bản cũ ở `/Applications` trong khi test bản mới ở thư mục dev là lý do phổ biến nhất khiến quyền "biến mất" sau mỗi lần sửa code.
6. **Publish GitHub Release** (`vX.Y.Z`) — zip bản build bằng `ditto`, commit + push `Resources/VERSION`, và `gh release create` đính kèm zip. Bước này chạy best-effort: lỗi mạng/`gh` chưa đăng nhập chỉ in cảnh báo, không làm hỏng phần build + cài local đã xong ở bước 5.

> **Vì sao không dùng `swift build` / `swift run`?** SwiftPM cần `xcrun --show-sdk-platform-path`, chỉ có khi cài Xcode.app đầy đủ (không có trong Command Line Tools riêng lẻ). Nếu máy bạn có Xcode.app, `swift run` vẫn dùng được bình thường để chạy nhanh khi phát triển — nhưng khi đó **Launch at Login** sẽ không hoạt động vì thiếu bundle identifier từ file `.app`, và app chạy ở một đường dẫn tạm khác `/Applications` nên cũng không liên quan gì đến quyền Screen Recording đã cấp cho bản `/Applications`.

Có thể bật **Launch at Login** trong menu **Settings…** của app.

## Cấp quyền chụp màn hình

Lần đầu chụp ảnh, macOS sẽ hỏi quyền **Screen Recording** cho Tide (System Settings → Privacy & Security → Screen Recording). Bấm cho phép rồi thử chụp lại — không cần khởi động lại app trên macOS bản mới, nhưng nếu ảnh vẫn trống, hãy tắt/bật lại app.

### Giữ quyền Screen Recording qua các lần rebuild

Ký **ad-hoc** (`codesign --sign -`) sinh chữ ký từ hash của chính binary, nên **đổi mỗi khi build lại**. macOS TCC (hệ quản lý quyền riêng tư) gắn quyền theo cả chữ ký, không chỉ tên app — nên mỗi lần rebuild, Tide bị coi là "app khác" và bị hỏi cấp quyền Screen Recording lại từ đầu, dù bản cũ đã được cấp quyền.

Để tránh việc này khi phát triển (rebuild nhiều lần), tạo một certificate ký ổn định **một lần duy nhất**, `build_app.sh` sẽ tự dùng nếu tìm thấy:

```bash
# Tạo key + certificate self-signed (Code Signing), tên "Tide Local Dev"
openssl genrsa -out tide_dev.key 2048
cat > tide_dev.cnf << 'EOF'
[req]
distinguished_name = dn
x509_extensions = v3_ext
prompt = no

[dn]
CN = Tide Local Dev

[v3_ext]
basicConstraints = critical,CA:true
keyUsage = critical,digitalSignature,keyCertSign
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
openssl req -x509 -new -nodes -key tide_dev.key -sha256 -days 3650 -out tide_dev.cer -config tide_dev.cnf

# Import vào keychain và tin cậy cho code signing
security import tide_dev.key -k ~/Library/Keychains/login.keychain-db -A -T /usr/bin/codesign
security import tide_dev.cer -k ~/Library/Keychains/login.keychain-db -A -T /usr/bin/codesign
security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db tide_dev.cer

# Xác nhận đã nhận diện được
security find-identity -v -p codesigning
```

Sau khi có certificate này, `build_app.sh` sẽ tự động ký bằng nó (kiểm tra qua `security find-identity`) và cài đè vào `/Applications`. Lần build đầu tiên sau khi đổi từ ad-hoc sang certificate mới vẫn sẽ bị hỏi quyền lại **một lần cuối** (vì chữ ký thay đổi khác hẳn ad-hoc trước đó), nhưng từ đó về sau mọi lần rebuild sẽ giữ nguyên quyền vì chữ ký (`Authority=Tide Local Dev`) không đổi. Kiểm tra chữ ký bản đang chạy bằng `codesign -dv /Applications/Tide.app`.

**Nếu vẫn bị hỏi quyền dù chữ ký không đổi:** kiểm tra có đang chạy nhầm bản khác không — `ps aux | grep Tide.app` xem process thật sự đang chạy từ đường dẫn nào, phải là `/Applications/Tide.app`. Quyền Screen Recording gắn theo đúng file `.app` đang chạy; nếu vẫn còn một bản `Tide.app` cũ (chữ ký khác) nằm ở nơi khác và được mở lên, nó sẽ luôn bị hỏi lại độc lập với bản `/Applications`.

## Phát hành & tự động cập nhật

Mỗi lần `./Scripts/build_app.sh` chạy xong, nó **tự publish một GitHub Release public** (`https://github.com/tuchung95/Tide/releases`) kèm file `Tide-vX.Y.Z.zip`. App đang chạy trên máy khác (hoặc máy này ở lần mở tiếp theo) sẽ tự phát hiện qua `UpdateChecker` (gọi `api.github.com/repos/tuchung95/Tide/releases/latest`, so `CFBundleShortVersionString`) và hỏi cài bản mới.

- **Không cần chạy riêng lệnh publish** — chỉ cần `./Scripts/build_app.sh` là vừa build local vừa phát hành. Vì vậy mỗi lần rebuild trong lúc phát triển cũng tạo một release mới; đây là hành vi được yêu cầu rõ ràng, không phải side-effect ẩn.
- Cách cập nhật khi phát hiện bản mới (`Sources/Tide/UpdateInstaller.swift`): tải file `.zip` đính kèm release → giải nén bằng `ditto` → spawn một shell script tách rời (`sleep 1; rm -rf /Applications/Tide.app; cp -R <bản mới> /Applications/Tide.app; open ...`) → app tự `NSApp.terminate` để script kịp thay thế rồi mở lại. Không cần Sparkle hay framework ngoài — chỉ URLSession + `/usr/bin/ditto` + `/bin/sh`.
- Vì app hiện ký bằng certificate self-signed (`Tide Local Dev`, không phải Developer ID của Apple) và chưa notarize, macOS Gatekeeper sẽ không tự động tin cậy các máy khác tải bản `.zip` này về — chỉ phù hợp dùng nội bộ giữa các máy đã tự thêm và tin cậy cùng certificate này (xem mục cấp quyền Screen Recording bên trên).

### Cài trên một máy Mac khác

1. Vào [github.com/tuchung95/Tide/releases/latest](https://github.com/tuchung95/Tide/releases/latest), tải file `Tide-vX.Y.Z.zip` đính kèm.
2. Giải nén, kéo `Tide.app` vào `/Applications`.
3. Lần mở đầu tiên sẽ bị Gatekeeper chặn ("Apple không thể kiểm tra phần mềm độc hại…") — vì file tải qua trình duyệt bị gắn cờ quarantine và app ký bằng certificate tự tạo, không phải của Apple. Vượt qua bằng 1 trong 2 cách:
   - Chuột phải (hoặc Control-click) vào `Tide.app` → **Open** → xác nhận **Open** trong hộp thoại.
   - Hoặc: System Settings → Privacy & Security → cuộn xuống thấy dòng "Tide was blocked from use because it is not from an identified developer" → bấm **Open Anyway**.
4. Chỉ cần làm bước 3 **một lần duy nhất** cho lần cài đầu. Các bản cập nhật sau đó qua **Check for Updates…** trong app tự tải bằng `URLSession` (không gắn cờ quarantine như tải qua trình duyệt) nên không bị Gatekeeper chặn lại nữa.

> Muốn máy đó không bị chặn ngay cả ở bước 3 (ví dụ định cài đi cài lại nhiều lần để test), copy `tide_dev.key`/`tide_dev.cer` sang máy đó và làm lại đúng các bước ở mục "Giữ quyền Screen Recording qua các lần rebuild" bên trên — máy đó sẽ nhận diện app ký bằng cùng certificate quen thuộc.

## Cấu trúc mã nguồn

```
Sources/Tide/
  main.swift              # điểm khởi động, thiết lập NSApplication
  AppDelegate.swift        # status item, menu, vòng lặp cập nhật tốc độ
  NetworkMonitor.swift     # đọc getifaddrs, tính delta byte theo interface
  SpeedFormatter.swift     # định dạng B/s → KB/s → MB/s → GB/s
  ScreenshotManager.swift  # bọc lệnh /usr/sbin/screencapture, hỗ trợ file/clipboard/cả hai
  LoginItemManager.swift   # bật/tắt Launch at Login qua SMAppService
  KeyCombo.swift           # model phím tắt + lưu trữ UserDefaults
  CaptureSettings.swift    # toggle Save/Copy độc lập cho từng chức năng chụp
  HotKeyManager.swift      # đăng ký phím tắt toàn cục qua Carbon Event Manager
  ShortcutRecorderControl.swift  # ô ghi phím tắt (click rồi bấm tổ hợp)
  SettingsWindowController.swift # cửa sổ "Settings…" dạng sidebar-tabs (General/Screenshot/Shortcuts)
  PublicNetworkInfo.swift  # tra cứu IP công cộng + tên nhà mạng qua ipinfo.io
  UpdateChecker.swift      # gọi GitHub Releases API, so version hiện tại với bản mới nhất
  UpdateInstaller.swift    # tải + giải nén + thay thế /Applications/Tide.app + relaunch
Resources/Info.plist       # metadata bundle, LSUIElement=1 (ẩn Dock icon)
Resources/AppIcon.icns     # icon ứng dụng (hiện trong Finder/Launchpad)
Resources/CaptureSound.mp3 # âm thanh phát khi chụp ảnh thành công
Resources/VERSION          # version hiện tại, build_app.sh tự tăng mỗi lần build
Scripts/build_app.sh       # build release + đóng gói .app + ký + cài /Applications + publish release
```

## Tùy biến

- Đổi khoảng cập nhật tốc độ: sửa `withTimeInterval: 1.0` trong `AppDelegate.swift`.
- Đổi cỡ chữ / kiểu hiển thị stack: sửa `statusFont` và hàm `stackedTitle(up:down:font:)` trong `AppDelegate.swift`.
- Đổi thư mục lưu ảnh chụp: sửa `screenshotsDirectory` trong `ScreenshotManager.swift`.
- Đổi bộ lọc interface mạng (mặc định chỉ tính `en*`): sửa `interfacePrefix` trong `NetworkMonitor.swift`.
