# INSTRUCTIONS FOR LOCAL AGENT (LOCAL_AGENT.md)

> **Dành cho Agent Ngoài:** Đọc tài liệu này khi repo được clone về máy tính cá nhân của người dùng (Linux, macOS hoặc WSL).

Bạn là **Agent Ngoài** (ví dụ: Antigravity, Claude Code, Cursor, CLI Assistant). Nhiệm vụ của bạn là chuẩn bị môi trường phía máy cá nhân, tiếp nhận Public Key từ **Agent Muse**, và sau khi kết nối thành công sẽ tự động triển khai cơ chế **Self-Healing vĩnh viễn** vào máy ảo Muse.

---

## 1. Bản chất kiến trúc
- Máy cá nhân của bạn sẽ đóng vai trò là **SSH Endpoint** đón kết nối từ Muse qua mạng Tailscale (cổng 22).
- Khi Muse kết nối tới cổng 22 của bạn, nó sẽ mở một cổng ngược (`127.0.0.1:2222`) trên máy bạn trỏ về máy ảo Muse.
- Bạn sẽ đăng nhập vào máy ảo Muse bằng lệnh `ssh muse` (tương đương `ssh -p 2222 root@127.0.0.1`).

---

## 2. Quy trình thực hiện của bạn (Chỉ 2 bước)

### Bước 1: Cấu hình máy ngoài khi có Public Key của Muse
Khi người dùng hoặc Agent Muse cung cấp chuỗi `<MUSE_PUBLIC_KEY>`, bạn chạy lệnh:
```bash
bash scripts/local_setup.sh "<MUSE_PUBLIC_KEY>"
```

Lệnh này sẽ:
1. Kiểm tra và đảm bảo OpenSSH Server đang lắng nghe trên cổng 22.
2. Tự động phát hiện IP Tailscale của máy bạn (`tailscale ip -4`).
3. Tạo SSH Keypair `~/.ssh/id_ed25519` (nếu chưa có).
4. Thêm `<MUSE_PUBLIC_KEY>` vào file `~/.ssh/authorized_keys`.
5. Tạo alias `Host muse` trong `~/.ssh/config`.
6. In ra thông số cần thiết để gửi cho Agent Muse.

👉 **Việc của bạn:** Copy thông tin xuất ra và gửi cho Agent Muse (hoặc bảo người dùng chuyển qua chat):
```text
bash scripts/muse_start_tunnel.sh <LOCAL_TAILSCALE_IP> <LOCAL_USER> "<LOCAL_PUBLIC_KEY>"
```

---

### Bước 2: Kiểm tra kết nối và Tự động Bền vững hóa (Self-Healing)
Sau khi Agent Muse thông báo đã chạy xong lệnh trên:
Bạn chỉ cần chạy lệnh sau trên máy cá nhân:
```bash
bash scripts/local_finalize_persistence.sh
```

Lệnh này sẽ tự động:
1. Chờ cổng `2222` trên máy cá nhân chuyển sang trạng thái `LISTEN`.
2. Kiểm tra bắt tay SSH với máy ảo Muse (`ssh muse hostname`).
3. Truyền và thực thi trực tiếp script `scripts/muse_harden_persistence.sh` vào bên trong máy ảo Muse qua SSH:
   - Cài đặt dịch vụ systemd `muse-reverse-tunnel.service`.
   - Nhúng cơ chế tự phục hồi vào Hatch Boot Hook (`muse-platform-boot.sh`) chạy mỗi 15s.
   - Cập nhật `MEMORY.md` và `HEARTBEAT.md` của Muse.
4. Xác nhận kết nối hoàn tất.

---

## 3. Kết quả
Kể từ thời điểm này, mỗi khi máy cá nhân bật OpenSSH Server, máy ảo Muse sẽ tự động kết nối lại trong vòng 10 giây. Bạn chỉ cần gõ:
```bash
ssh muse
```
để vào thẳng máy ảo Muse bất cứ lúc nào!
