# Accsoon CineEye Air protocol — static analysis notes (draft 2)

Source: the Accsoon app installed on this Mac (`/Applications/Accsoon.app`, an
iOS app wrapper, bundle id `com.yuheng.AccsoonOne`, version 1.6.9), read with
`otool` and `strings`. Nothing here has been observed on the wire yet —
**everything is unconfirmed until a capture with the real device**.

Confidence tags: **[asm]** read from disassembly, **[guess]** inferred.

## 0. Confirmed on the wire (2026-10-10, real CineEye Air)

`tools/client.py` produced a clean picture: 2163 frames in 72 s, none dropped,
decodes without errors as H.264 High 1920x1080 at 30 fps. This overrides the
"unconfirmed" notes below wherever they overlap.

- Transmitter is the gateway, `10.0.0.1`; the Mac got `10.0.0.11`.
- TCP 8001 keep-alive works as described, with channel 0 and a 1 s interval.
  Reply: Cmd 1, SubCmd 11, payload `00 01 01`.
- The reply's middle status byte is "transmitter has a video signal": `00 01 01`
  with a picture, `00 00 01` with the camera off (no datagrams are sent then).
- **No beacons were seen.** The keep-alive alone starts the stream.
- Video arrives on local UDP 8000 from an ephemeral source port (38043), not
  from 8000. Acks sent to port 8000 caused no problems; whether they are
  needed is untested.
- Every datagram was a video data frame: MainCh 1, SubCh 0, Type 1, with
  `ReTxEN` and `AckEN` set, data Type 1 / SubType 0. No End or other control
  frames arrived. Datagrams are at most 4096 bytes.
- VID = 1, PID = 1.
- Video header is correct as documented. `Type` 0 = keyframe (SPS, PPS, SEI,
  IDR in one message), 1 = P-frame. Keyframe every 30 frames. `BitRate` is in
  kbit/s (1024–5760 seen, it adapts). `ID` increments by one per frame.
- Payload is Annex-B with 4-byte start codes. No encryption.

Not yet tested: stream behaviour without acks, the stop command, a second
client, audio (MainCh 2 never appeared — nothing was feeding audio, or it
needs a separate request).

## 0b. Retransmit request, as built by the original app [asm, not seen on the wire]

`prefix (8)` + `Instruct = 1` (u16) + `MsgID` (u16) + `count` (u8) + missing list.
The list holds one **u32** per missing fragment index, and `count` is the list's
length in **bytes** (4 x the number of fragments), not the number of entries.
The original app sends it (twice) when an "end of message" frame arrives for an
incomplete message; the Air never sent end frames in our capture, so
AccsoonMonitor sends it as soon as a newer message starts. Whether the Air
honours it was tested live on 2026-10-11: 11 requests were sent to port 8000
and no fragment was resent, so the app no longer sends them. (Untried: sending
the request to the stream's source port instead of 8000.)

The video header's `TransQuality` float tracks the link: about 75-85 while the
bitrate sits at its 5760 kbit/s maximum, and negative (down to about -170)
when it has fallen to 1024. Higher is better; the exact scale is unknown.

There is no bitrate command on this stack: the only settings commands are
Wi-Fi name / password / channel (set, get, reset) and a self-test. The
transmitter adapts bitrate on its own (1024-5760 kbit/s seen).

## 0c. Wi-Fi settings commands [asm, not yet seen on the wire]

Same TCP framing as the keep-alive (Cmd = 1), one short connection each.
Replies use the request's SubCmd + 1 and carry the settings as text.

| SubCmd | Request | Payload |
|---|---|---|
| 20 | reset access point | none |
| 22 | get access point info | none |
| 24 | set access point | `name=<name>\nkey=<password>\nchannel=<n>` |

Reply payload (21, 23, 25): three lines, `name=`, `key=`, `channel=`.
Name, password and channel always travel together. The original app only
accepts: name 1-12 printable ASCII characters, password 8-12 digits, channel
one of 36, 40, 44, 48, 149, 153, 157, 161, 165 (its table also lists 0,
meaning unknown). After a successful set it tells the user to leave and
reconnect, so the transmitter evidently restarts its Wi-Fi.

The video header's `TransQuality` is what the original app passes to its
`showWifiSignal:` display.

## 1. Which stack the CineEye Air uses [asm]

The app holds three generations of the protocol. The product table gives each
device a type number, and the login screen routes by that number:

| Product | Type | Screen | Stack |
|---|---|---|---|
| CineEye | 1 | `VideoVCFixed` | ObjC `MediaServerClass` → `MediaRtms` + `TcpLinkClass` |
| **CineEye Air** | **2** | **`VideoVCFixed`** | **same as CineEye** |
| CineEye 2/2s, 2/2s Pro | 5, 4 | `CineEye2ProVC` | C++ `RtmsVer00` (ports 28000/28001/281xx) |
| CineView | 7 | `CineEye3VC` (likely) | C++ `accsoon_2022_4_26::rtmsn` |
| A1 gimbals | 3 | stabilizer screen | Bluetooth |

So the Air uses the **oldest, simplest stack**, written in Objective-C, which is
the easiest one to read. The `SysCfg.json` / `sys_cfg.json` / `CtlTcpCfg.json`
files and their 28xxx ports belong to the newer devices and do **not** apply.

## 2. Addresses and ports [asm]

| Item | Value |
|---|---|
| Transmitter IP | the Wi-Fi gateway address (`getGatewayIPAddress`) |
| TCP control port | **8001** |
| UDP port (both ends) | **8000** — client binds local-IP:8000 and replies to sender-IP:8000 |
| TCP frame begin | ASCII `ACCSOON` (7 bytes) |
| PID | 1 |
| VID | not located; copy it from the first beacon |
| UDP rx timeout | 100 ms |
| Max fragments per message | 250 |
| Max fragment payload | 6144 bytes |

All multi-byte fields are **little-endian**, structs are packed.

## 3. TCP control (port 8001) [asm]

A fresh short-lived connection per command (connect timeout 800 ms,
`TCP_NODELAY`). Send one frame, read one reply (up to 128 bytes), close.

### Frame header — 17 bytes

| Offset | Size | Field |
|---|---|---|
| 0 | 7 | `ACCSOON` |
| 7 | 2 | PID (= 1) |
| 9 | 2 | Cmd |
| 11 | 2 | SubCmd |
| 13 | 4 | PayloadLen |
| 17 | … | payload |

### Start / keep-alive / stop stream ("StaOp")

- Request: Cmd = 1, SubCmd = 10, payload 2 bytes: `[op, channel]`.
  `op` = 1 start/keep alive, 0 stop. `channel` is the video channel
  (`VideoCh`, value not traced; try 0).
- `StartMediaStream` starts a thread that sends this with op = 1 repeatedly
  (sleep interval not traced). After 15 consecutive failures the app treats the
  link as closed. `StopMediaStream` sends op = 0 once.
- Reply: Cmd = 1 means control reply. SubCmd = 11 is handled specially
  (probably the StaOp answer; payload likely `StdStatus` u8,
  `VideoStreamIsExist` u8, `AudioStreamIsExist` u8 [guess]). Other SubCmds are
  passed up as text payloads.

Other commands on the same link (numbers not traced, not needed for viewing):
set/get/reset AP name, password and channel; self-test.

**This keep-alive is very likely required for video to flow.**

## 4. UDP stream (port 8000) [asm]

### Basic prefix — 8 bytes (every datagram)

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | VID |
| 4 | 2 | PID |
| 6 | 2 | Ctl bitfield |

Ctl bits: `MainCh` 0–1, `SubCh` 2–3, `Type` 4–7, `ReTxEN` 8, `ReTxFlag` 9,
`AckEN` 10.

- `MainCh`: 0 = common (beacons), 1 = video (`SubCh` = stream index),
  2 = audio.
- `Type`: 0 = control frame, 1 = data frame.
- Datagrams shorter than 8 bytes, or with a different VID/PID, are dropped.

### Control frames — prefix (8) + `Instruct` u16, then:

| Instruct | Frame | Fields after the 10 bytes | Total |
|---|---|---|---|
| 0 | Ack (client → transmitter) | MsgID u16 | 12 |
| 1 | Req retransmit (client → transmitter) | MsgID u16, ReqFrameCnt u8, missing fragment IDs | 13+ |
| 2 | End of message (transmitter → client) | MsgID u16 | 12 |
| 3 | seen in the receiver, handled like "message finished"; meaning unknown | | |
| 10 | Beacon | IsValid u8, Dir u8, ID u16, TimeStamp i64 | 22 |

### Beacon handshake

The transmitter sends beacons on MainCh 0. For each beacon with
`IsValid != 0`, the client sends the same beacon back to sender-IP:8000 with
`IsValid = 0` and `Dir = 1`. (The reply serializer has an oddity around the
`IsValid` byte that I have not fully traced; echoing the received bytes with
those two fields changed is the safest first attempt.)

### Data frames — prefix (8) + 6 bytes

| Offset | Size | Field |
|---|---|---|
| 8 | 2 | MsgID — one per encoded frame |
| 10 | 1 | FrameCnt — fragments in this message |
| 11 | 1 | FrameID — fragment index |
| 12 | 1 | Type |
| 13 | 1 | SubType |
| 14 | … | fragment payload |

Receiver logic:

1. A data frame with a new MsgID starts a new message of FrameCnt fragments.
2. Each fragment is stored by FrameID.
3. When none are missing and `AckEN` is set, the client sends Ack (twice).
4. On an End frame for the current MsgID with fragments missing and `ReTxEN`
   set, the client sends Req with the missing list (twice).
5. A video message is passed on only if it is complete enough; for a first
   viewer we can simply drop incomplete messages and never send Req.

### Video message header — 23 bytes at the start of each reassembled message

| Offset | Size | Field |
|---|---|---|
| 0 | 2 | Width |
| 2 | 2 | Height |
| 4 | 4 | BitRate |
| 8 | 1 | FrameRate |
| 9 | 1 | StaCnt (connected stations) |
| 10 | 4 | TransQuality (float) |
| 14 | 4 | ID (frame counter; duplicates are skipped) |
| 18 | 1 | Type (frame type, values not traced) |
| 19 | 4 | PayLoadLen |
| 23 | … | H.264 data |

The payload goes straight to `MuxerWriteH264Nalu` and the decoder, so it is
**H.264**, very likely Annex-B NAL units [guess on Annex-B]. The Air path does
not use H.265. Payloads under 10 bytes are ignored.

Audio arrives the same way on MainCh 2 with its own header
(`VideoStreamClass_AudioMsgPrivateHeadTypDef`, not traced yet).

## 5. Minimal client recipe (to test in step 4)

1. Join the transmitter's Wi-Fi; gateway IP = transmitter.
2. Bind UDP on local-IP:8000.
3. Every ~1 s: TCP connect to gateway:8001, send
   `ACCSOON` + PID 1 + Cmd 1 + SubCmd 10 + len 2 + `[1, 0]`, read reply, close.
4. Answer each beacon as described.
5. Reassemble data frames on MainCh 1 by MsgID; ack complete messages when
   `AckEN` is set.
6. Strip the 23-byte header, write the rest to stdout → `ffplay -f h264 -`.

## 6. Still open

1. Keep-alive interval and the `VideoCh` value sent in StaOp.
2. Exact StaOp reply payload, and whether beacons start before or after it.
3. Beacon reply oddity around `IsValid`.
4. Data frame `Type`/`SubType` and video header `Type` values (keyframe flag?).
5. Audio message header.
6. VID value (can be copied from the first beacon).
7. No encryption was seen anywhere on this path, but only a capture proves it.
