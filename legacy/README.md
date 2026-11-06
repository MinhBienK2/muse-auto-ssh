# legacy/ — script của thiết kế cũ (muse-auto-ssh v1)

Các script ở đây **đã bị thay thế** bởi `muse-bridge` (xem `../PROTOCOL.md`). Giữ lại để tham
khảo và để đối chiếu với deployment đang chạy trên máy Muse.

| Script cũ | Được thay bằng |
|---|---|
| `muse_bootstrap.sh` | `bridge/muse_side.sh setup` (tự dò `BASE`, tự cài socat/sshd, tự sinh key) |
| `muse_start_tunnel.sh` | `bridge/muse_side.sh setup` (adopt-first, không kill tunnel cũ) |
| `muse_remote_sync.sh` | `bridge/muse_side.sh setup` + `bridge/muse_side.sh worker` |
| `muse_harden_persistence.sh` | watchdog Hatch trong `bridge/muse_side.sh` (`ensure_persistence`) |
| `local_setup.sh` | `bash scripts/bridge.sh arm` |
| `local_finalize_persistence.sh` | `bash scripts/bridge.sh arm` (đã push bundle + cài TOFU) |
| `outer_bridge.sh` | `bash scripts/bridge.sh status` / `inbox` |
| `reverse-tunnel-g3.sh` | script loop do `muse_side.sh` sinh ra (`$BASE/tunnel/reverse-tunnel.sh`) |
| `templates/` | proxy + loop + systemd đã được nhúng thẳng vào `bridge/muse_side.sh` |

`templates/ts-socat-proxy.sh` là **symlink** tới `bridge/ts-socat-proxy.sh` (một nguồn duy nhất — sửa
bản trong `bridge/`, đừng tạo bản thứ hai).

Mailbox kiểu cũ (`~/muse-bridge/MUSE_STATUS.md`, `OUTER_TASKS.md`) **không còn dùng** — trao đổi
giữa hai agent giờ đi qua bus tin nhắn JSON (`muse-bridge`), xem `../PROTOCOL.md` mục 5–7.
