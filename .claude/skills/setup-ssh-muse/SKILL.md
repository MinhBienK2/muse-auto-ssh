---
name: setup-ssh-muse
description: Kết nối 1 máy Muse MỚI — hỏi vài câu, sinh setup_prompt.md để dán sang máy Muse, chờ paste output của Muse rồi hoàn tất (sau đó `ssh <alias>` là vào được). Dùng khi người dùng gõ /setup-ssh-muse, "setup ssh muse", "kết nối máy Muse mới", "nối máy muse", "onboard máy Muse mới", hoặc muốn agent tự setup 2 chiều với 1 container Muse mới.
argument-hint: "[ten-ssh] [--resume <alias>]"
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, AskUserQuestion
---

# /setup-ssh-muse — nối 1 máy Muse MỚI bằng 1 lần dán + 1 lần paste output

Bạn là **Agent Ngoài** (hợp đồng ở `LOCAL_AGENT.md`). Nhiệm vụ của lệnh này:

1. Chuẩn bị máy + hỏi user vài câu (tên SSH, cổng, profile Chrome).
2. Sinh **`setup_prompt.md`** — file để user gửi sang chat của máy Muse **mới tinh**.
3. **DỪNG** chờ user paste lại output (status block) mà máy Muse vừa báo.
4. Từ output đó: authorize key của container, đẩy bundle, chờ kênh sống, xác nhận
   `ssh <alias>` vào được.

Gợi ý tên SSH do user gõ: `$ARGUMENTS` (rỗng = tự đặt).

> Tham chiếu: đọc `.claude/skills/muse-oneshot/SKILL.md` (quy trình agent) và
> `LOCAL_AGENT.md` §3.0 trước khi làm. Không tự chế lệnh ngoài những lệnh repo có sẵn.

---

## Chặng A — Chuẩn bị (KHÔNG hỏi user, tự làm)

1. Xác định thư mục repo: thư mục chứa `scripts/bridge.sh`. Nếu không có `.git` → báo user
   và dừng.
2. Đọc `AGENTS.md` + `.claude/skills/muse-oneshot/SKILL.md`.
3. Kiểm tra bản one-shot có trong repo:
   ```bash
   ls templates/MUSE_ONESHOT.template.md bridge/ts-connect-proxy.py
   ```
   Thiếu → repo đang ở nhánh cũ (`main`) → **báo user** (`git checkout feat/quickly-ssh`
   hoặc merge) và dừng. Đừng tự sửa template.
4. Guardrail:
   ```bash
   bash scripts/bridge.sh selftest
   ```
   Phải in `ALL TESTS: PASS`. Fail → báo user và **dừng** (không setup trên nền tảng hỏng).
5. ```bash
   bash scripts/bridge.sh doctor
   ```
   Ghi nhận 2 cảnh báo: TOFU hook và sshd keepalive.

## Chặng B — Hỏi user (dùng `AskUserQuestion`, hỏi 1 lần, 3 câu)

Hỏi bằng `AskUserQuestion` (user trả lời nhanh bằng click), **không** hỏi bằng lời trong chat:

1. **Tên SSH** (alias — sau này user gõ `ssh <alias>`).
   Mặc định gợi ý: `muse-001`; nếu alias đó đã có trong `~/.ssh/config` thì gợi ý
   `muse-002`, `muse-003`… (kiểm tra bằng `grep -c "^Host " ~/.ssh/config` và
   `bash scripts/bridge.sh hosts`).
2. **Cổng forward**: mặc định để trống → repo tự cấp cổng trống kế tiếp (`2222`, `2223`…).
3. **Profile Chrome**: `Default` (mặc định) hay `Profile 2` (account Muse khác).

Alias được dùng **làm host id** trong repo (`.muse-hosts/<alias>/`, spool, `~/.ssh/config`)
→ sau khi xong user gõ đúng `ssh <alias>` là vào container.

**Ghi lựa chọn vào file trạng thái NGAY BÂY GIỜ** (dùng tool `Write`, không dùng `cat >` trong
bash) — để session bị ngắt ở chặng nào cũng resume được:

```json
// .muse-hosts/<alias>/setup_state.json
{"phase": "asked", "alias": "<alias>", "port": "<port>", "profile": "<profile>",
 "prompt_path": "", "created": "<thoi diem>", "muse_output": ""}
```

Mỗi lần chuyển chặng → cập nhật lại `phase`: `asked` → `armed` → `prompt_ready` →
`waiting_muse` → `done`.

## Chặng C — Đăng ký host + chuẩn bị máy

```bash
bash scripts/bridge.sh arm                                        # sshd + key + bundle (deb cache)
bash scripts/bridge.sh add-host --host <alias> [--port <port>] --label "<alias>" \
     [--profile-dir "<profile>"]
```

- `--profile-dir` chỉ cần khi profile ≠ `Default` (account Muse khác).
- Nếu `doctor` báo **thiếu TOFU hook** hoặc **thiếu keepalive** → in đúng 2 lệnh này để user
  chạy (`sudo bash scripts/install_tofu_hook.sh`, `sudo bash scripts/install_sshd_keepalive.sh`)
  rồi **hỏi user bằng AskUserQuestion** "đã chạy xong chưa?" — không tự chạy sudo.
  Thiếu TOFU thì máy Muse **mới** không được sshd tự pin key → dán 1 lần sẽ hỏng ở Bước 3.
- `add-host` tự viết khối `Host <alias>` vào `~/.ssh/config` → user `ssh <alias>` là vào.
- Cập nhật `setup_state.json`: `phase=armed`.

## Chặng D — Sinh `setup_prompt.md`

```bash
bash scripts/bridge.sh oneshot --host <alias>
cp .muse-hosts/<alias>/MUSE_ONESHOT.md setup_prompt.md
```

- `setup_prompt.md` nằm ở **gốc repo** và phải được `.gitignore` (chứa IP/user/pubkey máy
  này). Nếu chưa có trong `.gitignore` → báo user, đừng commit file này.
- Kiểm tra nhanh: `wc -c setup_prompt.md` (khoảng 17 KB) và
  `grep -c "{{" setup_prompt.md` phải bằng 0 (không còn placeholder).
- In ra: đường dẫn tuyệt đối + kích thước.
- Cập nhật `setup_state.json`: `phase=prompt_ready`, `prompt_path=<đường dẫn tuyệt đối>`.

## Chặng E — Bàn giao và **DỪNG**

Cập nhật `setup_state.json`: `phase=waiting_muse` (giữ `muse_output` rỗng).

Sau đó **kết thúc lượt** bằng đúng 3 điều:

1. File cần gửi: `<đường dẫn tuyệt đối của setup_prompt.md>` — user mở file đó, copy
   **toàn bộ nội dung**.
2. Dán vào **chat MỚI** của Agent Muse (chat sạch, không dùng lại chat cũ).
3. Muse sẽ báo **status block** gồm các dòng `MUSE_HOST`, `MUSE_KEY`, `MUSE_PUBKEY`,
   `MUSE_TUNNEL_PORT`, `MUSE_TUNNEL`, `MUSE_PERSISTENCE`, `MUSE_PROBE` → user **paste nguyên
   block** (giữ đúng tên `KEY=value`) vào lại đây.

⛔ **DỪNG NGAY.** Không tự đoán port, không tự gọi `provision`, không hỏi thêm bằng
`AskUserQuestion` ở chặng này — user sẽ tự paste output của Muse. Chỉ tiếp tục khi user
paste.

## Chặng F — Khi user paste output của Muse

Parse các dòng `KEY=value` trong block user vừa paste (bỏ qua ``` fences và dòng văn
thường). Lưu nguyên block vào `setup_state.json` (`muse_output`).

1. `MUSE_PUBKEY` → authorize key của container ở máy này:
   ```bash
   bash scripts/bridge.sh authorize --host <alias> --key "<MUSE_PUBKEY>"
   ```
2. `MUSE_TUNNEL_PORT` → nếu **khác** cổng đã đăng ký: đổi port cho cả 3 chỗ (config, card,
   ssh alias) bằng lệnh chuyên dụng:
   ```bash
   bash scripts/bridge.sh set-port --host <alias> --port <MUSE_TUNNEL_PORT>
   ```
   rồi báo user (cổng đã đổi). Nếu giống → không làm gì.

   ⛔ **ĐỪNG chạy lại `add-host` để đổi port** — `add-host` ghi lại card từ đầu nên **mất field
   `thread`** (auto-repair dùng field này để đánh thức container) và **reset `web_profile_dir`
   về `Default`** (đổi account Chrome). `set-port` chỉ sửa đúng 3 chỗ, giữ nguyên phần còn lại.
3. `MUSE_TUNNEL=UP` / `MUSE_PROBE=OK` → đã có kênh. Vẫn chạy tiếp bước sau (idempotent).
4. Đẩy bundle + setup phía container (adopt-first, **không** kill tunnel):
   ```bash
   bash scripts/bridge.sh provision --host <alias>
   ```
5. Chờ kênh sống — poll mỗi 10 s, tối đa ~10 phút:
   ```bash
   bash scripts/bridge.sh status --host <alias>     # cần PEER_STATE=OK
   ```
6. Xác nhận cuối cùng (thứ user thực sự cần):
   ```bash
   ssh -o BatchMode=yes <alias> 'echo SSH_OK'
   ```
   Phải ra `SSH_OK`. Nếu chưa → xem `bash scripts/bridge.sh doctor` và log container.
7. Cập nhật `setup_state.json` (`phase=done`) và báo user:
   - `ssh <alias>` vào được,
   - đọc tin: `bash scripts/bridge.sh inbox --host <alias>`,
   - gửi tin: `bash scripts/bridge.sh send --host <alias> --type TASK --subject "…" --body "…"`,
   - tự giữ sống đã bật: systemd `Restart=always` + watchdog 15 s + loop reconnect 10 s.

## Chặng G — Khi Muse báo lỗi

| Muse báo | Xử lý |
|---|---|
| "không qua kiểm tra an toàn" / từ chối nội dung | **Đừng dán lại.** Chuyển sang bản ngắn: `bash scripts/bridge.sh prompt --host <alias>` rồi `bash scripts/bridge.sh onboard --host <alias>` |
| `MUSE_PROBE=FAILED` | `bridge.sh status` + `bridge.sh doctor`; xem log container (`tail -20 <base>/tunnel/tunnel.log`) |
| `MUSE_TUNNEL=DOWN` | tunnel chưa lên → chờ cell platform tỉnh (thường tự lại trong ~25 phút) rồi `provision` lại |
| Không có output nào | nhắc user paste **nguyên status block**, hoặc dùng `--send` để tự dán lại |

## `--resume`

Nếu user gọi `/setup-ssh-muse --resume <alias>`: đọc `.muse-hosts/<alias>/setup_state.json`
→ báo user đang ở chặng nào → tiếp tục đúng chặng đó (thường là Chặng F, chờ output của Muse).

## Luật cứng

- **Không hard-code** IP / user / pubkey / cổng / path của máy này — để script tự dò.
- **Đổi port = `bridge.sh set-port`**, không phải chạy lại `add-host` (xem Chặng F).
- **Sửa prompt = sửa template** `templates/MUSE_ONESHOT.template.md` rồi render lại; file đã
  render (`MUSE_PROMPT.md`, `MUSE_ONESHOT.md`, `setup_prompt.md`) là artifact, gitignore, không
  commit.
- `bash scripts/bridge.sh selftest` phải in `ALL TESTS: PASS` trước khi đi tiếp.
- **Không kill tunnel**, không `systemctl stop` service của Muse — kênh phải sống mãi.
- **Không bỏ qua Chặng E**: không tự nhảy sang provision khi user chưa paste output.
- Hỏi user bằng `AskUserQuestion` (click được), không hỏi bằng lời trong chat.
