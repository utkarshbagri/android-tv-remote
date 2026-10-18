# tv-remote-ios

A minimal iPhone remote for Android TV built on Google's **Android TV Remote protocol v2**. It is the same
protocol the Google TV app uses, and the protobuf field numbers come from
[androidtvremote2](https://github.com/tronikos/androidtvremote2). It handles pairing, the D-pad,
OK/Back/Home, volume, and deep-link launches. There are no dependencies: protobuf is hand-rolled and
the TLS client cert is generated on the device and kept in the Keychain.

```
Sources/ATVRemoteKit/   protocol core (iOS 16+ / macOS 13+)
  Protobuf.swift          tiny protobuf writer/reader + varint framing
  ClientIdentity.swift    RSA key + self-signed X.509 (DER built by hand) in the Keychain
  FramedTLSConnection     Network.framework TLS with client cert; captures the TV's cert
  PairingSession          port 6467: polo handshake + SHA-256 secret from the 6-hex-digit code
  RemoteSession           port 6466: configure/set_active/ping, key inject, app-link launch
  Discovery               Bonjour (_androidtvremote2._tcp + _googlecast._tcp) → IPv4
Sources/atvctl/         macOS CLI over the same kit (used to prove everything against the TV)
App/TVRemote/           SwiftUI app
project.yml             XcodeGen spec → TVRemote.xcodeproj
docs/DEEPLINKS.md       how each streaming app reacts to deep links
```

## Run the iOS app
Xcode must be installed. This Mac only had the Command Line Tools on 2026-10-18.
1. `xcodegen generate` (the generated `TVRemote.xcodeproj` is committed too) and open it in Xcode.
2. Simulator: pick any iPhone and press Run. The Simulator shares the Mac's Wi-Fi, so it reaches the TV.
3. iPhone with free signing: go to Signing & Capabilities, set Team to your Personal Team, then run on
   the device. Trust the developer profile on the iPhone (Settings → General → VPN & Device
   Management). Allow "Local Network" when prompted.
4. In the app: tap Connect (default `192.168.1.128`) or a discovered TV, then Pair with TV, then type
   the code shown on the TV.

## Mac menu-bar widget (no Xcode needed)
`scripts/build-mac-widget.sh` builds `Sources/TVRemoteBar` and installs `~/Applications/TV Remote.app`
(ad-hoc signed, menu-bar only). The panel has power, the current app, mute, a volume slider (sent
as volume key steps, since the protocol has no absolute volume), a D-pad, Back/Home/Play, and
one-click tiles for Netflix, Prime, JioHotstar, YouTube, SonyLIV and Apple TV.
Open it from the menu-bar TV icon, **⌃⌥T** anywhere, or by opening "TV Remote" again from
Spotlight or Finder. The last two matter when a crowded menu bar hides the icon behind the notch;
⌘-drag the icon to the right to keep it visible. Keyboard while it's open: arrows = D-pad, Return = OK, Esc/Delete = Back, Space = play/pause, H = Home.
It shares the Mac's Keychain identity with `atvctl`, so it's already paired. Design check without
a screen: `TVRemoteBar --snapshot out.png` renders the panel with sample state.

## CLI (macOS, no Xcode needed)
```
swift build
.build/debug/atvctl discover
.build/debug/atvctl pair 192.168.1.128          # then type the TV code on stdin
.build/debug/atvctl key 192.168.1.128 home right ok
.build/debug/atvctl launch 192.168.1.128 https://www.netflix.com/title/80100172
.build/debug/atvctl reset                        # delete the client identity (forces re-pair)
ATV_DEBUG=1 …                                    # hex-dump pairing traffic
```

## Protocol gotchas found on the Acer R4
- **The TV doesn't strictly verify the pairing secret against the presented cert.** If TLS presents
  a different identity than the one you hashed, pairing still "succeeds" but port 6466 rejects you
  with `bad certificate` (TV log: `AtvRemote.TcpClient: Incoming connection from unknown device`).
  This bit us on macOS: the file-based login keychain ignores cert labels, and query-wide
  `SecItemDelete` only removes the first match, so stale identities got mixed up. Fix: always take the
  certificate *from the SecIdentity* you hand to TLS, and delete item by item.
- **The TV dedupes paired certs by subject** (`KeyStoreManager: Deleting entry for … (CN=atvremote)`),
  so each identity gets a unique CN, `atvremote-<random>`.
- **Keys sent right after `remote_start` are dropped** (lost at 0 ms, delivered at 300 ms or later).
  `RemoteSession.connect()` waits 500 ms before returning.
- The TV doesn't advertise `_androidtvremote2._tcp`, so discovery also browses `_googlecast._tcp`.
- The cert needs basicConstraints CA:TRUE and a SAN, the same as androidtvremote2's cert.
