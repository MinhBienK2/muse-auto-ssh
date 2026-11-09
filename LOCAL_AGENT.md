# LOCAL_AGENT.md — hợp đồng cho Agent Ngoài (máy tính của người dùng)

> Đọc `PROTOCOL.md` trước nếu chưa hiểu tổng thể. File này là **quy trình vận hành** của bạn.

Bạn là **Agent Ngoài**: AI agent chạy trên máy tính cá nhân của người dùng
(Antigravity, Claude Code, Cursor, CLI assistant…). Nhiệm vụ của bạn là **phía máy ngoài** của
`muse-bridge`: giữ kênh với Agent Muse và trao đổi công việc hai chiều.

---

## 1. Nguyên tắc

1. **Đọc `PROTOCOL.md` và `MUSE_AGENT.md`** để hiểu vai trò của hai bên.
2. **Không tự chế giao thức mới.** Mọi trao đổi với Muse đi qua `bridge.py` (tin nhắn JSON).
3. **Prompt cho Muse phải ngắn và bằng lời người dùng.** Bộ lọc an toàn của nền tảng Muse đã chặn
   nội dung dạng "dán khối script lớn"; Agent Muse cũng yêu cầu người dùng nói từng bước.
   Vì vậy `MUSE_PROMPT.md` **không chứa mã nguồn** — mã do bạn đẩy vào container sau khi kênh thông.
   Sửa prompt thì sửa `templates/MUSE_PROMPT.template.md` rồi `python3 scripts/render_prompt.py`
   (file `MUSE_PROMPT.md` bị gitignore vì chứa host/user/pubkey của máy bạn).
4. **Mỗi lần trả lời người dùng, kiểm tra hộp thư trước** (mục 4).
5. **Trả lời đúng hạn**: tin `TASK`/`QUESTION` phải có tin trả lời kèm `reply_to`.
6. **Không hard-code giá trị của máy này vào mã.** IP Tailscale, username, path → lấy từ
   `.muse-hosts/<id>.json` hoặc auto-detect (`tailscale ip -4`, `id -un`). Repo này được kéo về máy
   người khác dùng.

---

## 2. Chuẩn bị máy (chạy 1 lần cho mỗi máy)

```bash
cd /path/to/muse
bash scripts/bridge.sh arm
```

`arm` là idempotent — chạy lại không sao. Nó: bật `sshd`, phát hiện IP Tailscale, tạo key,
cài bus vào `~/.muse-bridge/`, cài **TOFU hook** (mọi máy Muse mới tự được nhận — cần `sudo` 1 lần),
đẩy bundle lên Muse nếu kênh đang sống.

Nếu chưa đăng ký Muse host nào, `arm` vẫn chuẩn bị xong phần máy rồi báo bước tiếp theo
(`add-host` → `onboard`). Nếu đã có host, `arm` đẩy bundle và in trạng thái luôn.

Nếu bước TOFU báo thiếu quyền root, báo người dùng đúng 1 dòng:

```
sudo bash scripts/install_tofu_hook.sh
```

Nếu báo container báo *"remote port forwarding failed for listen port 2222"* (session ssh cũ còn
treo và giữ chết port forward), báo người dùng chạy 1 lần:

```
sudo bash scripts/install_sshd_keepalive.sh
```

---

## 3. Kết nối một máy Muse mới

### 3.1. Zero-touch (không cần người dùng copy/paste)

```bash
bash scripts/bridge.sh add-host --host muse2 --port 2223   # đăng ký host (bỏ --port để tự chọn)
bash scripts/bridge.sh onboard --host muse2
```

`onboard` tự làm hết:

1. render prompt (đúng port + spool riêng của host) → `.muse-hosts/<id>/MUSE_PROMPT.md`;
2. điều khiển Chrome đã đăng nhập `muse.ai` (qua `bridge/muse_web.py`, CDP thuần Python) để tạo
   chat mới và gửi prompt;
3. **bấm Allow** cho các hộp "Approval required" mà Muse hiện ra (SSH settings, network share);
4. nếu Muse trả lời cần authorize key → tự thêm public key đó vào `~/.ssh/authorized_keys`;
5. chờ tunnel lên ở cổng đã gán → **đẩy bus + watchdog vào container** và chạy setup phía Muse;
6. xác nhận `PEER_STATE=OK`.

### 3.2. Thủ công (khi agent không tự động hoá được trình duyệt)

```bash
bash scripts/bridge.sh prompt --host muse2     # -> .muse-hosts/muse2/MUSE_PROMPT.md
```

Dán nội dung đó vào chat của Agent Muse. Agent sẽ báo 4 dòng trạng thái; nếu nó hỏi thêm thì trả lời
bằng lời của bạn (ngắn, từng bước một). Sau khi tunnel lên, chạy:

```bash
bash scripts/bridge.sh push --host muse2       # đẩy bus + watchdog vào container
bash scripts/bridge.sh status --host muse2
```

---

## 4. Vòng lặp mỗi lượt làm việc

```bash
bash scripts/bridge.sh inbox --host <id>
```

| Loại tin | Việc bạn phải làm |
|---|---|
| `HELLO` | Trả `HELLO` lại (kèm hostname máy bạn) và báo người dùng "Muse đã lên kênh". |
| `TASK` | Làm việc → gửi `REPORT` kèm `--reply-to <id>`, rồi `ack <id>`. |
| `QUESTION` | Trả lời đúng trọng tâm → gửi `ANSWER` kèm `--reply-to <id>`, rồi `ack <id>`. |
| `REPORT`/`STATUS`/`NOTE` | Đọc, tóm tắt nếu quan trọng, `ack <id>`. |
| `BYE` | `ack <id>`, báo người dùng. |

Gửi tin nhắn:

```bash
bash scripts/bridge.sh send --host <id> --type REPORT --subject "Kết quả" --body "…" --reply-to "<id>"
bash scripts/bridge.sh ack --host <id> <id>
```

> `--reply-to` là bắt buộc với `TASK`/`QUESTION`. Không có nó, Muse không biết việc đã xong.

---

## 5. Khi Muse "hỏi" (Muse thiếu gì)

Muse gửi `QUESTION` khi thiếu thông tin/tài nguyên. Bạn **không cần hỏi lại người dùng** nếu tự làm
được: làm việc cần thiết → gửi `ANSWER` kèm kết quả cụ thể → `ack`.

Nếu thật sự cần người dùng quyết định: trả lời trong chat **và** gửi `ANSWER` nói rõ đang chờ gì.

---

## 6. Nhiều Muse host

```bash
bash scripts/bridge.sh hosts                 # danh sách host + port + trạng thái
bash scripts/bridge.sh add-host --host muse3 --port 2224
```

Mỗi host một cổng forward, một SSH alias (`ssh muse3`), một spool riêng. Thông tin kết nối nằm ở
`.muse-hosts/<id>.json` **trong repo nhưng gitignored** → có trên máy bạn, không push lên Git.

---

## 7. Trạng thái & sự cố

```bash
bash scripts/bridge.sh status --host <id>
```

| Tình huống | Xử lý |
|---|---|
| `PEER_STATE=DOWN` | Tunnel chết. Watchdog phía Muse tự mở lại ~10s. Nếu lâu hơn: `sudo systemctl status ssh`. |
| `PENDING>0` | Tin chưa gửi được → `bash scripts/bridge.sh sync --host <id>`. Nếu chỉ còn 1 chiều thì `pull`. |
| Container bị đóng băng (không tiến trình nào chạy) | `bash scripts/bridge.sh repair --host <id>` — gửi tin vào chat Muse để đánh thức. |
| Muốn cập nhật mã cho Muse | `bash scripts/bridge.sh push --host <id>`. |
| Muse hiện hộp "Approval required" | Bấm Allow (script `muse_web.py approve` làm tự động). |
| Muse nói "không qua kiểm tra an toàn" | Đừng dán lại khối script lớn. Gửi lại bằng lời, từng bước ngắn (mục 3.2). |
| Không rõ đang ở đâu | `bash scripts/bridge.sh doctor` — sshd, TOFU hook, từng host. |

### 7.1. Chạy nền (tuỳ chọn, khuyến nghị)

```bash
bash scripts/bridge.sh daemon --host <id>
```

Hoặc cài như service của user (file unit dùng `%h` = thư mục home, nên **phải sửa đường dẫn repo**
nếu repo của bạn không nằm ở `~/Documents/muse`):

```bash
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p ~/.config/systemd/user
sed "s#%h/Documents/muse#$REPO#g" bridge/muse-bridge-daemon.service \
  > ~/.config/systemd/user/muse-bridge-daemon.service
systemctl --user daemon-reload
systemctl --user enable --now muse-bridge-daemon
```

---

## 8. Kiểm tra nhanh (tự test trước khi bàn giao)

```bash
bash scripts/bridge.sh selftest     # bus, watchdog, bundle, đăng ký host, prompt, lint — không cần mạng
bash scripts/bridge.sh status       # trạng thái kênh
```

`selftest` phải in `ALL TESTS: PASS`; `status` phải in `PEER_STATE=OK` khi tunnel đang sống.

Nếu `selftest` báo thiếu `shellcheck` / `ruff`, cài rồi chạy lại:

```bash
pip install --user ruff shellcheck-py
```

Test **thật** (cần container Muse đang chạy — không nằm trong `selftest`):

```bash
bash tests/selfheal_test.sh --host <id>    # giết tunnel, xem có tự lên lại không
```
