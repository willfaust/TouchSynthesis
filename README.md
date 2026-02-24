# TouchSynthesis

On-device iOS remote desktop and touch automation. Exposes a simple TCP protocol for screen streaming and touch input — a client on the local network can connect. No Mac, no jailbreak, no WebDriverAgent.

## Architecture

```
┌─────────────────────────────────────┐
│  TouchSynthesis.app (iOS)           │     TCP :8347
│                                     │◄──────────────────── Client
│  ┌───────────────────────────────┐  │   JSON commands
│  │ CommandServer (TCP/WiFi Aware)│  │   JPEG stream
│  │  ├─ Screenshot streaming      │  │
│  │  ├─ Touch command dispatch    │  │
│  │  └─ Touch stream accumulator  │  │
│  └───────────────┬───────────────┘  │
│                  │                  │
│  ┌───────────────▼───────────────┐  │
│  │ TouchSynthesizer              │  │
│  │  ├─ XCTest synthesis (primary)│  │
│  │  ├─ XCTest screenshots        │  │
│  │  └─ IOKit HID (fallback)      │  │
│  └───────────────────────────────┘  │
│                                     │
│  ┌──────────┐  ┌────────────┐       │
│  │ Lockdown │─▶│ CDTunnel   │──▶ testmanagerd (DTX)
│  │ Client   │  │ (RSD proxy)│       │
│  └──────────┘  └────────────┘       │
│       │                             │
│       │        ┌────────────┐       │
│       └───────▶│ XCTest.fw  │──▶ SelfRunner (IDE + runner)
│                │ (dlopen)   │       │
│                └────────────┘       │
└─────────────────────────────────────┘
         │
    VPN loopback (10.7.0.0 ↔ 10.7.0.1)
         │
    lockdownd :62078
```

## How It Works

TouchSynthesis uses a **self-runner** approach: the app acts as both the IDE (via DTX to testmanagerd) and the test runner (via XCTest dlopen). This bypasses AMFI environment variable stripping on iOS 26+ and eliminates the need for a separate test runner like WebDriverAgent.

### Automation Pipeline

1. **VPN loopback** (LocalDevVPN) creates a network path to the device's own lockdownd: `10.7.0.0 ↔ 10.7.0.1`
2. **Lockdown handshake**: TCP to `10.7.0.1:62078`, TLS session using pairing record
3. **Heartbeat**: marco/polo keepalive to lockdownd (prevents DDI unmount)
4. **CDTunnel**: `StartService(CoreDeviceProxy)` → RemoteServiceDiscovery → developer services
5. **TestManager DTX**: Two DTX connections to `testmanagerd` — control session + daemon session
6. **XCTest dlopen**: Load XCTest.framework at runtime
7. **Session init**: `XCTRunnerDaemonSession` handshake (~50s for XPC setup)
8. **Automation mode**: `enableAutomationModeWithError:` on the shared session
9. **Touch synthesis**: `daemonProxy._XCT_synthesizeEvent:completion:` dispatches system-wide touch events

### Remote Control Protocol

Once automation is active, a TCP server on port 8347 accepts connections from a client on the network. The protocol is simple length-prefixed JSON:

- **Screenshot streaming**: Send `{"action":"startStream","params":{"quality":0.3}}` to begin receiving a continuous JPEG stream. Frames are length-prefixed binary (4-byte big-endian length + JPEG data). XCTest daemon proxy captures at ~15-25 FPS via the existing testmanagerd XPC session. TCP_NODELAY is enabled for low latency.
- **Touch relay**: Clients stream `touchBegan`/`touchMoved`/`touchEnded` events as the user's finger moves. The server accumulates all points with timing, then on `touchEnded` builds a single `XCPointerEventPath` with the full trajectory and synthesizes it as one continuous gesture. Taps, long presses, swipes, and multi-point gestures are all supported.
- **Fire-and-forget commands**: Touch and gesture commands return immediately without waiting for synthesis to complete, minimizing round-trip latency.

## Prerequisites

- **iOS 26+** (tested on iPhone 13 Pro, iOS 26.3)
- **DDI mounted + VPN loopback** via [LocalDevVPN](https://localdevvpn.com) or similar
- **Pairing record** from a trusted Mac (`/var/db/lockdown/` or Xcode)
- **Rust toolchain** for building the idevice FFI library

## Project Structure

```
TouchSynthesis/                         # iOS app (Xcode)
├── project.yml                         # XcodeGen spec
├── scripts/
│   ├── build-idevice.sh                # Cross-compile idevice FFI for iOS
│   └── readwrite-ffi.patch             # Patch for upstream idevice FFI
├── vendor/
│   └── idevice/                        # Git submodule (jkcoxson/idevice)
└── TouchSynthesis/
    ├── App/
    │   ├── TouchSynthesisApp.swift      # Entry point
    │   └── ContentView.swift            # UI + automation controls
    ├── idevice/
    │   ├── IdeviceTunnel.h/m            # ObjC wrapper: CDTunnel, heartbeat, screenshots
    │   ├── idevice.h                    # Generated C bindings (build artifact)
    │   └── libidevice_ffi.a             # Static Rust library (build artifact)
    ├── TestManager/
    │   ├── TestManagerClient.swift      # DTX RPC to testmanagerd
    │   └── SelfRunner.swift             # Self-runner orchestrator
    ├── TouchSynthesizer/
    │   └── TouchSynthesizer.h/m         # XCTest synthesis, screenshots, IOKit HID
    ├── RemoteControl/
    │   ├── CommandServer.swift          # Command dispatch, streaming, touch accumulation
    │   ├── CommandProtocol.swift        # JSON command/response types, frame codec
    │   ├── TCPServer.swift              # NWListener on port 8347
    │   └── WiFiAwareService.swift       # WiFi Aware transport (iOS 26+)
    ├── DTX/
    │   ├── DTXConnection.swift          # DTX transport
    │   ├── DTXMessage.swift             # Message encoding/decoding
    │   ├── DTXChannel.swift             # Channel multiplexing
    │   └── DTXAuxiliary.swift           # Primitive dictionary
    ├── Lockdown/
    │   ├── LockdownClient.swift         # TCP + TLS lockdownd client
    │   └── LockdownTypes.swift          # Error types
    ├── Model/
    │   ├── PairingRecord.swift          # Pairing plist parser
    │   └── DeviceInfo.swift             # Device info
    └── Util/
        ├── Logger.swift                 # In-app log viewer
        └── BackgroundKeepAlive.swift    # CLLocation background mode

```

## Build & Deploy

Requires [XcodeGen](https://github.com/yonaskolb/XcodeGen), Xcode 16+, and [Rust](https://rustup.rs/).

```bash
# Clone with submodules
git clone --recursive <repo-url>
cd TouchSynthesis

# Install Rust if needed
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
rustup target add aarch64-apple-ios

# Build idevice FFI library (cross-compile for iOS)
./scripts/build-idevice.sh

# Generate Xcode project and build
xcodegen generate
xcodebuild -project TouchSynthesis.xcodeproj \
  -scheme TouchSynthesis \
  -sdk iphoneos \
  -allowProvisioningUpdates \
  build
```

Or open `TouchSynthesis.xcodeproj` in Xcode after running `build-idevice.sh` and `xcodegen generate`.

## Usage

1. Open LocalDevVPN (provides DDI mounting + VPN loopback)
2. Launch TouchSynthesis
3. Import pairing record (first run only — saved to app Documents)
4. Tap **Start UI Automation**
5. Wait ~60s for XPC handshake + automation mode
6. The TCP server starts automatically on port 8347 — connect any client to begin remote control
7. Tap **Stop** to tear down (hold volume buttons to dismiss automation overlay if needed)

## Supported Gestures

| Gesture | Method |
|---------|--------|
| Tap | Single-point `XCPointerEventPath` |
| Long press | Touch down + delay + lift |
| Swipe/scroll | Multi-point `XCPointerEventPath` with timing |
| Pinch (zoom) | Two-finger `XCPointerEventPath` |
| Multi-finger tap | Parallel `XCPointerEventPath` per finger |
| Bezier swipe | Cubic bezier curve interpolation |
| Keyboard input | `XCPointerEventPath` key events |
| Hardware buttons | Home, volume up/down |

## Credits

- [idevice](https://github.com/jkcoxson/idevice) — Rust library for lockdownd, CoreDevice tunnel, heartbeat, and screenshots
- [StikDebug](https://github.com/StephenDev0/StikDebug) — Architecture inspiration for the heartbeat + fresh-CDTunnel-per-operation pattern
- **XCTest private API** — `XCSynthesizedEventRecord`, `XCPointerEventPath`, `XCTRunnerDaemonSession` for touch synthesis and screenshots
- **DTX protocol** — Apple's internal multiplexed RPC protocol, implemented from scratch
- **IOKit HID** — `IOHIDEventCreateDigitizerFingerEvent` for fallback touch injection
