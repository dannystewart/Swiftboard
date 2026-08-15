# Swiftboard

A small cross-platform clipboard agent that keeps two machines on the same LAN in sync. Copy on one, paste on the other. Text and images. It runs as a signed background app on macOS and a headless executable on Windows.

## Features

- Syncs **text and images** (images travel as PNG on the wire).
- **Auto-discovery** over UDP broadcast — no need to know the other machine's IP.
- **Liveness reporting** — logs when the peer goes offline and comes back.
- **No echo / ping-pong** — an update received from the peer is never bounced back.
- **No third-party dependencies** — just the Swift toolchain (plus a vendored C image codec on Windows).

## How it works

- A background loop polls the OS clipboard, using a cheap change token (`NSPasteboard.changeCount` on macOS, `GetClipboardSequenceNumber` on Windows) so it only reads when something actually changed.
- On a real change, the item is pushed to the peer over a TCP connection as a length-prefixed JSON frame.
- A TCP server receives frames and writes them to the local clipboard.
- Echo suppression: after applying a received item, the local clipboard is re-read and its hash/token recorded, so the poll loop recognizes it as "already have this" rather than re-broadcasting it. This holds even for images, whose bytes differ after a round-trip through each platform's clipboard.
- Discovery: each instance broadcasts a `SWIFTBOARD/1 <uuid>` beacon every few seconds and listens for the other's. A beacon with a different UUID reveals the peer's address. The same beacons double as a heartbeat for liveness.

Platform specifics live behind a `ClipboardBackend` protocol: macOS uses `NSPasteboard` / `NSBitmapImageRep`; Windows uses the Win32 clipboard API with a small stb-based C shim (`Sources/CSTBImage`) to convert between the clipboard's DIB format and PNG.

## Requirements

- Swift 6.3+ toolchain.
- macOS 26+ or Windows (with the Swift for Windows toolchain).
- Both machines on the same local network / subnet.

## Build

The cross-platform command-line executable, including the Windows build, remains a Swift package:

```bash
swift build -c release
```

The binary lands at `.build/release/swiftboard`.

On macOS, open `Swiftboard.xcodeproj` and build the `Swiftboard` scheme to produce `Swiftboard.app`. The app target compiles the same implementation as the CLI, has the stable bundle identifier `com.dannystewart.swiftboard`, and runs as an `LSUIElement` agent without a Dock icon or window.

## Usage

Run it on both machines. With no arguments, they discover each other:

```bash
swiftboard
```

Or pin the peer explicitly (disables discovery):

```bash
swiftboard 192.168.1.50
```

### Options

- `[peer]` — IP or hostname of the other machine. Omit to auto-discover.
- `--port <n>` — TCP/UDP port to use (default: `8765`).
- `--verbose` — debug logging, including discovery heartbeats.
- `-h`, `--help` — usage.

A few values are fixed in code rather than exposed as flags (see `Config.swift`): max payload size (100 MiB), poll interval (250 ms), and whether images sync. The high payload ceiling accommodates large, high-resolution PNG screenshots while retaining a defensive bound on incoming network frames.

## Firewall

Swiftboard listens on the chosen port over **both TCP** (clipboard data) and **UDP** (discovery beacons). On first run, allow both for Private networks:

- **Windows:** approve the Defender Firewall prompt(s), or add inbound allow rules for the port (TCP and UDP).
- **macOS:** if the outbound connection is blocked, check System Settings → Privacy & Security → Local Network.

## Install for automatic startup

The clipboard is per-session, so Swiftboard must run **in your logged-in user session**, not as a background service in an isolated session.

The install scripts build a release binary, copy it to a stable per-user location, start it immediately, and configure the OS to keep it running. Run the appropriate command from the repository root:

**Windows (PowerShell):**

```powershell
.\Scripts\install-windows.ps1
```

This registers a per-user Scheduled Task. It starts at login, retries failures, and performs a five-minute fallback check. The executable is linked as a GUI-subsystem app, so it stays hidden without opening a console window.

To bypass UDP discovery and configure a fixed peer:

```powershell
.\Scripts\install-windows.ps1 -Peer 192.168.1.50
```

**macOS:**

```bash
sh ./Scripts/install-macos.sh
```

This uses Xcode to build and sign `Swiftboard.app`, installs it under `~/Applications`, and registers a per-user `launchd` LaunchAgent with automatic restart. The bundle declares its Local Network usage and provides a stable code identity for macOS privacy controls. Allow Local Network access when macOS prompts on the first installation.

macOS 27 beta can incorrectly return `EHOSTUNREACH` (`OS error 65`) for private-LAN connections from directly launched third-party background processes, even when their signed bundle identity is recognized. Swiftboard detects that specific failure and retries the framed send through Apple-signed `/usr/bin/nc`; other platforms and unaffected macOS versions continue using the native socket transport.

To configure a fixed peer:

```bash
sh ./Scripts/install-macos.sh 192.168.1.50
```

Run the same script with `-Uninstall` on Windows or `--uninstall` on macOS to stop and remove Swiftboard.

Logs are written to `%LOCALAPPDATA%\Swiftboard\swiftboard.log` on Windows and `~/Library/Logs/swiftboard.log` on macOS. Startup is fail-fast: if Swiftboard cannot initialize its TCP listener or discovery socket, it exits so the OS supervisor can retry instead of leaving a partially working process behind.

The Xcode target uses automatic signing with the development team configured in the project. For distribution to another Mac, select a Developer ID Application certificate and archive/notarize the app in Xcode; the runtime and installer layout do not otherwise change.

## Limitations

- Designed for exactly **two** peers.
- Plain text and images only; rich text (RTF) falls back to plain text on macOS and is ignored on Windows.
- LAN only; discovery relies on UDP broadcast reaching the other machine.
