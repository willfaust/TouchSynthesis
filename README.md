# TouchSynthesis

On-device iOS touch automation. Connects to its own lockdownd via VPN loopback, establishes a CoreDevice tunnel, and synthesizes touch events system-wide using XCTest's daemon session — no Mac, no WebDriverAgent, no separate test runner.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  TouchSynthesis.app (on-device)                         │
│                                                         │
│  ┌──────────┐    ┌────────────┐    ┌──────────────────┐ │
│  │ Lockdown │───▶│ CDTunnel   │───▶│ testmanagerd     │ │
│  │ Client   │    │ (RSD proxy)│    │ (DTX protocol)   │ │
│  └──────────┘    └────────────┘    └──────────────────┘ │
│       │                                    │            │
│       │          ┌────────────┐    ┌───────▼──────────┐ │
│       │          │ XCTest.fw  │    │ SelfRunner       │ │
│       └─────────▶│ (dlopen)   │───▶│ (IDE + runner)   │ │
│                  └────────────┘    └──────────────────┘ │
│                         │                               │
│                  ┌──────▼─────────────────────────┐     │
│                  │ TouchSynthesizer               │     │
│                  │ daemonProxy._XCT_synthesize... │     │
│                  │ → session.synthesizeEvent      │     │
│                  │ → IOKit HID (fallback)         │     │
│                  └────────────────────────────────┘     │
└─────────────────────────────────────────────────────────┘
         │
    VPN loopback
    (10.7.0.0 ↔ 10.7.0.1)
         │
┌────────▼────────┐
│   lockdownd     │
│   port 62078    │
└─────────────────┘
```

## How It Works

TouchSynthesis uses a **self-runner** approach: the app acts as both the IDE (via DTX to testmanagerd) and the test runner (via XCTest dlopen). This bypasses AMFI environment variable stripping on iOS 26+ and eliminates the need for WebDriverAgent.

### Pipeline

1. **VPN loopback** (LocalDevVPN) creates a tunnel: `10.7.0.0 ↔ 10.7.0.1`
2. **Lockdown handshake**: TCP to `10.7.0.1:62078` → TLS session with pairing record
3. **CDTunnel**: `StartService(CoreDeviceProxy)` → RemoteServiceDiscovery → developer services
4. **Heartbeat**: marco/polo keepalive to lockdownd (prevents DDI unmount)
5. **TestManager DTX**: Two DTX connections to `testmanagerd.lockdown.secure` — control session + test session
6. **XCTest dlopen**: Load `/System/Developer/Library/Frameworks/XCTest.framework` at runtime
7. **Session init**: `XCTRunnerDaemonSession.initiateSharedSessionWithCompletion:` (blocks ~50s for XPC handshake)
8. **Automation mode**: `enableAutomationModeWithError:` on the shared session
9. **Touch synthesis**: `daemonProxy._XCT_synthesizeEvent:completion:` sends system-wide touch events

### Key Discovery

`enableAutomationModeWithError:` is the **only** initialization call needed. Other methods like `finishInitializationForUIAutomation`, `requestAutomationSession`, or `_XCT_enableAutomationModeWithReply:` will **kill the automation overlay** after a split second. The minimal call is sufficient.

## Prerequisites

- **iOS 26+** (tested on iPhone 13 Pro, iOS 26.3)
- **DDI mounted + VPN loopback** — either [StikDebug](https://stikdebug.com) or [LocalDevVPN](https://localdevvpn.com) works (both provide DDI mounting and VPN loopback to `10.7.0.1`)
- **Pairing record** from a trusted Mac (`/var/db/lockdown/` or Xcode)
- **Rust toolchain** — for building the idevice FFI library (see Build & Deploy below)

## Project Structure

```
TouchSynthesis/
├── project.yml                      # XcodeGen project spec
├── README.md
├── scripts/
│   └── build-idevice.sh             # Cross-compile idevice FFI for iOS
├── vendor/
│   └── idevice/                     # Git submodule: github.com/jkcoxson/idevice
├── TouchSynthesis/
│   ├── Info.plist
│   ├── TouchSynthesis-Bridging-Header.h
│   ├── App/
│   │   ├── TouchSynthesisApp.swift  # @main entry point
│   │   └── ContentView.swift        # UI: one-button automation + touch canvas
│   ├── Model/
│   │   ├── PairingRecord.swift      # Pairing plist parser
│   │   └── DeviceInfo.swift         # Device info struct
│   ├── Lockdown/
│   │   ├── LockdownClient.swift     # TCP + TLS client for lockdownd
│   │   └── LockdownTypes.swift      # Error types
│   ├── DTX/
│   │   ├── DTXConnection.swift      # DTX transport layer
│   │   ├── DTXMessage.swift         # DTX message encoding/decoding
│   │   ├── DTXChannel.swift         # DTX channel multiplexing
│   │   └── DTXAuxiliary.swift       # DTX primitive dictionary
│   ├── TestManager/
│   │   ├── TestManagerClient.swift  # DTX RPC to testmanagerd
│   │   └── SelfRunner.swift         # Self-runner orchestrator
│   ├── TouchSynthesizer/
│   │   ├── TouchSynthesizer.h       # ObjC interface
│   │   └── TouchSynthesizer.m       # XCTest dlopen + event synthesis + IOKit HID
│   ├── Util/
│   │   ├── Logger.swift             # In-app log viewer
│   │   └── BackgroundKeepAlive.swift # CLLocation background mode
│   └── idevice/
│       ├── idevice.h                # Generated: Rust FFI C bindings (build artifact)
│       ├── IdeviceTunnel.h          # ObjC wrapper header
│       ├── IdeviceTunnel.m          # CDTunnel + heartbeat + screenshot
│       └── libidevice_ffi.a         # Generated: static Rust library (build artifact)
└── reference/                       # Archived exploration code
    ├── WDAClient.swift
    └── WDALauncher-full.swift
```

## Build & Deploy

Requires [XcodeGen](https://github.com/yonaskolb/XcodeGen), Xcode 16+, and [Rust](https://rustup.rs/).

```bash
# Clone with submodules
git clone --recursive <repo-url>
cd TouchSynthesis

# Or if already cloned:
git submodule update --init

# Install Rust (if not already installed)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
rustup target add aarch64-apple-ios

# Build the idevice FFI library (cross-compile for iOS)
./scripts/build-idevice.sh

# Generate Xcode project and build
xcodegen generate
xcodebuild -project TouchSynthesis.xcodeproj \
  -scheme TouchSynthesis \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates \
  build

# Deploy to device
ios-deploy --bundle /path/to/TouchSynthesis.app
```

Or after running `build-idevice.sh` and `xcodegen generate`, open `TouchSynthesis.xcodeproj` in Xcode and build/run directly.

## Usage

1. Open StikDebug or LocalDevVPN (either works — they provide DDI mounting + VPN loopback)
2. Launch TouchSynthesis
3. Import pairing record (first run only — saved to Documents)
4. Tap **Start UI Automation**
5. Wait ~60s for XPC handshake + automation mode
6. Tap the screenshot or touch canvas to synthesize touches
7. Tap **Stop UI Automation** (red) to tear down connections (you may still need to hold volume buttons to dismiss the automation overlay)

## Sources & Credits

- **idevice** — Rust FFI library for lockdownd, CoreDevice tunnel, heartbeat, and screenshots. Wraps Apple's proprietary protocols (lockdownd, RemoteServiceDiscovery, DTX).
- **XCTest private API** — `XCSynthesizedEventRecord`, `XCPointerEventPath`, `XCTRunnerDaemonSession` for touch event synthesis. Loaded at runtime via `dlopen`.
- **StikDebug** — Architecture inspiration for the heartbeat + fresh-CDTunnel-per-operation pattern. DDI mounting dependency.
- **DTX protocol** — Apple's internal multiplexed RPC protocol used by Instruments, testmanagerd, and other developer services. Implemented from scratch based on protocol analysis.
- **IOKit HID** — `IOHIDEventCreateDigitizerFingerEvent` + `IOHIDEventSystemClientDispatchEvent` for fallback touch injection when XCTest synthesis isn't available.
