#!/usr/bin/env python3
"""Fake CineEye Air transmitter, for testing client.py without the device.

It speaks the protocol as docs/protocol.md describes it, so it only proves the
client matches our notes, not that the notes match the real device.

Local test on one machine (different ports, because both ends normally use 8000):

    python3 tools/fake_transmitter.py --udp-port 18000 --tcp-port 18001 \
        --client-port 18002 --frames 200 --expect /tmp/expect.h264
    python3 tools/client.py --host 127.0.0.1 --local-ip 127.0.0.1 \
        --udp-port 18000 --tcp-port 18001 --local-port 18002 > /tmp/got.h264

With --h264 FILE it streams a real Annex-B file (one access unit per message)
instead of synthetic data.
"""
import argparse
import os
import socket
import struct
import sys
import threading
import time

import rtms

VID, PID = 1, 1


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def split_annexb(data):
    """Split an Annex-B stream into chunks, each ending just before a slice-bearing unit's successor."""
    starts = []
    i = data.find(b"\x00\x00\x01")
    while i != -1:
        starts.append(i - 1 if i > 0 and data[i - 1] == 0 else i)
        i = data.find(b"\x00\x00\x01", i + 3)
    units = [data[a:b] for a, b in zip(starts, starts[1:] + [len(data)])]
    frames, cur = [], b""
    for u in units:
        cur += u
        nal_type = u[u.index(b"\x01") + 1] & 0x1F
        if nal_type in (1, 5):
            frames.append(cur)
            cur = b""
    if cur:
        frames.append(cur)
    return frames


def synthetic_frames(n):
    for i in range(n):
        size = 30000 if i % 30 == 0 else 3000 + (i * 37) % 2000
        yield b"\x00\x00\x00\x01" + bytes([0x65 if i % 30 == 0 else 0x41]) + os.urandom(size)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("--udp-port", type=int, default=rtms.UDP_PORT)
    ap.add_argument("--tcp-port", type=int, default=rtms.TCP_PORT)
    ap.add_argument("--client-port", type=int, default=rtms.UDP_PORT)
    ap.add_argument("--frames", type=int, default=200)
    ap.add_argument("--fps", type=int, default=30)
    ap.add_argument("--fragment", type=int, default=1400)
    ap.add_argument("--h264", help="Annex-B file to stream instead of synthetic data")
    ap.add_argument("--expect", help="write the exact bytes the client should output")
    ap.add_argument("--timeout", type=float, default=20, help="give up if no client shows up")
    args = ap.parse_args()

    state = dict(client=None, sta_ops=0, beacon_replies=0, acks=0)

    tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    tcp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    tcp.bind((args.bind, args.tcp_port))
    tcp.listen(8)

    def tcp_loop():
        while True:
            conn, addr = tcp.accept()
            with conn:
                conn.settimeout(1)
                try:
                    req = rtms.parse_tcp_frame(conn.recv(256))
                except OSError:
                    continue
                if not req:
                    log("tcp: bad frame from %s" % addr[0])
                    continue
                pid, cmd, subcmd, payload = req
                if cmd == rtms.CMD_CTL and subcmd == rtms.SUBCMD_STA_OP and len(payload) == 2:
                    state["sta_ops"] += 1
                    if payload[0] == 1:
                        if state["client"] is None:
                            log("tcp: start from %s, channel %d" % (addr[0], payload[1]))
                        state["client"] = addr[0]
                    else:
                        log("tcp: stop from %s" % addr[0])
                    conn.sendall(rtms.tcp_frame(rtms.CMD_CTL, rtms.SUBCMD_STA_OP_REPLY, bytes([0, 1, 0]), pid))
                else:
                    log("tcp: unexpected cmd=%d subcmd=%d payload=%s" % (cmd, subcmd, payload.hex()))

    threading.Thread(target=tcp_loop, daemon=True).start()

    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.bind((args.bind, args.udp_port))
    udp.settimeout(0.01)

    def udp_loop():
        while True:
            try:
                data, _ = udp.recvfrom(2048)
            except socket.timeout:
                continue
            except OSError:
                return
            if len(data) < rtms.CTL_HEAD.size:
                continue
            instruct = rtms.CTL_HEAD.unpack_from(data)[3]
            if instruct == rtms.INSTRUCT_BEACON and len(data) == rtms.BEACON.size:
                if data[rtms.BEACON_ISVALID_OFFSET] == 0 and data[rtms.BEACON_DIR_OFFSET] == 1:
                    state["beacon_replies"] += 1
            elif instruct == rtms.INSTRUCT_ACK:
                state["acks"] += 1

    threading.Thread(target=udp_loop, daemon=True).start()

    log("waiting for a client on tcp %d ..." % args.tcp_port)
    deadline = time.time() + args.timeout
    while state["client"] is None:
        if time.time() > deadline:
            sys.exit("no client connected")
        time.sleep(0.05)
    dest = (state["client"], args.client_port)

    beacon_id = 0
    while state["beacon_replies"] == 0:
        if time.time() > deadline:
            sys.exit("client never answered a beacon")
        udp.sendto(rtms.beacon_frame(VID, PID, 1, 0, beacon_id, int(time.time() * 1000)), dest)
        beacon_id += 1
        time.sleep(0.2)
    log("beacon answered, streaming")

    if args.h264:
        with open(args.h264, "rb") as f:
            frames = split_annexb(f.read())
    else:
        frames = list(synthetic_frames(args.frames))
    expect = open(args.expect, "wb") if args.expect else None

    for n, payload in enumerate(frames):
        head = rtms.VIDEO_HEAD.pack(1920, 1080, 8000000, args.fps, 1, 1.0, n + 1, 0, len(payload))
        msg = head + payload
        parts = [msg[i:i + args.fragment] for i in range(0, len(msg), args.fragment)]
        if len(parts) > 250:
            sys.exit("frame %d needs %d fragments (max 250); raise --fragment" % (n, len(parts)))
        msg_id = n & 0xFFFF
        ctl = rtms.make_ctl(rtms.MAINCH_VIDEO, 0, rtms.TYPE_DATA, ack_en=1)
        for i, part in enumerate(parts):
            udp.sendto(rtms.DATA_HEAD.pack(VID, PID, ctl, msg_id, len(parts), i, 0, 0) + part, dest)
        udp.sendto(rtms.end_frame(VID, PID, rtms.MAINCH_VIDEO, 0, msg_id, ack_en=1), dest)
        if expect:
            expect.write(payload)
        if n % args.fps == 0:
            udp.sendto(rtms.beacon_frame(VID, PID, 1, 0, beacon_id, int(time.time() * 1000)), dest)
            beacon_id += 1
        time.sleep(1.0 / args.fps)

    time.sleep(0.3)
    log("sent %d frames | sta_ops=%d beacon_replies=%d acks=%d" % (
        len(frames), state["sta_ops"], state["beacon_replies"], state["acks"]))


if __name__ == "__main__":
    main()
