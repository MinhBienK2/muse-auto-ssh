# CODING_STANDARDS.md — tiêu chuẩn cho reviewer

> File này dành cho **reviewer** (và cho implementer khi cần khớp style). Nó chỉ chứa những quyết
> định **cần phán đoán** — những thứ đã có thể kiểm tra tự động thì đã nằm trong guardrail
> (`scripts/check_prompt_sync.sh`, `tests/run_all.sh`, shellcheck, ruff), không lặp lại ở đây.

> **Điều kiện hoàn tất của một review:** mọi điểm dưới đây đã được áp dụng hoặc đã được biện minh
> là không liên quan. Mỗi mục có "cách kiểm tra" — nếu cách kiểm tra là lệnh, hãy chạy lệnh đó,
> đừng đoán.

---

## 1. Một nguồn sự thật

**Quy tắc.** Mỗi khái niệm chỉ có **một** nơi định nghĩa. Hai bản của cùng một file là lỗi, kể cả khi
bạn đang ở trong `legacy/`.

| Khái niệm | Nguồn duy nhất |
|---|---|
| Bus core (đọc/gửi tin) | `bridge/bridge.py` |
| Lệnh CLI phía máy ngoài | `scripts/bridge.sh` → `bridge/local_side.sh` |
| Lệnh CLI phía Muse | `bridge/muse_side.sh` |
| Driver trình duyệt | `bridge/muse_web.py` |
| Proxy helper | `bridge/ts-socat-proxy.sh` |
| Script loop tunnel | `bridge/reverse-tunnel.sh` |
| Prompt dán cho Muse | `templates/MUSE_PROMPT.template.md` |

**Cách kiểm tra.** `git ls-files | xargs grep -l <tên file>` — nếu tên file xuất hiện ở nhiều nơi
ngoài `legacy/`, đó là bản sao cần xoá hoặc thay bằng symlink.

**Đã có sẵn:** `legacy/templates/ts-socat-proxy.sh` là symlink tới `bridge/ts-socat-proxy.sh` — đây là
mẫu để copy.

## 2. Mọi thứ phải chạy được ở máy khác

**Quy tắc.** Repo này được kéo về máy người khác. Không file nào được chứa giá trị riêng của một
máy cụ thể: IP Tailscale, username, đường dẫn home, hostname, port cố định, email.

**Cách kiểm tra.** `bash scripts/check_hygiene.sh` — quét **mọi** file tracked (kể cả `legacy/`), tìm IP
ngoài dải riêng (loopback / RFC1918 / dải CGNAT của Tailscale được miễn), email thật, và đường dẫn
`/home/<tên-của-người-viết>`. Phải in `HYGIENE_CHECK: PASS`.

Giá trị runtime lấy từ: `tunnel-<port>.conf` (phía Muse), `.muse-hosts/<id>.json` (phía máy ngoài),
`--host/--user/--port` flag, hoặc auto-detect (`tailscale ip -4`, `id -un`).

**Ngoại lệ duy nhất:** `bridge/muse-bridge-daemon.service` dùng `%h` (home) — không phải đường dẫn
 tuyệt đối.

## 3. Prompt phải ngắn và không chứa mã

**Quy tắc.** `MUSE_PROMPT.md` là thứ người dùng **dán vào chat của Agent Muse**. Bộ lọc an toàn của
nền tảng đã chặn nội dung dạng "khối script lớn" (05/11, 06/11). Prompt phải:

- **ngắn** (< 12 KB);
- **không nhúng source code** của bus — code đi qua kênh SSH đã xác thực, sau khi kênh thông;
- **bằng lời**, mỗi bước một việc, để Agent Muse tự viết phần nó cần;
- nói rõ **đường dẫn file tuyệt đối** mà Agent Muse phải tạo (`/root/.ssh/...`), vì `~` của
  Agent Muse không phải `~` của sshd.

**Cách kiểm tra:** `bash scripts/check_prompt_sync.sh --strict`.

**Sửa prompt:** sửa `templates/MUSE_PROMPT.template.md`, rồi `python3 scripts/render_prompt.py`.
Không sửa `MUSE_PROMPT.md` (file này bị gitignore — nó chứa pubkey/IP của máy bạn).

## 4. Thay đổi giao thức = thay đổi `PROTOCOL.md` + version

**Quy tắc.** Đổi envelope, đổi tên loại tin, đổi layout spool → sửa `PROTOCOL.md` **và** tăng
`PROTOCOL_VERSION` trong `bridge/bridge.py`. Hai bên chạy lệch version là mất tin.

Thêm loại tin mới: thêm tên vào `MSG_TYPES` trong `bridge/bridge.py` **và** thêm hàng vào bảng loại
tin trong `PROTOCOL.md` mục 7. Sửa một trong hai = lỗi.

## 5. Idempotency và adopt-first

**Quy tắc.** Mọi lệnh setup phải chạy lại được mà không phá trạng thái đang chạy.

- Nếu tunnel đã lên (`pgrep -af "ssh -N -R <port>:"`) → **adopt**, không kill, không mở thêm.
- Ghi file bằng cách atomic: viết `<file>.tmp.$$` rồi `mv` — không ghi đè tại chỗ (container Muse
  có thể đang đọc file đó).
- Idempotency của script sinh ra phải được **kiểm tra bằng test**, không bằng niềm tin.

**Cách kiểm tra:** `tests/watchdog_upgrade_test.sh` (inject 2 lần → file không đổi),
`tests/muse_side_test.sh` (setup chạy 2 lần).

## 6. Test phải hermetic

**Quy tắc.** Test offline **không được** chạm vào trạng thái thật của máy: không đọc/ghi
`~/.ssh/config`, `~/.muse-bridge/`, không đọc `tailscale`, không ghi ra ngoài `$TMP`.

**Cách kiểm tra.** Chạy test với `HOME` và `MUSE_BRIDGE_STATE` trỏ vào thư mục tạm:

```bash
HOME=$(mktemp -d) MUSE_BRIDGE_STATE=$(mktemp -d) bash tests/run_all.sh
```

Phải PASS. Nếu FAIL → test đang đọc trạng thái thật (đó chính là lý do `hosts_test.sh` trước đây
"pass" trên máy tác giả nhưng "fail" trên máy khác — nó đọc `~/.muse-bridge/hosts/` thật).

**Quy ước assert:** dùng `ok <label> <command...>` / `rc <label> <code>` như trong
`tests/bus_selftest.sh`. **Không** dùng `check "label" $?` ngay sau một `[ ... ]` — `$?` bị ghi đè
bởi lệnh kế tiếp (shellcheck SC2319).

## 7. Không để lỗi im lặng trong đường lệnh phục hồi

**Quy tắc.** Đường phục hồi (rollback, fallback, restore) phải **báo cáo** khi không chạy được.
Một `&&` im lặng trong nhánh lỗi là bug chờ đợi.

**Cách kiểm tra:** shellcheck (`SC2144`, `SC2319`) + đọc từng nhánh `else`/`|| true` xem có in gì
không. Ví dụ `scripts/install_tofu_hook.sh`: restore config sshd dùng **biến** `$BACKUP`, không
dùng `[ -f "$CONF.bak."* ]` (glob với `-f` hỏng khi có ≥2 file backup → `too many arguments` →
restore bị bỏ qua âm thầm).

## 8. Ngôn ngữ và chú thích

- Comment và thông báo lỗi: **tiếng Việt không dấu** (khớp code hiện có — giữ nguyên để không
  tạo diff toàn repo). Doc (`*.md`): tiếng Việt có dấu.
- Comment giải thích **vì sao**, không giải thích **cái gì** (code đã nói rõ cái gì).
- Comment phải còn đúng sau khi code đổi. Comment mô tả hành vi đã bị bỏ = nên xoá.

## 9. Đừng để lại việc dở

**Quy tắc.** Một lần đồng thuận trong PR phải để lại code đúng, test xanh, doc đúng, không còn
TODO/stub/mock/no-op, và `git status` sạch (trừ file cố ý chưa track).

**Cách kiểm tra.**
```bash
bash scripts/bridge.sh selftest     # ALL TESTS: PASS (gồm check_hygiene.sh)
git status --short                  # khong co file sua chua commit
```
`check_hygiene.sh` đã quét `TODO|FIXME|XXX|not implemented` trong file tracked. Không có stub được
giữ lại "để sau". Việc chưa làm được thì **không làm** và nói rõ ra, chứ không để lại một hàm rỗng
trông như đã xong.
