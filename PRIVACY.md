# Privacy & Data flow

TranslateMate được thiết kế tối thiểu hoá data thu thập. Dưới đây là toàn bộ những gì app làm với dữ liệu của bạn.

## Dữ liệu rời khỏi máy

Khi bạn bấm hotkey, **chỉ có đoạn text bạn bôi đen** được gửi qua HTTPS đến **OpenRouter** (https://openrouter.ai) để dịch. OpenRouter sau đó forward đến provider (Google, Anthropic, OpenAI, Meta, DeepSeek...) tuỳ model bạn chọn.

App không gửi:
- Tên app đang focus
- Bundle ID
- Tên người dùng / hostname
- Lịch sử dịch (chỉ lưu local)
- Bất kỳ telemetry nào

Header HTTP gửi đi:
- `Authorization: Bearer <api_key_của_bạn>`
- `Content-Type: application/json`
- `User-Agent: TranslateMate/1.0`
- `X-Title: TranslateMate` (chỉ để OpenRouter biết app nào gọi)

Body chỉ chứa: `{model, messages: [system_prompt, source_text], temperature, max_tokens}`.

## Dữ liệu lưu local

Tất cả ở chính máy của bạn, không sync cloud:

| Loại | Lưu tại | Có encrypt? |
|---|---|---|
| API key OpenRouter | Keychain (`Bundle.bundleIdentifier`) | Có (Keychain native) |
| Hotkey, target language, model, style | UserDefaults | Không (plaintext) |
| Lịch sử 50 bản dịch gần nhất | UserDefaults | Không (plaintext) |
| Log diagnostic 200 entry | RAM only (mất khi quit app) | N/A |

API key được lưu trong **Keychain**, không phải UserDefaults — không thể đọc nếu không có quyền của user đang đăng nhập.

Lịch sử dịch lưu plaintext trong UserDefaults vì đây là data bạn tự xem trong History tab. Nếu nhạy cảm, bạn có thể clear bất kỳ lúc nào (Settings → History → Clear all) hoặc chỉnh `maxHistory` trong code.

## Permissions yêu cầu

- **Accessibility** (Trợ năng) — đọc text đang chọn từ app khác và gõ phím tắt giả lập (Cmd+V). Không có Accessibility, app hoàn toàn không hoạt động.
- **Apple Events** — chỉ khi macOS hỏi (rất hiếm), để paste vào ô text trong vài app cũ.

App **KHÔNG** cần và **KHÔNG** request:
- Internet usage description (chỉ HTTPS đi ra)
- Camera, microphone, location
- Files & Folders
- Contacts, Calendar
- Full Disk Access

## Network endpoints

| Endpoint | Mục đích | Khi nào gọi |
|---|---|---|
| `POST openrouter.ai/api/v1/chat/completions` | Dịch text | Mỗi lần bấm hotkey |
| `GET openrouter.ai/api/v1/models` | Lấy list model | Lần đầu mở Settings + cache 24h |
| `GET openrouter.ai/api/v1/auth/key` | Validate API key | Khi user bấm "Validate key" |

Không có endpoint nào khác. Không có analytics, không có crash reporting bên thứ 3.

## Source code review

Toàn bộ network calls nằm trong file `OpenRouterClient.swift`. Bạn có thể đọc và verify đúng những gì mô tả ở trên — chỉ ~250 dòng code.
