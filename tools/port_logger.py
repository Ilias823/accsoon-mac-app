#!/usr/bin/env python3
"""Pretend to be the CineEye Air and log whatever the Accsoon Go app sends.

Run it on the Mac, then start Accsoon Go. Every TCP connection and UDP datagram
that arrives on the watched ports is printed as a hex dump and appended to a
log file, so we can see the app's opening messages without the real device.

The app talks to the transmitter's IP address, not to your Mac. To catch that
traffic, first find the address it tries (Wireshark on en0, or `nettop`), then
give your Mac that address as an alias, e.g.:

    sudo ifconfig lo0 alias 192.168.1.1     # replace with the transmitter IP
    python3 tools/port_logger.py --host 192.168.1.1 --tcp 554 8080 --udp 5000
    sudo ifconfig lo0 -alias 192.168.1.1    # undo when finished

With no ports given it listens on a set of common ones.
"""

import argparse
import datetime
import socket
import threading

DEFAULT_TCP = [80, 554, 1935, 5000, 6000, 8000, 8080, 8554, 9000, 10000]
DEFAULT_UDP = [5000, 5004, 6000, 8000, 9000, 10000, 32100, 32108]

_print_lock = threading.Lock()


def hexdump(data: bytes, width: int = 16) -> str:
    lines = []
    for offset in range(0, len(data), width):
        chunk = data[offset:offset + width]
        hex_part = " ".join(f"{b:02x}" for b in chunk)
        text_part = "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)
        lines.append(f"  {offset:08x}  {hex_part:<{width * 3}} {text_part}")
    return "\n".join(lines)


def log(log_path: str, header: str, data: bytes = b"") -> None:
    stamp = datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3]
    entry = f"[{stamp}] {header}"
    if data:
        entry += f" ({len(data)} bytes)\n{hexdump(data)}"
    with _print_lock:
        print(entry, flush=True)
        with open(log_path, "a") as f:
            f.write(entry + "\n")


def handle_tcp_client(conn: socket.socket, addr, port: int, log_path: str) -> None:
    log(log_path, f"TCP {port}: connection from {addr[0]}:{addr[1]}")
    with conn:
        while True:
            try:
                data = conn.recv(65536)
            except OSError as e:
                log(log_path, f"TCP {port}: error {e}")
                return
            if not data:
                log(log_path, f"TCP {port}: {addr[0]}:{addr[1]} closed")
                return
            log(log_path, f"TCP {port}: from {addr[0]}:{addr[1]}", data)


def serve_tcp(host: str, port: int, log_path: str) -> None:
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        srv.bind((host, port))
    except OSError as e:
        log(log_path, f"TCP {port}: cannot listen ({e})")
        return
    srv.listen()
    while True:
        conn, addr = srv.accept()
        threading.Thread(target=handle_tcp_client, args=(conn, addr, port, log_path),
                         daemon=True).start()


def serve_udp(host: str, port: int, log_path: str) -> None:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    try:
        sock.bind((host, port))
    except OSError as e:
        log(log_path, f"UDP {port}: cannot listen ({e})")
        return
    while True:
        data, addr = sock.recvfrom(65536)
        log(log_path, f"UDP {port}: from {addr[0]}:{addr[1]}", data)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="0.0.0.0", help="address to listen on")
    parser.add_argument("--tcp", type=int, nargs="*", help="TCP ports to listen on")
    parser.add_argument("--udp", type=int, nargs="*", help="UDP ports to listen on")
    parser.add_argument("--log", default="fake_transmitter.log", help="log file path")
    args = parser.parse_args()

    tcp_ports = args.tcp if args.tcp is not None else DEFAULT_TCP
    udp_ports = args.udp if args.udp is not None else DEFAULT_UDP

    for port in tcp_ports:
        threading.Thread(target=serve_tcp, args=(args.host, port, args.log), daemon=True).start()
    for port in udp_ports:
        threading.Thread(target=serve_udp, args=(args.host, port, args.log), daemon=True).start()

    print(f"Listening on {args.host}  TCP {tcp_ports}  UDP {udp_ports}  (Ctrl+C to stop)")
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
