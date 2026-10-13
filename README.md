# Accsoon Monitor for Mac

A small macOS app that shows the live picture from an Accsoon CineEye Air
wireless video transmitter, written from scratch because the official app runs
poorly on the Mac.

- Low-latency live view with hardware decoding, automatic reconnect
- False colour, zebra, 3D LUTs (`.cube`), grids, signal indicator
- Recording to QuickTime files in `~/Movies/Accsoon Monitor`, without
  re-encoding and without the tools burned in
- No Accsoon code or assets: the protocol was worked out for interoperability
  and is described in [docs/protocol.md](docs/protocol.md)

Not affiliated with Accsoon. This repository contains only our own notes and
code. Tested with one CineEye Air only.

The transmitter Wi-Fi channel setting in Settings is **experimental**: its
commands were read from the original app's code and have never been tried on
a device. Reading is harmless; changing the channel is at your own risk.

## Download

Get `Accsoon-Monitor-<version>.zip` from the
[latest release](https://github.com/Ilias823/accsoon-mac-app/releases/latest),
unzip it and move **Accsoon Monitor** to Applications. It runs on Apple
silicon and Intel Macs with macOS 14 or later; no Xcode needed.

The app is not notarised by Apple, so the first launch is blocked. Open it
once, dismiss the warning, then go to **System Settings → Privacy & Security**
and click **Open Anyway**. On macOS 14 you can instead right-click the app and
choose **Open**.

## Use

1. Quit the official Accsoon app.
2. Join the transmitter's Wi-Fi network (turn off any VPN).
3. Open Accsoon Monitor and allow local network access when asked.

Keys: **F** false colour, **Z** zebra, **L** LUT, **G** grid, **⌘O** load LUT,
**⌘R** record,
**⌘I** info overlay, double-click for full screen.

A diagnostic log is written to `~/Library/Logs/AccsoonMonitor.log`.

## Build

Needs macOS 14 or later and Xcode (or just the Command Line Tools).

```bash
AccsoonMonitor/Scripts/build.sh
open AccsoonMonitor/build/AccsoonMonitor.app
```

The script also runs the protocol checks. `AccsoonMonitor/Scripts/release.sh`
builds the universal zip that is attached to releases. `swift build` on
`AccsoonMonitor/Package.swift` builds the same targets.

## Layout

- `AccsoonMonitor/` — the app (`CineEyeProtocol`: packet parsing and
  reassembly; `CineEyeVideo`: H.264 decoding and LUT parsing; `AccsoonMonitor`:
  networking, Metal renderer, UI)
- `tools/` — the Python prototype client, a fake transmitter for testing it,
  and `port_logger.py`, the early tool that just logs what an app sends
- `docs/protocol.md` — protocol notes
- `docs/PLAN.md` — the original project plan
- `captures/` — a place for packet captures from your own device (ignored by
  git by default, because they contain your footage)

## Licence

[MIT](LICENSE)
