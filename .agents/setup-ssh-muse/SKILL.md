---
name: setup-ssh-muse
description: Kết nối 1 máy Muse MỚI — tự cài điều kiện tiên quyết (Tailscale/sshd/TOFU), hỏi vài câu, sinh setup_prompt.md để dán sang máy Muse, chờ paste output của Muse rồi hoàn tất (sau đó `ssh <alias>` là vào được). Dùng khi người dùng gõ /setup-ssh-muse, "setup ssh muse", "kết nối máy Muse mới", "nối máy muse", "onboard máy Muse mới", "dán prompt vào Muse", "prompt một lần là xong", one-shot prompt, hoặc muốn agent tự setup 2 chiều với 1 container Muse mới.
argument-hint: "[ten-ssh] [--resume <alias>]"
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, AskUserQuestion
---

# /setup-ssh-muse — nối 1 máy Muse MỚI bằng 1 lần dán + 1 lần paste output

Bạn là **Agent Ngoài** (hợp đồng ở `LOCAL_AGENT.md`). Nhiệm vụ của lệnh này:

1. Chuẩn bị máy: **tự kiểm tra & cài điều kiện tiên quyết** (Tailscale, sshd, TOFU hook,
   sshd keepalive) — phần nào tự cài được thì agent tự cài, phần nào cần mật khẩu `sudo` thì
   đưa user đúng 1 lệnh và hỏi; xong hỏi user vài câu (tên SSH, cổng, profile Chrome).
2. Sinh **`setup_prompt.md`** — file để user gửi sang chat của máy Muse **mới tinh**.
3. **DỪNG** chờ user paste lại output (status block) mà máy Muse vừa báo — hoặc tự dán hộ
   (zero-touch) nếu user thích.
4. Từ output đó: authorize key của container, đẩy bundle, chờ kênh sống, xác nhận
   `ssh <alias>` vào được.

Gợi ý tên SSH do user gõ: `$ARGUMENTS` (rỗng = tự đặt).

## File thuộc skill này

| File | Vai trò |
|---|---|
| `SKILL.md` (file này) | **toàn bộ quy trình** agent ngoài làm — 7 chặng A→G |
| `reference/MUSE_PROMPT.template.md` | **prompt duy nhất** của repo, dán vào chat Muse. Sửa prompt = sửa file này rồi render lại |

> Skill này nằm thật trong `.agents/setup-ssh-muse/`; `.claude/skills` là **symlink → `.agents`** →
> agent tool khác (Codex, Cursor, OpenCode…) dùng chung được, không phải copy 2 bản.
>
> Không tự chế lệnh ngoài những lệnh repo có sẵn. Giao thức bus: `PROTOCOL.md`.

---

## Chặng A — Chuẩn bị (KHÔNG hỏi user, tự làm)

1. Xác định thư mục repo: thư mục chứa `scripts/bridge.sh`. Nếu không có `.git` → báo user
   và dừng.
2. Đọc `AGENTS.md` (bản đồ repo).
3. Kiểm tra prompt + helper có trong repo:
   ```bash
   ls .agents/setup-ssh-muse/reference/MUSE_PROMPT.template.md bridge/ts-connect-proxy.py
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
   Ghi nhận cảnh báo nào (TOFU / keepalive / sshd) → xử lý ở **Chặng A2**.

## Chặng A2 — Điều kiện tiên quyết (agent tự lo; chỉ hỏi user khi `sudo` cần mật khẩu)

Đây là phần agent **tự làm trước**, để sau đó user chỉ còn đúng 2 việc tay (dán prompt + paste
status block). Bốn thứ phải có:

| # | Cần | Kiểm tra | Tự cài được? |
|---|---|---|---|
| 1 | Tailscale (IP để container gọi về) | `tailscale ip -4` | ✗ — user cài + `tailscale up` |
| 2 | sshd nghe `:22` | `ss -tln \| grep ':22'` | ✓ `sudo -n systemctl enable --now ssh` |
| 3 | TOFU hook (container MỚI tự được pin key) | `test -f /etc/ssh/sshd_config.d/99-muse-bridge.conf` | ✓ `sudo -n bash scripts/install_tofu_hook.sh` |
| 4 | sshd keepalive (session treo tự nhả port) | `test -f /etc/ssh/sshd_config.d/98-muse-bridge-keepalive.conf` | ✓ `sudo -n bash scripts/install_sshd_keepalive.sh` |

**Vòng lặp — lặp tới khi đủ cả 4, mỗi vòng xác minh bằng file thật (không tin lời nói):**

1. `bash scripts/bridge.sh doctor` → đọc cảnh báo.
2. Mục nào thiếu mà **tự cài được** → chạy lệnh trong bảng với **`sudo -n`** (non-interactive: fail
   ngay nếu cần mật khẩu; **không** chạy `sudo` có mật khẩu → lệnh treo chờ nhập).
3. Mục **cần mật khẩu** → **hỏi user bằng `AskUserQuestion`**, đưa **đúng 1 lệnh** cần chạy:
   > `sudo bash scripts/install_tofu_hook.sh`  (hoặc `sudo bash scripts/install_sshd_keepalive.sh`)

   User báo "xong" → **chạy lại `bash scripts/bridge.sh doctor`** để xác minh. Còn thiếu → hỏi lại,
   không đi tiếp.
4. Tailscale: `tailscale ip -4` rỗng → bảo user `sudo tailscale up` + đăng nhập. Có IP → **in IP ra**
   cho user thấy (IP này nằm trong prompt dán sang Muse).

> **Phía container:** cell Muse MỚI cần node Tailscale riêng. Nếu Agent Muse báo "cần duyệt node"
> kèm link `login.tailscale.com` → bảo user mở link duyệt, rồi chạy lại
> `bash scripts/bridge.sh provision --host <alias>`.

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
- Điều kiện tiên quyết (Tailscale, sshd, TOFU, keepalive) đã xử lý ở **Chặng A2**. Chặng C chỉ
  chạy lệnh trên. Nếu A2 còn cảnh báo → **quay lại A2**, đừng đi tiếp: thiếu TOFU thì máy Muse
  **mới** không được sshd tự pin key → dán 1 lần sẽ hỏng ở Bước 3 của prompt.
- `add-host` tự viết khối `Host <alias>` vào `~/.ssh/config` → user `ssh <alias>` là vào.
- Cập nhật `setup_state.json`: `phase=armed`.

## Chặng D — Sinh `setup_prompt.md`

```bash
bash scripts/bridge.sh prompt --host <alias>
cp .muse-hosts/<alias>/MUSE_PROMPT.md setup_prompt.md
```

- `bridge.sh prompt` render từ `reference/MUSE_PROMPT.template.md` (prompt duy nhất của repo).
- `setup_prompt.md` nằm ở **gốc repo** và phải được `.gitignore` (chứa IP/user/pubkey máy
  này). Nếu chưa có trong `.gitignore` → báo user, đừng commit file này.
- Kiểm tra nhanh: `wc -c setup_prompt.md` (khoảng 17 KB) và
  `grep -c "{{" setup_prompt.md` phải bằng 0 (không còn placeholder).
- In ra: đường dẫn tuyệt đối + kích thước.
- Cập nhật `setup_state.json`: `phase=prompt_ready`, `prompt_path=<đường dẫn tuyệt đối>`.
- **Cách khác** (tuỳ chọn, chỉ khi user muốn): `bash scripts/bridge.sh prompt --host <alias>
  --send` tự dán prompt vào chat Muse qua driver web và chờ status block (tối đa ~10 phút,
  có thể treo). Driver tự bấm **Allow** cho hộp phê duyệt; nếu vẫn bị chặn thì báo user bấm tay —
  đừng giả vờ xong. Mặc định vẫn là user tự dán (bước 1–2 ở Chặng E).

## Chặng E — Bàn giao (hoặc tự dán) và **DỪNG**

Cập nhật `setup_state.json`: `phase=waiting_muse` (giữ `muse_output` rỗng).

**Hỏi user 1 câu bằng `AskUserQuestion`** — "Bạn tự dán prompt, hay để agent tự dán?"

| Chọn | Agent làm gì |
|---|---|
| **Để agent tự dán (zero-touch)** | `bash scripts/bridge.sh onboard --host <alias>` — tự dán qua driver web, tự bấm Allow, chờ status block, authorize key, đồng bộ port, provision. Xong → **nhảy thẳng sang bước 5–7 của Chặng F** (chờ `PEER_STATE=OK` + `SSH_OK`), user không phải paste gì |
| **Tôi tự dán** | flow bên dưới |

Zero-touch mà driver bị chặn → báo user bấm tay, **đừng giả vờ xong**; chuyển sang flow "tôi tự dán".

**Nếu user chọn "tôi tự dán"** → kết thúc lượt bằng đúng 3 điều:

1. File cần gửi: `<đường dẫn tuyệt đối của setup_prompt.md>` — user mở file đó, copy
   **toàn bộ nội dung**.
2. Dán vào **chat MỚI** của Agent Muse (chat sạch, không dùng lại chat cũ).
3. Muse sẽ báo **status block** gồm các dòng `MUSE_HOST`, `MUSE_KEY`, `MUSE_PUBKEY`,
   `MUSE_TUNNEL_PORT`, `MUSE_TUNNEL`, `MUSE_PERSISTENCE`, `MUSE_PROBE` → user **paste nguyên
   block** (giữ đúng tên `KEY=value`) vào lại đây.

⛔ **DỪNG NGAY** (ở nhánh "tôi tự dán"). Không tự đoán port, không tự gọi `provision`, không hỏi
thêm bằng `AskUserQuestion` — user sẽ tự paste output của Muse. Chỉ tiếp tục khi user paste.

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
   Nếu Muse **đã tự** kéo bundle và dựng tunnel thì `provision` chỉ chạy lại cho idempotent.
   Nếu Muse **chưa** kéo được bundle (Bước 4 của prompt lỗi) → `provision` là đường dự phòng:
   nó đẩy bus + watchdog + loop tunnel + deb cache xuống container, chạy `muse_side.sh setup`
   và authorize public key của container (để bus chạy được chiều Muse → máy tôi).
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
| "không qua kiểm tra an toàn" / từ chối nội dung | **Đừng dán lại.** Thử lại bằng `--send` (driver web tự dán, đôi khi qua được bộ lọc). Nếu vẫn bị chặn: prompt này **không chứa source code bus** → bộ lọc chỉ chặn vì **quá lớn** → rút gọn template: xoá khối **Bước 5b** (script dựng phòng ~50 dòng) và rút **Bước 4** xuống lệnh `tar` 1 dòng → prompt còn ~13 KB → `bash scripts/bridge.sh prompt --host <alias>` render lại rồi dán lại. Nếu vẫn bị chặn → **báo user**, không tự đoán. |
| `MUSE_PROBE=FAILED` | `bridge.sh status` + `bridge.sh doctor`; xem log container (`tail -20 <base>/tunnel/tunnel.log`) |
| `MUSE_TUNNEL=DOWN` | tunnel chưa lên → chờ cell platform tỉnh (thường tự lại trong ~25 phút) rồi `provision` lại |
| Không có output nào | nhắc user paste **nguyên status block**, hoặc dùng `--send` để tự dán lại |
| Muốn làm tự động hết (không paste tay) | `bash scripts/bridge.sh onboard --host <alias>` — tự dán prompt qua web, chờ status block, authorize key, provision |

> `onboard` làm đúng phần Chặng F bằng driver web: render prompt → gửi vào chat Muse mới → chờ
> status block → authorize `MUSE_PUBKEY` → provision → `PEER_STATE=OK`. Dùng khi user đã hỏi
> "làm hộ tôi luôn".

## `--resume`

Nếu user gọi `/setup-ssh-muse --resume <alias>`: đọc `.muse-hosts/<alias>/setup_state.json`
→ báo user đang ở chặng nào → tiếp tục đúng chặng đó (thường là Chặng F, chờ output của Muse).

## Luật cứng

- **Không hard-code** IP / user / pubkey / cổng / path của máy này — để script tự dò.
- **Đổi port = `bridge.sh set-port`**, không phải chạy lại `add-host` (xem Chặng F).
- **Sửa prompt = sửa template** `reference/MUSE_PROMPT.template.md` (trong skill này) rồi
  render lại; file đã render (`MUSE_PROMPT.md`, `setup_prompt.md`) là artifact, gitignore,
  không commit.
- `bash scripts/bridge.sh selftest` phải in `ALL TESTS: PASS` trước khi đi tiếp.
- **Chặng A2 phải sạch cảnh báo** (Tailscale / sshd / TOFU / keepalive) trước khi sang Chặng B —
  thiếu TOFU thì cell MỚI hỏng ở Bước 3 của prompt.
- **Không chạy `sudo` có mật khẩu** (sẽ treo chờ nhập). Chỉ dùng `sudo -n`; nếu cần mật khẩu →
  hỏi user bằng `AskUserQuestion` và đưa đúng 1 lệnh.
- **Không kill tunnel**, không `systemctl stop` service của Muse — kênh phải sống mãi.
- **Không bỏ qua Chặng E**: không tự nhảy sang provision khi user chưa paste output (trừ nhánh
  zero-touch mà user đã chọn ở Chặng E).
- Hỏi user bằng `AskUserQuestion` (click được), không hỏi bằng lời trong chat.
