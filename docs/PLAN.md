# Plan: Mac monitor app for Accsoon CineEye Air

## Context
The official Accsoon Go app for Mac is buggy; the iPad version works. Goal: our own
Mac app (repo `Ilias823/accsoon-mac-app`, currently empty) that connects to the
CineEye Air over its Wi-Fi and shows a clean, low-latency live monitor. Recording,
LUTs and monitoring tools come later. The protocol is undocumented, so we must
reverse-engineer it. User has an Apple Silicon Mac.

## Answer: can we reverse-engineer the app without the transmitter?
Yes, partly, and it's worth doing first. Two kinds of analysis:

- **Static analysis (no transmitter needed)**: read the app's code to find the
  ports, the message formats, the connection handshake and the video codec. This
  gives us most of the protocol's *structure*.
- **Dynamic analysis without the transmitter**: run the app and watch what it
  tries to do (which IP/port it contacts, the first message it sends). We can run
  a tiny fake "transmitter" server on the Mac to catch that first message. But
  the app stops at the first reply it doesn't get, so this only reveals the
  opening of the conversation.

What it can't do: confirm real values and timing. One capture with the real
CineEye Air is still needed at the end, but it becomes a quick confirmation
instead of guesswork.

Best target to read: the **Android version of Accsoon Go (APK)**. Android apps
decompile into readable Java/Kotlin with `jadx`, which is far easier than a Mac
binary. If the core is in native `.so` libraries, Ghidra handles those, and their
symbol names usually still help. The Mac app (`.app` bundle) is the second target:
`strings`, `otool -L`, `class-dump`/Hopper/Ghidra.

Legal: reverse-engineering for interoperability with your own device, for
personal use, is generally permitted in the EU and US. Don't copy Accsoon code or
assets into the repo — only our own notes and our own implementation.

## Steps

### 0. Set up the Mac (work moves to a local Claude Code session)
In Terminal on the Mac:
1. Install Homebrew (it asks for your Mac password, and may install Apple's
   Command Line Tools first — accept):
   `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`
2. Make `brew` available (Apple Silicon) — the installer prints these too:
   `echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile && eval "$(/opt/homebrew/bin/brew shellenv)"`
   Check: `brew --version`.
3. Tools: `brew install jadx ffmpeg node nmap python` and
   `brew install --cask wireshark` (jadx pulls in Java automatically).
4. Claude Code: `npm install -g @anthropic-ai/claude-code`.
5. Project: `git clone https://github.com/Ilias823/accsoon-mac-app`,
   `mkdir ~/accsoon-re && mv ~/Downloads/accsoon.apk ~/accsoon-re/`
   (APK stays outside the repo).
6. `cd accsoon-mac-app && claude`, then: "Follow docs/PLAN.md step 1:
   decompile ~/accsoon-re/accsoon.apk and write docs/protocol.md."
Later, for step 5: install Xcode from the Mac App Store.

### 1. Static analysis (no device)
- APK is at `~/accsoon-re/accsoon.apk` (outside the repo). Optionally also copy the Mac app bundle
  (`/Applications/Accsoon Go.app`) into `~/accsoon-re/` —
  **never** committed to the repo.
- Me: decompile with `jadx` / Ghidra. Look for: SSID/IP
  patterns, ports, socket code, packet structs/magic bytes, H.264/H.265 decoder
  setup, RTP/RTSP/custom framing, any encryption/auth keys.
- Output: `docs/protocol.md` — our own written description of the protocol.

### 2. Dynamic check on the Mac (no device)
- Run Accsoon Go with Wireshark on `en0` and `nettop`/`lsof -i` to see what it
  tries to reach.
- `tools/fake_transmitter.py` (already written) listens on the discovered port(s)
  and logs whatever the app sends; extend it with replies from the static
  analysis to push the app further into the handshake.

### 3. Confirm with the real CineEye Air (once)
- Join its Wi-Fi, `nmap` it, capture Wireshark traffic while the Mac app (and
  ideally the iPad app via USB + `rvictl`) connects and streams for ~30 s.
  Commit the `.pcap` under `captures/`.
- Me: reconcile with `docs/protocol.md`.

### 4. Prototype client (Python)
- `tools/client.py`: connect, handshake, dump the elementary video stream to
  stdout → `python tools/client.py | ffplay -` shows live video.
- **Milestone**: live picture with no Accsoon software involved.

### 5. Mac app v1 — clean live monitor (Swift/SwiftUI)
- Network.framework for the connection + auto-reconnect.
- VideoToolbox hardware decode → AVSampleBufferDisplayLayer for low latency.
- UI: connect/status, full-screen, aspect handling, small latency/bitrate overlay.
- Structure: `AccsoonMonitor/` Xcode project — `Protocol/` (packet parsing,
  unit-testable), `Video/` (decoder + display), `UI/`.

## Verification
- Steps 1–2: `docs/protocol.md` predictions match what the fake server receives.
- Step 3: captured traffic matches the documented protocol.
- Step 4: `ffplay` shows the live camera picture.
- Step 5: build in Xcode on the Mac; stream runs ≥30 min without drop; unplug/replug
  Wi-Fi and it reconnects; latency visibly comparable to the iPad app.
- Protocol parsing has unit tests driven by packets from the `.pcap`.

## Where the work runs
From step 0 on, everything runs in a local Claude Code session on the Mac, which
can join the transmitter's Wi-Fi, run Wireshark and build with Xcode.
