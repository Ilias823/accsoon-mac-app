#!/usr/bin/env python3
"""Prototype CineEye Air viewer: writes the H.264 elementary stream to stdout.

    python3 tools/client.py | ffplay -f h264 -fflags nobuffer -flags low_delay \\
        -probesize 32 -analyzeduration 0 -framedrop -vf setpts=0 -

Join the transmitter's Wi-Fi first. Logs go to stderr. Based on
docs/protocol.md. Use -v and --dump FILE to record what the transmitter sends.
"""
import argparse
import re
import socket
import struct
import subprocess
import sys
import threading
import time

import rtms


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def default_gateway():
    try:
        out = subprocess.run(["route", "-n", "get", "default"], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    m = re.search(r"gateway:\s*(\S+)", out)
    return m.group(1) if m else None


def local_ip_towards(host):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect((host, 9))
        return s.getsockname()[0]
    finally:
        s.close()


class KeepAlive(threading.Thread):
    """Sends the StaOp start/keep-alive over a fresh TCP connection each time."""

    def __init__(self, host, port, channel, interval, verbose):
        super().__init__(daemon=True)
        self.addr = (host, port)
        self.channel = channel
        self.interval = interval
        self.verbose = verbose
        self.stop_event = threading.Event()
        self.failures = 0
        self.last_reply = None

    def sta_op(self, op):
        frame = rtms.tcp_frame(rtms.CMD_CTL, rtms.SUBCMD_STA_OP, bytes([op, self.channel]))
        with socket.create_connection(self.addr, timeout=0.8) as s:
            s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            s.sendall(frame)
            s.settimeout(1.0)
            try:
                return s.recv(128)
            except socket.timeout:
                return b""

    def run(self):
        while not self.stop_event.is_set():
            try:
                reply = self.sta_op(1)
                self.failures = 0
                if reply != self.last_reply or self.verbose > 1:
                    self.last_reply = reply
                    log("tcp: keep-alive reply %s parsed=%s" % (reply.hex(), rtms.parse_tcp_frame(reply)))
            except OSError as e:
                self.failures += 1
                if self.failures in (1, 15) or self.verbose:
                    log("tcp: keep-alive failed (%d in a row): %s" % (self.failures, e))
            self.stop_event.wait(self.interval)

    def stop(self):
        self.stop_event.set()
        try:
            self.sta_op(0)
        except OSError:
            pass


class Message:
    def __init__(self, msg_id, count):
        self.msg_id = msg_id
        self.count = count
        self.parts = {}

    def complete(self):
        return len(self.parts) == self.count

    def data(self):
        return b"".join(self.parts[i] for i in range(self.count))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", help="transmitter IP (default: the default gateway)")
    ap.add_argument("--local-ip", help="local IP to bind (default: the one that routes to the transmitter)")
    ap.add_argument("--tcp-port", type=int, default=rtms.TCP_PORT)
    ap.add_argument("--udp-port", type=int, default=rtms.UDP_PORT, help="transmitter UDP port")
    ap.add_argument("--local-port", type=int, default=rtms.UDP_PORT, help="local UDP port")
    ap.add_argument("--channel", type=int, default=0, help="video channel sent in the keep-alive")
    ap.add_argument("--keepalive", type=float, default=1.0, help="keep-alive interval in seconds")
    ap.add_argument("--no-tcp", action="store_true", help="do not send the TCP keep-alive")
    ap.add_argument("--no-ack", action="store_true", help="never ack video messages")
    ap.add_argument("--no-beacon-reply", action="store_true")
    ap.add_argument("--no-wait-key", action="store_true", help="output from the first frame, not the first keyframe")
    ap.add_argument("--dump", metavar="FILE", help="append every received datagram to FILE (u16 length + bytes)")
    ap.add_argument("-v", "--verbose", action="count", default=0)
    args = ap.parse_args()

    host = args.host or default_gateway()
    if not host:
        sys.exit("could not find the default gateway; pass --host")
    local_ip = args.local_ip or local_ip_towards(host)
    log("transmitter %s  tcp %d  udp %d  |  local %s:%d" % (host, args.tcp_port, args.udp_port, local_ip, args.local_port))

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 20)
    sock.bind((local_ip, args.local_port))
    sock.settimeout(0.1)

    keepalive = None
    if not args.no_tcp:
        keepalive = KeepAlive(host, args.tcp_port, args.channel, args.keepalive, args.verbose)
        keepalive.start()

    dump = open(args.dump, "ab") if args.dump else None
    out = sys.stdout.buffer
    ident = None  # (VID, PID), learned from the first datagram
    current = None
    last_video_id = None
    started = False  # output begins at the first keyframe
    stats = dict(datagrams=0, beacons=0, frames=0, dropped=0, bytes=0, other=0)
    info = ""
    last_report = time.time()

    try:
        while True:
            now = time.time()
            if now - last_report >= 2:
                last_report = now
                log("udp: %s %s" % (" ".join("%s=%d" % kv for kv in stats.items()), info))
            try:
                data, addr = sock.recvfrom(65536)
            except socket.timeout:
                continue
            stats["datagrams"] += 1
            if dump:
                dump.write(struct.pack("<H", len(data)) + data)
            if len(data) < rtms.PREFIX.size:
                continue
            vid, pid, raw_ctl = rtms.PREFIX.unpack_from(data)
            if ident is None:
                ident = (vid, pid)
                log("udp: first datagram from %s:%d, VID=%d PID=%d" % (addr[0], addr[1], vid, pid))
            if (vid, pid) != ident:
                continue
            ctl = rtms.Ctl(raw_ctl)
            reply_to = (addr[0], args.udp_port)
            instruct = None
            if ctl.type == rtms.TYPE_CTL and len(data) >= rtms.CTL_HEAD.size:
                instruct = rtms.CTL_HEAD.unpack_from(data)[3]

            if ctl.main_ch == rtms.MAINCH_COMMON:
                if instruct == rtms.INSTRUCT_BEACON and len(data) >= rtms.BEACON.size:
                    stats["beacons"] += 1
                    if args.verbose and stats["beacons"] <= 3:
                        log("udp: beacon %s" % data.hex())
                    if data[rtms.BEACON_ISVALID_OFFSET] and not args.no_beacon_reply:
                        sock.sendto(rtms.beacon_reply(data), reply_to)
                else:
                    stats["other"] += 1
                    if args.verbose:
                        log("udp: unknown common frame %s" % data[:32].hex())
                continue

            if ctl.main_ch != rtms.MAINCH_VIDEO:
                stats["other"] += 1
                continue

            if ctl.type == rtms.TYPE_DATA and len(data) >= rtms.DATA_HEAD.size:
                _, _, _, msg_id, count, frag_id, ftype, subtype = rtms.DATA_HEAD.unpack_from(data)
                if current is None or current.msg_id != msg_id:
                    if current is not None and not current.complete():
                        stats["dropped"] += 1
                    current = Message(msg_id, count)
                    if args.verbose > 1:
                        log("udp: msg %d: %d fragments, type=%d subtype=%d" % (msg_id, count, ftype, subtype))
                if frag_id >= current.count or current.complete():
                    continue
                current.parts[frag_id] = data[rtms.DATA_HEAD.size:]
                if not current.complete():
                    continue
                if ctl.ack_en and not args.no_ack:
                    ack = rtms.ack_frame(vid, pid, ctl.main_ch, ctl.sub_ch, msg_id)
                    sock.sendto(ack, reply_to)
                    sock.sendto(ack, reply_to)
                msg = current.data()
                if len(msg) < rtms.VIDEO_HEAD.size:
                    continue
                w, h, bitrate, fps, sta, quality, video_id, vtype, plen = rtms.VIDEO_HEAD.unpack_from(msg)
                payload = msg[rtms.VIDEO_HEAD.size:rtms.VIDEO_HEAD.size + plen]
                if video_id == last_video_id or len(payload) < 10:
                    continue
                last_video_id = video_id
                if not started:
                    if vtype != rtms.VIDEO_TYPE_KEY and not args.no_wait_key:
                        continue
                    started = True
                if stats["frames"] == 0:
                    log("video: first frame %dx%d %dfps, starts with %s" % (w, h, fps, payload[:8].hex()))
                stats["frames"] += 1
                stats["bytes"] += len(payload)
                info = "| %dx%d %dfps %dkbps sta=%d q=%.2f type=%d" % (w, h, fps, bitrate, sta, quality, vtype)
                out.write(payload)
                out.flush()
            elif instruct is not None and args.verbose > 1:
                log("udp: video ctl instruct=%d %s" % (instruct, data[:16].hex()))
    except (KeyboardInterrupt, BrokenPipeError):
        pass
    finally:
        if keepalive:
            keepalive.stop()
        log("done: %s" % " ".join("%s=%d" % kv for kv in stats.items()))


if __name__ == "__main__":
    main()
