# Sensate Remote

A remote control for the **Sensate 2** relaxation device — start a session (default *Be Sensate* vibration, up to 60+ minutes, any intensity) without the official app.

- **iOS app** (SwiftUI + CoreBluetooth) — the one-tap button for your iPhone
- **Mac helper** (`sensatectl`) — CLI/controller for macOS

Works because the Sensate keeps playing standalone once a session starts over BLE; no firmware modification needed (and none is possible — the device's secure boot is locked).

## iOS app

1. Open `SensateRemote.xcodeproj` in Xcode (generate it first with [xcodegen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen && xcodegen generate`).
2. Select your iPhone as the run destination.
3. In *Signing & Capabilities*, choose your personal team (free Apple ID works).
4. Press Run. First launch asks for Bluetooth permission — allow it.

> Free signing expires every 7 days: reopen the project and re-run to the phone to renew. A paid developer account ($99/yr) lasts a year.

Usage: pick duration (10–90 min) and intensity, tap **Start**. The app re-triggers the 10-minute default track at each boundary so the session runs the full length, keeps working from the lock screen (bluetooth-central background mode), and sends Stop at the end. Tap Stop any time.

## Mac helper

```bash
cd mac && ./build.sh          # builds SensateCtl.app (one-time Bluetooth permission prompt)
open -n SensateCtl.app --args status    # battery + connection check
open -n SensateCtl.app --args start     # default track @ 100% (gain 95), plays standalone
open -n SensateCtl.app --args stop
open -n SensateCtl.app --args volume 70
```

Results are written to `~/.sensatectl-last.json`.

## Protocol (reverse-engineered, firmware 0.4.40)

Service `00001813-0000-1000-8000-00805f9b30fb`:

| Characteristic | Command | Meaning |
|---|---|---|
| `2A5A` DEVCTRL | `a2` | battery → notify `ed a2 <pct> <usb> <mv_lo> <mv_hi>` |
| `2A57` PLAYBACK | `c9 <gain>` | set volume (app 0–100% ⇒ device 0–95) |
| `2A57` PLAYBACK | `c1 <hi> <lo> 00 00` | play current track from offset (seconds) |
| `2A57` PLAYBACK | `c2` / `c5` | pause / resume |
| `2A57` PLAYBACK | `c4` | stop |

Acks arrive as notifications `ec <cmd> …`; status `ff` means rejected. The device name is `BioSelf <serial>`.

## Notes

- Reverse-engineered from the official Android app and the stock 0.4.40 firmware image for personal interoperability with my own device.
- The Sensate's secure boot v2 + flash encryption (release mode) means custom firmware is not installable; this project uses only the device's documented-by-behavior BLE interface.
- Sessions continue standalone after disconnect; keep the app in range if you rely on its automatic re-triggers for sessions longer than the 10-minute track.
