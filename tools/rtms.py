"""Wire formats for the CineEye / CineEye Air link, as described in docs/protocol.md.

Everything is little-endian and packed. The TCP keep-alive, data frames and
video header are confirmed against a real CineEye Air; beacons, Req and End
frames were not seen on the wire.
"""
import struct

TCP_PORT = 8001
UDP_PORT = 8000

# --- TCP control -----------------------------------------------------------

TCP_BEGIN = b"ACCSOON"
TCP_HEAD = struct.Struct("<7sHHHI")  # begin, PID, Cmd, SubCmd, PayloadLen

CMD_CTL = 1
SUBCMD_STA_OP = 10
SUBCMD_STA_OP_REPLY = 11


def tcp_frame(cmd, subcmd, payload=b"", pid=1):
    return TCP_HEAD.pack(TCP_BEGIN, pid, cmd, subcmd, len(payload)) + payload


def parse_tcp_frame(data):
    """Returns (pid, cmd, subcmd, payload) or None."""
    if len(data) < TCP_HEAD.size:
        return None
    begin, pid, cmd, subcmd, length = TCP_HEAD.unpack_from(data)
    if begin != TCP_BEGIN:
        return None
    return pid, cmd, subcmd, data[TCP_HEAD.size:TCP_HEAD.size + length]


# --- UDP -------------------------------------------------------------------

PREFIX = struct.Struct("<IHH")  # VID, PID, Ctl
CTL_HEAD = struct.Struct("<IHHH")  # + Instruct
DATA_HEAD = struct.Struct("<IHHHBBBB")  # + MsgID, FrameCnt, FrameID, Type, SubType
BEACON = struct.Struct("<IHHHBBHq")  # + IsValid, Dir, ID, TimeStamp
VIDEO_HEAD = struct.Struct("<HHIBBfIBI")  # W, H, BitRate, FPS, StaCnt, TransQ, ID, Type, PayLoadLen

VIDEO_TYPE_KEY = 0  # SPS + PPS + SEI + IDR
VIDEO_TYPE_DELTA = 1

MAINCH_COMMON = 0
MAINCH_VIDEO = 1
MAINCH_AUDIO = 2

TYPE_CTL = 0
TYPE_DATA = 1

INSTRUCT_ACK = 0
INSTRUCT_REQ = 1
INSTRUCT_END = 2
INSTRUCT_BEACON = 10

BEACON_ISVALID_OFFSET = 10
BEACON_DIR_OFFSET = 11


def make_ctl(main_ch=0, sub_ch=0, type_=0, retx_en=0, retx_flag=0, ack_en=0):
    return (main_ch & 3) | (sub_ch & 3) << 2 | (type_ & 15) << 4 | retx_en << 8 | retx_flag << 9 | ack_en << 10


class Ctl:
    def __init__(self, raw):
        self.main_ch = raw & 3
        self.sub_ch = (raw >> 2) & 3
        self.type = (raw >> 4) & 15
        self.retx_en = (raw >> 8) & 1
        self.retx_flag = (raw >> 9) & 1
        self.ack_en = (raw >> 10) & 1


def ack_frame(vid, pid, main_ch, sub_ch, msg_id):
    return CTL_HEAD.pack(vid, pid, make_ctl(main_ch, sub_ch), INSTRUCT_ACK) + struct.pack("<H", msg_id)


def end_frame(vid, pid, main_ch, sub_ch, msg_id, retx_en=0, ack_en=0):
    ctl = make_ctl(main_ch, sub_ch, retx_en=retx_en, ack_en=ack_en)
    return CTL_HEAD.pack(vid, pid, ctl, INSTRUCT_END) + struct.pack("<H", msg_id)


def beacon_frame(vid, pid, is_valid, direction, beacon_id, timestamp):
    return BEACON.pack(vid, pid, make_ctl(), INSTRUCT_BEACON, is_valid, direction, beacon_id, timestamp)


def beacon_reply(received):
    """Echo a received beacon with IsValid = 0 and Dir = 1."""
    out = bytearray(received)
    out[BEACON_ISVALID_OFFSET] = 0
    out[BEACON_DIR_OFFSET] = 1
    return bytes(out)
