# Latch

Native iOS import for a Fujifilm X100 VI. Quiet Ink, the same paper and type as [thomas.md](https://thomas.md) and the OpenHealth iOS app: warm paper, New York titles, SF Mono for every number, a hairline instead of a card, color only when something is actually wrong.

XApp’s copy is hard to debug because a dropped socket looks like a spinner. Latch keeps the trace.

## What it talks

The camera is `192.168.0.1`, command port **55740**. The first packet is Fuji’s 82-byte init (`version` `0x8f53e4f2` in front of the GUID), not ISO PTP/IP. After the ack, containers are USB PTP: 12-byte header, little-endian. This follows the published [libfuji](https://github.com/petabyt/libfuji) client (MIT). It is not a decompile of XApp, and it does not include Fujifilm’s code.

Latch, compared with the way that session usually dies:

- sends the init again after Init Fail, including on a reconnect
- waits 50 ms before OpenSession, and the transaction id goes back to 1 on every new socket
- polls `0xD212` until `0xDF00` leaves "press OK". That record is not always first; object count is `0xD222`
- sets client state `0xDF01 = 20` (XApp gallery)
- reads `0xD621` for the import handles, and only falls back to `1..count` when that list is empty
- sets `0xD226 = 2` and `0xD227 = 1` before each file, then both back to 0. Until D227 is 1, ObjectInfo reports about 100 KB
- reads with `GetPartialObject` (`0x101B`) in 1 MB pieces and resumes from the last offset

## Two modes

**Virtual body.** A body in the process. Turn on the stalls (flaky init, OK prompt, mid-file TCP death, 100 KB size lie, skipped settle) and replay XApp next to Latch. Compare runs each fault alone.

**Camera Wi-Fi.** Join `FUJIFILM-xxxx` in Settings (5 GHz is the same protocol, just faster), allow Local Network, come back, import. Files land in the app’s documents folder. OK is on the camera.

## Build

From this repository:

```sh
brew install xcodegen
xcodegen generate
open Latch.xcodeproj
```

Team is set to the same development team as OpenHealth. Run `LatchTests` for the session: init retry, stall resume at transaction id 1, size lie, D621 handles, partial offsets, and the event layout. Those tests run against the in-process body. They do not join a camera.

The phone has to be on the camera’s network. Latch cannot join that SSID for you without the Hotspot Configuration entitlement.
