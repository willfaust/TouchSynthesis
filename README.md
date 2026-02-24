# TouchSynthesis

On-device iOS touch automation. Connects to its own lockdownd via VPN loopback, establishes a CoreDevice tunnel, and synthesizes touch events system-wide — no Mac, no jailbreak, no WebDriverAgent.

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
│                  │ XCTest synthesis (primary)     │     │
│                  │ IOKit HID (fallback)           │     │
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

TouchSynthesis uses a **self-runner** approach: the app acts as both the IDE (via DTX to testmanagerd) and the test runner (via XCTest dlopen). This bypasses AMFI environment variable stripping on iOS 26+ and eliminates the need for a separate test runner like WebDriverAgent.

### Pipeline

1. **VPN loopback** (LocalDevVPN) creates a network path to the device's own lockdownd: `10.7.0.0 ↔ 10.7.0.1`
2. **Lockdown handshake**: TCP to `10.7.0.1:62078`, TLS session using pairing record
3. **Heartbeat**: marco/polo keepalive to lockdownd (prevents DDI unmount)
4. **CDTunnel**: `StartService(CoreDeviceProxy)` → RemoteServiceDiscovery → developer services
5. **TestManager DTX**: Two DTX connections to `testmanagerd` — control session + daemon session
6. **XCTest dlopen**: Load XCTest.framework at runtime
7. **Session init**: `XCTRunnerDaemonSession` handshake (~50s for XPC setup)
8. **Automation mode**: `enableAutomationModeWithError:` on the shared session
9. **Touch synthesis**: `daemonProxy._XCT_synthesizeEvent:completion:` dispatches system-wide touch events

## Prerequisites

- **iOS 26+** (tested on iPhone 13 Pro, iOS 26.3)
- **DDI mounted + VPN loopback** via [LocalDevVPN](https://localdevvpn.com) or similar
- **Pairing record** from a trusted Mac (`/var/db/lockdown/` or Xcode)
- **Rust toolchain** for building the idevice FFI library

## Project Structure

```
TouchSynthesis/
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
    │   ├── TouchSynthesizer.h/m         # XCTest synthesis + IOKit HID fallback
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
6. Tap the screenshot or touch canvas to synthesize touches
7. Tap **Stop** to tear down (hold volume buttons to dismiss automation overlay if needed)

## Credits

- [idevice](https://github.com/jkcoxson/idevice) — Rust library for lockdownd, CoreDevice tunnel, heartbeat, and screenshots
- [StikDebug](https://github.com/StephenDev0/StikDebug) — Architecture inspiration for the heartbeat + fresh-CDTunnel-per-operation pattern
- **XCTest private API** — `XCSynthesizedEventRecord`, `XCPointerEventPath`, `XCTRunnerDaemonSession` for touch synthesis
- **DTX protocol** — Apple's internal multiplexed RPC protocol, implemented from scratch
- **IOKit HID** — `IOHIDEventCreateDigitizerFingerEvent` for fallback touch injection
