# Hướng dẫn sử dụng TranslateMate (User Guide)

Chào mừng bạn đến với **TranslateMate** — Ứng dụng dịch thuật trực tiếp ngay trên mọi cửa sổ làm việc của macOS, tận dụng sức mạnh của các AI tiên tiến thông qua OpenRouter.

Tài liệu này sẽ hướng dẫn bạn cách cài đặt, thiết lập và sử dụng TranslateMate hiệu quả nhất.

---

## 1. Cài đặt ứng dụng

### Bước 1: Tải về
Bạn có thể tải phiên bản mới nhất của ứng dụng (`.dmg`) từ mục **Releases** trên GitHub của dự án.
- [Tải TranslateMate v1.0.0 (.dmg)](https://github.com/duongtuanvn/TranslateMate/releases/latest/download/TranslateMate-1.0.dmg)

### Bước 2: Cài đặt & Xử lý cảnh báo bảo mật
1. Mở file `.dmg` vừa tải về, kéo thả icon **TranslateMate** vào thư mục **Applications**.
2. **LƯU Ý QUAN TRỌNG**: Vì TranslateMate là ứng dụng mã nguồn mở và được đóng gói cục bộ (ad-hoc signing) nên khi mở lần đầu, Gatekeeper của macOS có thể chặn và báo lỗi: *"App is damaged and can't be opened"* (Ứng dụng bị hỏng).
   **Cách khắc phục:**
   - Mở ứng dụng **Terminal** (nhấn `Cmd + Space` gõ Terminal).
   - Nhập lệnh sau và nhấn Enter:
     ```bash
     sudo xattr -cr /Applications/TranslateMate.app
     ```
   - Nhập mật khẩu máy Mac của bạn khi được yêu cầu (mật khẩu sẽ không hiển thị khi gõ).
   - Sau đó, bạn có thể mở ứng dụng TranslateMate bình thường.

### Bước 3: Cấp quyền Accessibility (Trợ năng)
Để TranslateMate có thể đọc và viết thay thế đoạn văn bản bạn đang bôi đen trên các ứng dụng khác, nó cần quyền **Accessibility**.
1. Mở TranslateMate từ thư mục Applications hoặc Spotlight.
2. macOS sẽ hiện thông báo yêu cầu quyền Trợ năng.
3. Bấm vào **Open System Settings** (hoặc vào *System Settings > Privacy & Security > Accessibility*).
4. Bật công tắc bên cạnh **TranslateMate**.

---

## 2. Thiết lập API Key (Bắt buộc)

TranslateMate kết nối với hơn 30 mô hình AI (Gemini, Claude, Llama, DeepSeek...) qua **OpenRouter**. Bạn cần có API Key để sử dụng.

1. Truy cập [OpenRouter Keys](https://openrouter.ai/keys) và đăng nhập (có thể dùng tài khoản Google).
2. Bấm **Create Key** để tạo một API key mới. Đặt tên (ví dụ: `TranslateMate`) và copy dãy mã (bắt đầu bằng `sk-or-v1-`).
3. Nhấp vào icon hình 🌐 của TranslateMate trên thanh Menu Bar (góc trên bên phải màn hình), chọn **Settings...**
4. Trong tab **General**, dán mã vừa copy vào ô **OpenRouter API Key**.
5. Bấm **Validate key** để kiểm tra. Nếu hiển thị chữ "Valid" xanh lá cây là thành công.

*(Lưu ý: OpenRouter cung cấp rất nhiều mô hình **hoàn toàn miễn phí** để bạn sử dụng hằng ngày).*

---

## 3. Cách sử dụng ứng dụng

Sau khi thiết lập xong, bạn có thể dịch bất kỳ đoạn văn bản nào trên mọi ứng dụng (Notes, Telegram, Slack, Word, Trình duyệt...).

TranslateMate cung cấp hai chế độ sử dụng chính:

### Chế độ Thay thế (Replace Mode) - Mặc định: `⌘D`
Dùng khi bạn muốn **viết tin nhắn tiếng Việt** và muốn nó biến thành tiếng Anh trước khi gửi.
- **Cách dùng:** Gõ tin nhắn -> Bôi đen đoạn text đó -> Bấm tổ hợp phím `Cmd + D`.
- **Kết quả:** Đoạn tiếng Việt của bạn sẽ bị xóa đi và được tự động gõ đè bản dịch tiếng Anh vào vị trí đó chỉ sau 1 giây.

### Chế độ Cửa sổ nổi (Popup Mode) - Mặc định: `⌘⇧T`
Dùng khi bạn đang **đọc tài liệu/tin nhắn** tiếng nước ngoài và muốn hiểu nghĩa.
- **Cách dùng:** Bôi đen đoạn text cần hiểu -> Bấm tổ hợp phím `Cmd + Shift + T`.
- **Kết quả:** Một cửa sổ nhỏ (HUD) sẽ nổi lên hiển thị bản dịch tiếng Việt. Bấm phím `Esc` hoặc click chuột ra ngoài để đóng.

*(Ứng dụng có tính năng **Auto Language Swap**: Nếu cài đặt ngôn ngữ đích là English, nhưng đoạn bôi đen đã là English, ứng dụng sẽ tự động dịch nó sang Vietnamese).*

---

## 4. Tùy chỉnh nâng cao (Settings)

Bạn có thể mở cửa sổ Cài đặt bằng cách bấm vào biểu tượng 🌐 trên Menu Bar -> **Settings...**

### Tab General (Cài đặt chung)
- **Hotkeys**: Nhấp chuột vào ô phím tắt hiện tại và bấm tổ hợp phím mới nếu bạn muốn thay đổi `⌘D` hoặc `⌘⇧T` thành phím khác tránh trùng lặp.
- **Translate to**: Thiết lập ngôn ngữ đích mặc định cho từng chế độ.
- **Launch at login**: Bật tính năng này để ứng dụng tự chạy khi khởi động máy Mac.
- **Always use clipboard paste**: Giữ mặc định BẬT để tương thích với các ứng dụng như Telegram, Discord.

### Tab Translation (Dịch thuật)
- **Model**: Chọn AI Model bạn muốn dùng. Nhấn **Refresh** để lấy danh sách các mô hình miễn phí (Free) mới nhất từ OpenRouter. 
  - Khuyên dùng: `deepseek/deepseek-chat-v3-0324:free` hoặc `google/gemini-2.5-flash-lite`.
- **Style**: Chọn văn phong (Natural, Literal, Casual, Formal).
- **Custom instructions**: Bạn có thể ra lệnh riêng cho AI. Ví dụ: *"Giữ nguyên biểu tượng cảm xúc. Dùng văn phong chat thân thiện."*
- **Fallback Models**: Khi mô hình chính bị quá tải (Rate limit - mã lỗi 429), ứng dụng sẽ tự động chuyển qua thử các mô hình trong danh sách dự phòng này. Bạn nên thêm 3-4 mô hình Free vào đây.

### Tab History (Lịch sử)
Xem lại 50 bản dịch gần nhất, chi tiết Model đã sử dụng và **Chi phí (Cost)** ước tính quy ra tiền Việt. Bạn có thể Click chuột phải vào một dòng để copy lại văn bản gốc hoặc bản dịch.

---

## 5. Khắc phục sự cố (Troubleshooting)

### Phím tắt không hoạt động
- Đảm bảo bạn đã bôi đen text trước khi bấm.
- Có thể tổ hợp phím `⌘D` bị ứng dụng khác chiếm (ví dụ: Bookmark của Safari). Hãy vào **Settings > General** để đổi sang phím khác như `⌘⌥E` (Cmd + Option + E) hoặc `⌃⌥⌘Space`.

### Đã cấp quyền Accessibility nhưng app vẫn báo "NOT granted"
Do bạn đã cập nhật phiên bản mới, macOS bị nhầm lẫn quyền cũ.
- Mở Terminal và gõ: `sudo xattr -cr /Applications/TranslateMate.app`
- Sau đó vào System Settings -> Privacy -> Accessibility, chọn TranslateMate và bấm nút dấu trừ **"-"** để xóa nó đi.
- Mở lại ứng dụng TranslateMate để macOS hỏi quyền lại từ đầu.

### Bôi đen trên Telegram, dịch xong nhưng text không đổi
Telegram dùng nhân Electron nên đôi lúc không cho phép ghi đè văn bản trực tiếp. TranslateMate đã có cơ chế copy-paste tự động (Clipboard fallback). Hãy đảm bảo bạn **BẬT** tùy chọn *Always use clipboard paste* trong mục **Settings > General**.

### Ứng dụng báo lỗi "All fallback models exhausted"
Đây là do API OpenRouter giới hạn số lần gọi (Rate limit) cho các mô hình miễn phí. 
- Cách khắc phục: Đợi một vài phút để hạn mức được reset, hoặc vào tab Translation thêm nhiều mô hình Free khác vào danh sách **Fallback Models**. Nếu bạn dùng nhiều, hãy nạp $1-$2 vào OpenRouter để dùng các mô hình trả phí (Giá cực kỳ rẻ, khoảng vài đồng/tin nhắn).

---

Nếu có bất kỳ thắc mắc nào, hãy mở tab **Diagnostics** trong Settings để xem Log chi tiết và báo cáo lỗi (Issue) trên [GitHub Repository](https://github.com/duongtuanvn/TranslateMate/issues).

Chúc bạn có trải nghiệm tuyệt vời với **TranslateMate**!
