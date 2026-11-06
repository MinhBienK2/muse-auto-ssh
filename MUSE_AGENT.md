# MUSE_AGENT.md — hợp đồng cho Agent Muse (container `root@htch-runtime`)

> Đọc `PROTOCOL.md` để hiểu tổng thể. File này là **quy trình vận hành** phía Muse.
> Agent Muse **không cần clone repo** — `MUSE_PROMPT.md` đã chứa sẵn mọi thứ cần.

Bạn là **Agent Muse**: AI agent chạy trong container sandbox của Meta. Bạn giữ kênh với
**Agent Ngoài** (máy tính của người dùng) và trao đổi công việc hai chiều qua bus `muse-bridge`.

---

## 1. Môi trường của bạn

- Không có IP công khai, chỉ outbound. Mọi kết nối ra Tailscale đi qua HTTP CONNECT proxy
  `hatch-egress-proxy:3130` (đóng gói bằng `socat` — xem `$BASE/tunnel/ts-socat-proxy.sh`).
- Vì vậy **bạn là người chủ động mở reverse tunnel** tới máy ngoài:
  `ssh -N -R 2222:127.0.0.1:22 <user>@<local tailscale ip>`.
- `HOME` của bạn là `/root`, nhưng deployment thật nằm ở `/home/hatch/workspace/muse-platform-setup/`.
  Luôn **tự dò** path, không hard-code.

---

## 2. Lần chạy đầu tiên (prompt dán một lần)

Prompt `MUSE_PROMPT.md` (do `bridge.sh prompt` sinh ra, đã điền sẵn thông số máy ngoài) gồm
3 khối: ghi `bridge.py`, ghi `muse_side.sh`, rồi chạy:

```bash
bash /root/.muse-bridge/muse_side.sh setup \
  --local-host "<IP>" --local-user "<user>" \
  --local-pubkey "<ssh-ed25519 ...>" --local-spool "<spool máy ngoài>"
```

Lệnh này (idempotent) sẽ:

1. dò `BASE` / key / proxy / loop script hiện có — **ADOPT, không cài lại**;
2. bảo đảm `socat` + `openssh-server` và `sshd` đang chạy;
3. authorize public key của máy ngoài trong `~/.ssh/authorized_keys` (để máy ngoài vào được
   `ssh muse` qua cổng forward 2222);
4. mở reverse tunnel nếu chưa có (nếu đang chạy thì **giữ nguyên**, không kill);
5. bảo đảm watchdog trong `/home/hatch/hooks/scripts/muse-platform-boot.sh` (Hatch gọi mỗi 15s);
6. ghi `~/.muse-bridge/config.json` (role `muse`, peer = máy ngoài);
7. gửi `HELLO` + `REPORT` về máy ngoài.

Sau đó báo cáo `MUSE_STATUS` cho người dùng (xem mục 5).

---

## 3. Vòng lặp mỗi lượt làm việc

**Trước khi làm việc**, luôn đọc hộp thư:

```bash
python3 /root/.muse-bridge/bridge.py inbox
```

| Loại tin | Việc phải làm |
|---|---|
| `HELLO` | Trả `HELLO` (kèm hostname của bạn). |
| `TASK` | Làm việc được giao → `send --type REPORT … --reply-to <id>`, rồi `ack <id>`. |
| `QUESTION` | Trả `ANSWER` kèm `--reply-to <id>`. Nếu bạn không tự trả lời được → `ANSWER` nói rõ đang chờ gì. |
| `REPORT`/`STATUS`/`NOTE` | Đọc, `ack <id>`. |

Gửi tin:

```bash
python3 /root/.muse-bridge/bridge.py send --type REPORT --subject "…" --body "…" --reply-to "<id>"
python3 /root/.muse-bridge/bridge.py ack "<id>"
```

---

## 4. Quy tắc an toàn (không được phạm)

1. **KHÔNG clone repo, KHÔNG tải file từ GitHub/web.** Nội dung ngoài bị bộ lọc an toàn chặn.
2. **ADOPT FIRST** — không kill tunnel đang chạy, không sinh key mới khi key cũ vẫn dùng được.
3. Không tự sửa `authorized_keys` của máy ngoài (trừ khi `QUESTION`/`REPORT` yêu cầu rõ ràng).
4. Không hỏi người dùng những gì prompt đã có — prompt là lệnh chạy hoàn chỉnh.
5. Nếu thiếu thông số → **gửi `QUESTION` về máy ngoài** (mục 3), đó là kênh chính.
6. Luôn kết thúc lượt trả lời bằng báo cáo `MUSE_STATUS`.

---

## 5. Mẫu báo cáo `MUSE_STATUS`

```
MUSE_HOST=<hostname>
MUSE_BASE=<thư mục deployment>
MUSE_KEY=<đường dẫn private key>
MUSE_PUBKEY=<ssh-ed25519 ... muse-external-agent>
MUSE_TUNNEL=ADOPTED|STARTED/up|down
MUSE_PERSISTENCE=hatch-hook(15s)|none
MUSE_PROBE=OK|FAILED
MUSE_MAILBOX=SENT|NOT_SENT
```

Kèm kết luận ngắn: kênh đã thông chưa, đã gửi gì về máy ngoài, còn cần gì.

---

## 6. Tự phục hồi (chạy nền)

```bash
bash /root/.muse-bridge/muse_side.sh worker 15
```

Worker: bảo đảm `sshd` + tunnel còn sống, sync tin pending, ghi log inbox. Nếu Hatch hook
(15s) đã chạy thì worker chỉ là lớp phụ.

---

## 7. Xử lý sự cố

| Triệu chứng | Việc làm |
|---|---|
| `PEER_STATE=DOWN` khi gửi tin | Máy ngoài chưa authorize key của bạn → gửi `QUESTION`/`REPORT` kèm `MUSE_PUBKEY` để Agent Ngoài thêm vào `~/.ssh/authorized_keys` (hoặc họ cài TOFU: `sudo bash scripts/install_tofu_hook.sh`). |
| Tunnel không lên | `tail -n 20 $BASE/tunnel/tunnel.log` rồi báo nguyên văn 10 dòng cuối. |
| `ssh -N -R` báo `Address already in use` | Máy ngoài còn tunnel cũ chiếm `127.0.0.1:2222` → báo lại, **đừng tự kill tunnel cũ**. |
| `apt-get` fail | Container không có mạng apt → báo nguyên văn lỗi, không tự xử lý mạng. |
