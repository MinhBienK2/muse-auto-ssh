#!/usr/bin/env python3
"""ts-connect-proxy.py - ProxyCommand cho ssh: noi thang, khong duoc thi HTTP CONNECT.

    ts-connect-proxy.py <host> <port> | --banner <host> <port>

Ban goc duy nhat: prompt inject nguyen file nay (render_prompt.py); container dung
python3 co san khi thieu socat. ts-socat-proxy.sh goi file nay lam fallback.
"""
import os
import select
import socket
import sys

PROXY_HOST = os.environ.get("PROXY_HOST", "hatch-egress-proxy")
PROXY_PORT = int(os.environ.get("PROXY_PORT", "3130"))


def open_conn(host, port):
    """Thu noi thang truoc (container co tailscale rieng); that bai thi qua proxy."""
    try:
        return socket.create_connection((host, port), 8)
    except OSError:
        pass
    try:
        sock = socket.create_connection((PROXY_HOST, PROXY_PORT), 10)
    except OSError as err:
        sys.stderr.write("khong noi duoc proxy %s:%d: %s\n" % (PROXY_HOST, PROXY_PORT, err))
        sys.exit(1)
    req = "CONNECT %s:%d HTTP/1.1\r\nHost: %s:%d\r\n\r\n" % (host, port, host, port)
    sock.sendall(req.encode())
    head = sock.recv(256).split(b"\r\n")[0]
    if b"200" not in head:
        sys.stderr.write("CONNECT that bai: %s\n" % head.decode("utf-8", "replace"))
        sys.exit(1)
    return sock


def banner_probe(host, port, timeout):
    """In 4 byte dau (banner SSH) cua host:port. Thay bash /dev/tcp (co the bi TAT)."""
    try:
        with socket.create_connection((host, port), timeout) as sock:
            sock.settimeout(timeout)
            os.write(1, sock.recv(4))
    except OSError:
        return 1
    return 0


def main():
    if len(sys.argv) >= 4 and sys.argv[1] == "--banner":
        return banner_probe(sys.argv[2], int(sys.argv[3]), 5)
    if len(sys.argv) < 3:
        sys.stderr.write("usage: ts-connect-proxy.py <host> <port> | --banner <host> <port>\n")
        return 2
    sock = open_conn(sys.argv[1], int(sys.argv[2]))
    stdin_open = True
    while True:
        watch = [sock, 0] if stdin_open else [sock]
        ready, _, _ = select.select(watch, [], [], 60)
        if not ready:
            break
        for src in ready:
            if src is sock:
                data = sock.recv(65536)
                if not data:
                    return 0
                os.write(1, data)
            else:
                data = os.read(0, 65536)
                if not data:
                    # stdin EOF -> dong nua ghi, van doc phia server cho den khi no dong
                    stdin_open = False
                    try:
                        sock.shutdown(socket.SHUT_WR)
                    except OSError:
                        pass
                    continue
                sock.sendall(data)
    return 0


if __name__ == "__main__":
    sys.exit(main())
