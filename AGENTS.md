# AGENTS.md — bản đồ repo `muse-bridge`

> File này được nạp vào context của **mọi agent làm việc trong repo này**. Nó chỉ là **bản đồ trỏ
> tới**, không lặp lại nội dung của các file khác. Đọc đúng 1-2 file theo việc bạn đang làm.

## Bạn đang làm gì? Đọc file nào

| Việc | Đọc file này |
|---|---|
| Hiểu giao thức (envelope, loại tin, spool, trust) | [`PROTOCOL.md`](PROTOCOL.md) |
| Chạy phía **máy của người dùng** (đọc/gửi tin, đăng ký Muse host) | [`LOCAL_AGENT.md`](LOCAL_AGENT.md) |
| Chạy phía **container Muse** (bus, watchdog, tự phục hồi) | [`MUSE_AGENT.md`](MUSE_AGENT.md) |
| Sửa **prompt dán cho Muse** | [`templates/MUSE_PROMPT.template.md`](templates/MUSE_PROMPT.template.md) → render bằng `python3 scripts/render_prompt.py` |
| Đọc **tiêu chuẩn code** (khi review hoặc khi phải khớp style) | [`CODING_STANDARDS.md`](CODING_STANDARDS.md) |
| Cài đặt lần đầu / người dùng mới | [`README.md`](README.md) |

## Bốn điều bắt buộc

1. **Một nguồn mã.** `bridge/bridge.py` là bus core dùng chung cho cả hai bên. Sửa nó thì phải
   `bash scripts/bridge.sh push --host <id>` để đồng bộ lên container — hai bên phải chạy **cùng
   phiên bản**, lệch version là mất tin.
2. **Prompt là artifact sinh ra.** Không sửa `MUSE_PROMPT.md` bằng tay (nó còn bị `.gitignore` vì
   chứa host/user/pubkey của máy bạn). Sửa `templates/MUSE_PROMPT.template.md` rồi render lại.
3. **Thông tin kết nối không vào git.** IP Tailscale, username, public key, đường dẫn máy → nằm ở
   `.muse-hosts/` (đã gitignore) hoặc runtime config, **không** hard-code trong file tracked và
   **không** commit.
4. **Không chạy lệnh sửa file bằng `sed`/`python` trong `bash`.** Dùng tool sửa file. Lý do: repo
   này có nhiều file shell lớn, thay thế chuỗi bằng script là nguồn gốc của hàng loạt vòng
   "fix" lặp lại.

## Guardrail — chạy trước khi bàn giao

```bash
bash scripts/bridge.sh selftest      # toàn bộ test offline + shellcheck + ruff
```

Phải in `ALL TESTS: PASS`. Cài thêm tool nếu báo thiếu:

```bash
pip install --user ruff shellcheck-py
```

`selftest` chạy offline, không cần mạng, không cần container Muse. Test **thật** (cần container):
`bash tests/selfheal_test.sh --host <id>`.

Pre-commit hook đã có ở `.githooks/pre-commit`; bật cho repo local:

```bash
git config core.hooksPath .githooks
```

## Vài cái bẫy đã tốn thời gian trước đây

- `sshd` trong container Muse chạy user `root` → nó đọc `/root/.ssh/authorized_keys`, **không phải**
  `~/.ssh/authorized_keys` của user `hatch`. Sửa cả hai.
- Container không ra ngoài thẳng được → phải qua HTTP CONNECT proxy `hatch-egress-proxy` **cổng 3130**,
  **không cần user:pass** (cổng 3128 thì cần token, đừng dùng).
- Key SSH của container nằm ở **`/home/hatch/.ssh/id_ed25519`**, không phải `/root/.ssh/` (thư mục đó
  bị xoá mỗi lần container refresh). Lệnh `ssh` **phải có `-i`** trỏ tới key đó.
- Key của máy bạn phải nằm ở `/home/hatch/.ssh/authorized_keys` (vùng bền) và `/root/.ssh/authorized_keys`
  nên là **symlink** trỏ tới nó — nếu không, key mất mỗi lần container refresh.
- `check_prompt_sync.sh` so sánh `MUSE_PROMPT.md` với bản render từ **máy đang chạy** → trên máy
  khác nó sẽ FAIL. Dùng `--strict` (chỉ kiểm tra template, không phụ thuộc máy) cho CI.
- Mỗi Muse host một cổng forward riêng **và một config riêng** (`tunnel-<port>.conf`). Dùng chung một
  `tunnel.conf` là hai port đụng nhau.
- `openssh-server` (`/usr/sbin/sshd`) không nằm trong base image container → bị mất mỗi khi container refresh (vì `/` là overlay tạm). Phải luôn lưu sẵn các gói deb ở `/home/hatch/.muse-bridge/deb/` (vùng bền vững btrfs) để tự cài lại tức thì bằng `dpkg -i` offline (< 1s); tuyệt đối không trông cậy vào `apt-get` qua proxy (rất hay timeout/chặn).
- `/run/sshd` (tmpfs) bị mất mỗi lần reboot và umask trong daemon/hook có thể sinh ra quyền `0770` → `sshd` crash lập tức do Privilege Separation. Luôn `chmod 755 /run/sshd /var/run/sshd`.
- Host keys `/etc/ssh/ssh_host_*_key` bị wipe khi container refresh → phải lưu bền ở `/home/hatch/.muse-bridge/ssh_host/` để khôi phục lại, tránh máy ngoài cảnh báo đổi fingerprint.
