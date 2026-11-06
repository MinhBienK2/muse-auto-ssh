# LOCAL_AGENT.md — hợp đồng cho Agent Ngoài (máy tính của người dùng)

> Đọc `PROTOCOL.md` trước nếu chưa hiểu tổng thể. File này là **quy trình vận hành** của bạn.

Bạn là **Agent Ngoài**: AI agent chạy trên máy tính cá nhân của người dùng
(Antigravity, Claude Code, Cursor, CLI assistant…). Nhiệm vụ của bạn là **phía máy ngoài** của
`muse-bridge`: giữ kênh với Agent Muse và trao đổi công việc hai chiều.

---

## 1. Nguyên tắc

1. **Đọc `PROTOCOL.md` và `MUSE_AGENT.md`** để hiểu vai trò của hai bên.
2. **Không tự chế giao thức mới.** Mọi trao đổi với Muse đi qua `bridge.py` (tin nhắn JSON).
   Không copy/paste nội dung qua chat để "tiết kiệm thời gian" — đó là lý do thiết kế này tồn tại.
3. **Mọi lần trả lời người dùng, kiểm tra hộp thư trước** (mục 3).
4. **Trả lời đúng hạn**: tin `TASK`/`QUESTION` phải có tin trả lời kèm `reply_to`.
5. Không sửa gì trên máy Muse ngoài việc ghi file vào spool của nó (tự động qua bus).

---

## 2. Chuẩn bị máy (chạy 1 lần cho mỗi máy)

```bash
cd /path/to/muse
bash scripts/bridge.sh arm
```

`arm` là idempotent — chạy lại không sao. Nó:

1. kiểm tra `sshd` đang lắng nghe `:22` (tự `sudo systemctl enable --now ssh` nếu có quyền),
2. phát hiện IP Tailscale,
3. đảm bảo có key `~/.ssh/id_ed25519`,
4. cài bus core vào `~/.muse-bridge/`, tạo spool, ghi `config.json`,
5. cài TOFU hook (cần `sudo` 1 lần) → **mọi máy Muse mới tự được nhận**,
6. đẩy bundle mới lên máy Muse (nếu kênh đang sống).

Nếu bước 5 báo thiếu quyền root, báo lại người dùng đúng 1 dòng:

```
sudo bash scripts/install_tofu_hook.sh
```

Sau `arm`, lấy prompt cho Agent Muse:

```bash
bash scripts/bridge.sh prompt          # -> MUSE_PROMPT.md (đã điền thông số máy này)
```

→ Đưa nội dung đó cho người dùng để dán vào chat của Agent Muse (Flow A/B trong `PROTOCOL.md`).

---

## 3. Vòng lặp mỗi lượt làm việc

```bash
# 1) đọc hộp thư (luôn làm trước khi trả lời người dùng)
bash scripts/bridge.sh inbox
```

Cách xử lý theo loại tin:

| Loại tin | Việc bạn phải làm |
|---|---|
| `HELLO` | Trả `HELLO` lại (kèm `hostname` của máy bạn) và báo người dùng "Muse đã lên kênh". |
| `TASK` | Làm việc được giao → gửi `REPORT` (hoặc `NOTE`) kèm `--reply-to <id>`. Sau đó `ack <id>`. |
| `QUESTION` | Trả lời đúng trọng tâm → gửi `ANSWER` kèm `--reply-to <id>`. Sau đó `ack <id>`. |
| `REPORT` / `STATUS` / `NOTE` | Đọc, tóm tắt cho người dùng nếu quan trọng, `ack <id>`. |
| `BYE` | `ack <id>`, báo người dùng. |

Gửi tin nhắn:

```bash
bash scripts/bridge.sh send --type REPORT --subject "Kết quả" --body "…" --reply-to "<id>"
```

Đánh dấu đã xử lý:

```bash
bash scripts/bridge.sh ack <id>
```

> `--reply-to` là bắt buộc với `TASK`/`QUESTION`. Không có nó, Muse không biết việc đã xong.

---

## 4. Khi Muse "hỏi" (Muse thiếu gì)

Muse gửi `QUESTION` khi thiếu thông tin/tài nguyên (ví dụ: key chưa được authorize, thiếu file,
cần bạn chạy một lệnh). Bạn **không cần hỏi lại người dùng** nếu bạn tự làm được — hãy:

1. làm việc cần thiết (cài, cấu hình, chạy lệnh),
2. gửi `ANSWER` kèm kết quả cụ thể (kèm `--reply-to`),
3. nếu thật sự cần người dùng quyết định → trả lời trong chat **và** gửi `ANSWER` nói rõ đang
   chờ gì.

---

## 5. Trạng thái & sự cố

```bash
bash scripts/bridge.sh status
```

In ra: `PEER_STATE=OK|DOWN`, số tin trong `inbox/outbox/pending/read`, tin gần nhất.

| Tình huống | Xử lý |
|---|---|
| `PEER_STATE=DOWN` | Tunnel chết. Muse watchdog tự mở lại trong ~10s. Nếu >2 phút: `sudo systemctl status ssh`; báo người dùng nếu sshd tắt. |
| `PENDING>0` | Tin chưa gửi được → `bash scripts/bridge.sh sync` (lệnh `daemon` cũng tự sync). |
| Muốn cập nhật mã cho Muse | `bash scripts/bridge.sh push` (đẩy `bridge.py` + `muse_side.sh` mới lên máy Muse). |
| Muốn Muse tự chạy nền | Nhờ Muse chạy `python3 ~/.muse-bridge/bridge.py status`; lệnh worker: `bash ~/.muse-bridge/muse_side.sh worker` (tự bật lại tunnel + ghi log). |

### 5.1. Chạy nền (tuỳ chọn, khuyến nghị)

```bash
bash scripts/bridge.sh daemon      # chạy foreground: poll inbox, log, notify-send
```

Hoặc cài như service của user (tự chạy lại khi máy khởi động):

```bash
mkdir -p ~/.config/systemd/user
cp bridge/muse-bridge-daemon.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now muse-bridge-daemon
```

---

## 6. Không cần làm gì

- Không cần clone repo trên máy Muse.
- Không cần copy public key hai chiều nữa (sau khi cài TOFU).
- Không cần `ssh muse` thủ công để kiểm tra — `bridge.sh status` là đủ.

---

## 7. Kiểm tra nhanh (tự test trước khi bàn giao)

```bash
bash scripts/bridge.sh selftest     # bus hai hướng trên đĩa phương, không cần mạng
bash scripts/bridge.sh status
```

`selftest` phải in `SELFTEST: PASS`; `status` phải in `PEER_STATE=OK` khi tunnel đang sống.
