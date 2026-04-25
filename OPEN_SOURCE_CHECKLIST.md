# Open-source checklist

Những điều cần làm trước khi public repo + những điều người dùng cần biết khi clone về dùng.

## Cho người release (bạn)

### Trước khi push lên GitHub

- [ ] **Đổi `BUNDLE_ID` trong `build.sh`** thành prefix của bạn hoặc generic. Hiện đang là `com.tuanduong.translatemate`. Nếu để nguyên thì user clone về phải tự đổi.
- [ ] **Đổi copyright trong `LICENSE`** từ "Tuấn Dương" sang tên bạn / project.
- [ ] **Đổi `CERT_NAME`** trong `build.sh` nếu muốn (hiện là `"TranslateMate Local Dev"` — dùng được cho ai cũng OK).
- [ ] **Verify không có API key sót**: `grep -ri "sk-or-v1-" .` phải trả empty.
- [ ] **Verify không có thông tin cá nhân**: `grep -ri "duongtuanvn\|tuanduong" .` để check.
- [ ] **Test build từ scratch**: `rm -rf build && ./build.sh run` phải work.
- [ ] **Update README.md** với screenshots, demo GIF nếu có.
- [ ] **Tạo GitHub release** với DMG đã sign (`./build.sh dmg`) - user có thể download chạy ngay.
- [ ] **Add LICENSE, PRIVACY, .gitignore** (đã có sẵn trong repo).

### Cảnh báo về Apple Developer

- App build ra với **self-signed cert** chỉ chạy được trên máy của user đó (không distribute được qua Mac App Store, không qua được Gatekeeper trên máy người khác nếu họ download).
- Nếu muốn release DMG cho người khác download: cần **Apple Developer ID ($99/năm)** + notarization. Không cần thiết cho personal use.
- Hướng dẫn alternative: user download source và `./build.sh run` sẽ tự sign với cert tự ký trên máy họ.

### Optional nice-to-have

- [ ] Tạo `CONTRIBUTING.md` nếu muốn nhận PR.
- [ ] Setup GitHub Actions CI để check build pass mỗi PR.
- [ ] Thêm screenshots vào README.
- [ ] Tạo issue templates.
- [ ] Thêm `CHANGELOG.md`.

## Cho người dùng (clone về dùng)

Liệt kê trong README để user biết. Họ cần:

### Yêu cầu bắt buộc

1. **macOS 13.0 trở lên** (vì dùng `SMAppService` cho Launch at Login).
2. **Xcode hoặc Command Line Tools**: `xcode-select --install`.
3. **OpenRouter API key**: đăng ký free tại https://openrouter.ai/keys. Free models đủ cho dịch hằng ngày.
4. **Quyền Accessibility**: macOS sẽ hỏi lần đầu chạy. Bắt buộc, app không hoạt động nếu không có.

### Customization khuyến nghị

User clone về có thể đổi:

- **`BUNDLE_ID`** trong `build.sh` thành unique của họ (`com.<your_name>.translatemate`). Ngăn xung đột nếu nhiều user trên cùng máy hoặc CI/CD.
- **`APP_NAME`** trong `build.sh` nếu muốn rebrand.
- **Hotkey defaults** trong `HotkeyShortcut.swift` (`.default` và `.popupDefault`). Hiện default ⌘D và ⌘⇧T.
- **Default model** trong `SettingsStore.swift`. Hiện là `deepseek/deepseek-chat-v3-0324:free`.
- **Default fallback chain** trong `SettingsStore.defaultFallbackModels`.
- **`AppLanguageStore.suggestedLanguages`** nếu không nói tiếng Việt.

### Workflow setup (recommended)

```bash
# Clone
git clone https://github.com/<your-username>/TranslateMate
cd TranslateMate

# (Tuỳ chọn) Đổi BUNDLE_ID trong build.sh sang của bạn
# vim build.sh   # đổi BUNDLE_ID="com.yourname.translatemate"

# Setup self-signed cert một lần (tránh re-grant Accessibility mỗi rebuild)
./build.sh setup-cert

# Build và mở
./build.sh run

# Hoặc install vào /Applications/ để có shortcut + permanent grant
./build.sh install
open /Applications/TranslateMate.app
```

### Lần đầu chạy

1. macOS sẽ hỏi quyền **Accessibility** → System Settings → Privacy → Accessibility → bật cho TranslateMate.
2. App tự mở Settings vì chưa có API key → paste OpenRouter key.
3. Tab Translation → click "Refresh" để fetch list models hiện có → chọn 1 free model.
4. Test trong Notes: gõ "Xin chào", Cmd+A, ⌘D (hoặc hotkey bạn config).

### Lưu ý hotkey conflict

Một số hotkey có thể bị app khác chiếm:
- ⌘D: Telegram (Mute), Safari (Bookmark), Finder (Duplicate)
- ⌘T: nhiều app dùng cho New Tab
- ⌘E: nhiều app dùng cho Find with Selection

Nếu hotkey không fire (log không có "Hotkey triggered"), đổi sang tổ hợp ít xung đột:
- **⌘⌥E** (Cmd+Option+E)
- **⌘⌥T** (Cmd+Option+T)
- **⌃⌥⌘Space**
- **F13/F14** (function keys nếu có)

### Troubleshooting

Xem `README.md` → section "Troubleshooting" để biết các lỗi phổ biến và fix.

## Files quan trọng

```
TranslateMate/
├── LICENSE                    # MIT
├── PRIVACY.md                 # Data flow & permissions
├── OPEN_SOURCE_CHECKLIST.md   # File này
├── README.md                  # Overview, install, usage
├── .gitignore                 # Bỏ build/, .DS_Store, *.p12...
├── build.sh                   # Build script (chính)
└── TranslateMate/             # Swift sources (12 files)
    ├── *.swift
    ├── Info.plist
    └── TranslateMate.entitlements
```

## Tóm tắt

- App tự dùng → không cần làm gì thêm, push lên private repo cũng được.
- Public repo cá nhân → add LICENSE + PRIVACY + .gitignore là đủ.
- Public repo nghiêm túc → cần Apple Developer ID để DMG distribute được.
