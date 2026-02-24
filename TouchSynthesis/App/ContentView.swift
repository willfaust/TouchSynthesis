import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var logger = ProtocolLogger()
    @State private var pairingRecord: PairingRecord?
    @State private var lockdownClient: LockdownClient?
    @State private var showFilePicker = false
    @State private var isWorking = false
    @State private var isStopping = false

    // Tunnel
    @State private var ideviceTunnel: IdeviceTunnel?
    @State private var tunnelConnected = false
    @State private var keepAliveActive = false
    @State private var heartbeatTimer: Timer?
    @State private var lastPingOk = false

    // Self-runner
    @State private var testManager: TestManagerClient?
    @State private var selfRunner: SelfRunner?
    @State private var automationReady = false
    @State private var status: String = ""

    // Display
    @State private var screenshotImage: UIImage?
    @State private var touchDots: [CGPoint] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    pairingBar
                    controlSection
                    interactionSection
                    logSection
                }
                .padding()
            }
            .navigationTitle("TouchSynthesis")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        Button("Copy Log") {
                            UIPasteboard.general.string = logger.allText
                        }
                        Button("Clear") { logger.clear() }
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.data, .propertyList],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .onAppear { loadSavedPairing() }
    }

    // MARK: - Pairing Bar

    private var pairingBar: some View {
        HStack {
            if pairingRecord != nil {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Pairing loaded")
                    .font(.subheadline).fontWeight(.medium)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("No pairing file")
                    .font(.subheadline).fontWeight(.medium)
            }
            Spacer()
            glassButton(pairingRecord != nil ? "Re-import" : "Import Pairing") {
                showFilePicker = true
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Control Section

    private var controlSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Start / Stop button
            Button {
                if automationReady {
                    stopEverything()
                } else {
                    Task { await startEverything() }
                }
            } label: {
                HStack {
                    if isWorking || isStopping {
                        ProgressView()
                            .tint(.white)
                    }
                    if automationReady || isStopping {
                        Image(systemName: "stop.fill")
                        Text(isStopping ? "Stopping..." : "Stop UI Automation")
                            .fontWeight(.semibold)
                    } else {
                        Image(systemName: isWorking ? "gearshape.2" : "play.fill")
                        Text(isWorking ? "Working..." : "Start UI Automation")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint((automationReady || isStopping) ? .red : .blue)
            .disabled(pairingRecord == nil || isWorking || isStopping)
            .modifier(GlassModifier(tintColor: (automationReady || isStopping) ? .red : .blue))

            // Status
            if !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(automationReady ? .green : .secondary)
            }

            // Status dots
            HStack(spacing: 16) {
                statusDot("Connected", on: tunnelConnected)
                statusDot("Alive", on: lastPingOk)
                statusDot("BG", on: keepAliveActive)
                statusDot("Touch", on: automationReady)
            }
        }
    }

    // MARK: - Interaction Section (screenshot + touch canvas side by side)

    private var interactionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if automationReady {
                // Action buttons
                HStack(spacing: 8) {
                    glassButton("Screenshot", icon: "camera", alwaysEnabled: true) {
                        Task { await takeDeviceScreenshot() }
                    }
                    glassButton("Tap Center", icon: "hand.tap", alwaysEnabled: true) {
                        Task { await directTap(at: CGPoint(x: 195, y: 422)) }
                    }
                    glassButton("Scroll Down", icon: "arrow.down", alwaysEnabled: true) {
                        Task { await directSwipe(from: CGPoint(x: 195, y: 600), to: CGPoint(x: 195, y: 300), duration: 0.5) }
                    }
                    glassButton("Scroll Up", icon: "arrow.up", alwaysEnabled: true) {
                        Task { await directSwipe(from: CGPoint(x: 195, y: 300), to: CGPoint(x: 195, y: 600), duration: 0.5) }
                    }
                }

                // Screenshot (small, left) + Touch canvas (right)
                HStack(alignment: .top, spacing: 10) {
                    // Small screenshot thumbnail — tappable
                    if let image = screenshotImage {
                        GeometryReader { geo in
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .cornerRadius(8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(.secondary.opacity(0.3))
                                )
                                .contentShape(Rectangle())
                                .onTapGesture { location in
                                    let imageAspect = image.size.width / image.size.height
                                    let viewWidth = geo.size.width
                                    let viewHeight = viewWidth / imageAspect
                                    let scaleX = image.size.width / viewWidth
                                    let scaleY = image.size.height / viewHeight
                                    let devicePoint = CGPoint(
                                        x: location.x * scaleX,
                                        y: location.y * scaleY
                                    )
                                    logger.log("Screenshot tap → device (\(Int(devicePoint.x)), \(Int(devicePoint.y)))", phase: "TOUCH", level: .info)
                                    Task { await directTap(at: devicePoint) }
                                }
                        }
                        .aspectRatio(image.size.width / image.size.height, contentMode: .fit)
                        .frame(width: 120)
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.gray.opacity(0.15))
                            .frame(width: 120, height: 200)
                            .overlay(
                                Text("No screenshot")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            )
                    }

                    // Touch canvas
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Touch Canvas")
                                .font(.caption).fontWeight(.medium)
                            Spacer()
                            Button("Clear") { touchDots.removeAll() }
                                .font(.caption2)
                        }

                        ZStack {
                            Rectangle()
                                .fill(Color.black)
                                .overlay(
                                    Canvas { context, size in
                                        for dot in touchDots {
                                            let rect = CGRect(x: dot.x - 4, y: dot.y - 4, width: 8, height: 8)
                                            context.fill(Path(ellipseIn: rect), with: .color(.red))
                                        }
                                    }
                                )
                                .contentShape(Rectangle())
                                .onTapGesture { location in
                                    touchDots.append(location)
                                    logger.log("Canvas tap (\(Int(location.x)), \(Int(location.y)))", phase: "TOUCH", level: .debug)
                                    let synthPoint = CGPoint(x: location.x + 50, y: location.y)
                                    logger.log("Synth tap at (\(Int(synthPoint.x)), \(Int(synthPoint.y)))", phase: "TOUCH", level: .info)
                                    Task {
                                        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                                            TouchSynthesizer.tap(at: synthPoint) { error in
                                                if let error = error {
                                                    self.logger.log("XCTest tap failed: \(error)", phase: "TOUCH", level: .warning)
                                                    TouchSynthesizer.hidTap(at: synthPoint) { hidErr in
                                                        if let hidErr = hidErr {
                                                            self.logger.log("HID fallback failed: \(hidErr)", phase: "TOUCH", level: .error)
                                                        } else {
                                                            self.logger.log("Tap OK via \(TouchSynthesizer.lastPathUsed)", phase: "TOUCH", level: .success)
                                                        }
                                                        c.resume()
                                                    }
                                                } else {
                                                    self.logger.log("Tap OK via \(TouchSynthesizer.lastPathUsed)", phase: "TOUCH", level: .success)
                                                    c.resume()
                                                }
                                            }
                                        }
                                    }
                                }

                            ForEach(Array(touchDots.enumerated()), id: \.offset) { _, dot in
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 10, height: 10)
                                    .position(dot)
                            }
                        }
                        .frame(height: 250)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                        Text("Green = finger, Red = synth (50px right)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Log Section

    private var logSection: some View {
        GroupBox("Log") {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(logger.entries) { entry in
                    Text(entry.formatted)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(entry.level.color)
                        .id(entry.id)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Helpers

    private func statusDot(_ label: String, on: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(on ? .green : .gray.opacity(0.3))
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption2)
                .foregroundStyle(on ? .primary : .secondary)
        }
    }

    /// Liquid glass button on iOS 26+, bordered on older
    private func glassButton(_ title: String, icon: String? = nil, alwaysEnabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if let icon = icon {
                Label(title, systemImage: icon)
                    .font(.caption)
            } else {
                Text(title)
                    .font(.caption)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(alwaysEnabled ? false : isWorking)
        .modifier(GlassModifier())
    }

    // MARK: - Actions

    private func loadSavedPairing() {
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let path = docsDir.appendingPathComponent("pairing.plist")
        guard FileManager.default.fileExists(atPath: path.path) else {
            logger.log("No saved pairing file — import one", phase: "INIT", level: .warning)
            return
        }
        do {
            let data = try Data(contentsOf: path)
            pairingRecord = try PairingRecord(fromData: data)
            logger.log("Loaded saved pairing (HostID: \(pairingRecord!.hostID))", phase: "INIT", level: .success)
        } catch {
            logger.log("Failed to load saved pairing: \(error)", phase: "INIT", level: .error)
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }

            guard url.startAccessingSecurityScopedResource() else {
                logger.log("Cannot access file", phase: "Import", level: .error)
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            let data = try Data(contentsOf: url)
            let record = try PairingRecord(fromData: data)
            pairingRecord = record

            let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let savedURL = docsDir.appendingPathComponent("pairing.plist")
            try data.write(to: savedURL)

            logger.log("Pairing file loaded & saved (HostID: \(record.hostID))", phase: "Import", level: .success)
        } catch {
            logger.log("Import failed: \(error.localizedDescription)", phase: "Import", level: .error)
        }
    }

    // MARK: - Start Everything

    private func startEverything() async {
        isWorking = true
        defer { isWorking = false }

        guard let record = pairingRecord else {
            logger.log("No pairing record", phase: "START", level: .error)
            return
        }

        // Step 1: Lockdown handshake
        status = "Connecting lockdown..."
        logger.log("Starting full handshake...", phase: "P1")

        do {
            let client = LockdownClient(pairingRecord: record)
            try client.connect()
            lockdownClient = client
            logger.log("TCP connected", phase: "P1", level: .success)

            let type = try client.queryType()
            logger.log("QueryType: \(type)", phase: "P1", level: .success)

            let sid = try client.startSession()
            logger.log("Session started (ID: \(sid))", phase: "P1", level: .success)
            logger.log("TLS active: \(client.isTLSActive)", phase: "P1",
                       level: client.isTLSActive ? .success : .warning)
        } catch {
            status = "Handshake failed: \(error.localizedDescription)"
            logger.log("Handshake failed: \(error.localizedDescription)", phase: "P1", level: .error)
            if let recovery = (error as? LockdownError)?.recoverySuggestion {
                logger.log("Fix: \(recovery)", phase: "P1", level: .warning)
            }
            return
        }

        // Step 2: Tunnel + heartbeat
        status = "Starting tunnel & heartbeat..."
        logger.log("Starting lockdownd heartbeat...", phase: "P3")

        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let pairingPath = docsDir.appendingPathComponent("pairing.plist").path

        let tunnel = ideviceTunnel ?? IdeviceTunnel()

        let errorMsg: String? = await Task.detached {
            tunnel.connect(withPairingFile: pairingPath, deviceIP: "10.7.0.1", port: 62078)
        }.value

        if let errorMsg = errorMsg {
            status = "Tunnel failed: \(errorMsg)"
            logger.log("Connect failed: \(errorMsg)", phase: "P3", level: .error)
            logger.log("Is DDI mounted? Use StikDebug to mount it first.", phase: "P3", level: .warning)
            return
        }

        ideviceTunnel = tunnel
        tunnelConnected = true
        logger.log("Lockdownd heartbeat started (marco/polo)", phase: "P3", level: .success)
        logger.log("Each operation will create a fresh CDTunnel on demand", phase: "P3", level: .info)

        BackgroundKeepAlive.shared.start()
        keepAliveActive = BackgroundKeepAlive.shared.isActive
        if keepAliveActive {
            logger.log("Background keepalive active", phase: "P3", level: .success)
        } else {
            logger.log("Background keepalive needs location permission — check Settings", phase: "P3", level: .warning)
        }

        startHeartbeat()
        lastPingOk = true

        // Step 3: Self-runner (DTX + XCTest + automation)
        status = "Starting self-runner..."
        logger.log("Starting self-runner mode...", phase: "RUNNER", level: .info)

        do {
            let lockdown = LockdownClient(pairingRecord: record)
            try lockdown.connect()
            logger.log("Lockdown TCP connected (for testmanagerd)", phase: "RUNNER", level: .success)

            let _ = try lockdown.queryType()
            let sid = try lockdown.startSession()
            logger.log("Lockdown session: \(sid)", phase: "RUNNER", level: .success)

            let tm = TestManagerClient(lockdown: lockdown, tunnel: ideviceTunnel, logger: logger)
            testManager = tm

            let runner = SelfRunner(
                lockdown: lockdown,
                testManager: tm,
                tunnel: ideviceTunnel,
                logger: logger
            )
            selfRunner = runner

            status = "Setting up testmanagerd + XCTest..."
            try await runner.start()

            automationReady = true
            status = "Self-runner active! Touch synthesis ready."
            logger.log("Self-runner mode active!", phase: "RUNNER", level: .success)

        } catch {
            status = "Self-runner failed: \(error.localizedDescription)"
            logger.log("Self-runner failed: \(error.localizedDescription)", phase: "RUNNER", level: .error)
            return
        }

        // Step 4: Initial screenshot
        status = "Taking initial screenshot..."
        await takeDeviceScreenshot()
        status = "Ready! Tap screenshot to interact."
    }

    // MARK: - Stop Everything

    private func stopEverything() {
        isStopping = true
        logger.log("Stopping UI automation...", phase: "STOP", level: .info)

        // Disconnect testmanagerd DTX sessions
        testManager?.disconnect()
        testManager = nil
        selfRunner = nil
        logger.log("DTX connections closed", phase: "STOP", level: .success)

        // Stop heartbeat timer
        stopHeartbeat()
        lastPingOk = false

        // Disconnect tunnel
        ideviceTunnel?.disconnect()
        ideviceTunnel = nil
        tunnelConnected = false
        logger.log("Tunnel disconnected", phase: "STOP", level: .success)

        // Stop background keepalive
        BackgroundKeepAlive.shared.stop()
        keepAliveActive = false

        // Disconnect lockdown
        lockdownClient?.disconnect()
        lockdownClient = nil

        // Reset UI state
        screenshotImage = nil
        touchDots.removeAll()
        automationReady = false
        isStopping = false
        status = "Stopped. You may need to hold volume buttons to dismiss the overlay."
        logger.log("All connections torn down", phase: "STOP", level: .success)
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        stopHeartbeat()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            guard let tunnel = ideviceTunnel, tunnelConnected else { return }
            Task.detached {
                let ok = tunnel.pingTunnel()
                await MainActor.run {
                    lastPingOk = ok
                    if ok {
                        logger.log("Ping: device reachable", phase: "HB", level: .debug)
                    } else {
                        logger.log("Ping: device unreachable", phase: "HB", level: .warning)
                    }
                }
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    // MARK: - Screenshot

    private func takeDeviceScreenshot() async {
        guard let tunnel = ideviceTunnel else { return }

        logger.log("Taking screenshot (fresh CDTunnel)...", phase: "P3")

        let result: (data: Data?, error: String?) = await Task.detached {
            var outError: NSString?
            let data = tunnel.takeScreenshotAndReturnError(&outError)
            return (data as Data?, outError as String?)
        }.value

        if let error = result.error {
            logger.log("Screenshot failed: \(error)", phase: "P3", level: .error)
            return
        }

        guard let pngData = result.data, let image = UIImage(data: pngData) else {
            logger.log("Screenshot: invalid image data", phase: "P3", level: .error)
            return
        }

        screenshotImage = image
        logger.log("Screenshot captured (\(Int(image.size.width))x\(Int(image.size.height)), \(pngData.count / 1024)KB)", phase: "P3", level: .success)
    }

    // MARK: - Touch

    private func directTap(at point: CGPoint) async {
        logger.log("Tap at (\(Int(point.x)), \(Int(point.y)))...", phase: "TOUCH", level: .info)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            TouchSynthesizer.tap(at: point) { error in
                if let error = error {
                    self.logger.log("XCTest tap failed: \(error) — trying HID fallback", phase: "TOUCH", level: .warning)
                    TouchSynthesizer.hidTap(at: point) { hidError in
                        if let hidError = hidError {
                            self.logger.log("HID tap also failed: \(hidError)", phase: "TOUCH", level: .error)
                        } else {
                            self.logger.log("Tap OK via \(TouchSynthesizer.lastPathUsed)", phase: "TOUCH", level: .success)
                        }
                        continuation.resume()
                    }
                } else {
                    self.logger.log("Tap OK via \(TouchSynthesizer.lastPathUsed)", phase: "TOUCH", level: .success)
                    continuation.resume()
                }
            }
        }

        try? await Task.sleep(nanoseconds: 500_000_000)
        await takeDeviceScreenshot()
    }

    private func directSwipe(from: CGPoint, to: CGPoint, duration: TimeInterval) async {
        logger.log("Swipe (\(Int(from.x)),\(Int(from.y))) → (\(Int(to.x)),\(Int(to.y)))...", phase: "TOUCH", level: .info)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            TouchSynthesizer.swipe(from: from, to: to, duration: duration) { error in
                if let error = error {
                    self.logger.log("XCTest swipe failed: \(error) — trying HID fallback", phase: "TOUCH", level: .warning)
                    TouchSynthesizer.hidSwipe(from: from, to: to, duration: duration) { hidError in
                        if let hidError = hidError {
                            self.logger.log("HID swipe also failed: \(hidError)", phase: "TOUCH", level: .error)
                        } else {
                            self.logger.log("Swipe OK via \(TouchSynthesizer.lastPathUsed)", phase: "TOUCH", level: .success)
                        }
                        continuation.resume()
                    }
                } else {
                    self.logger.log("Swipe OK via \(TouchSynthesizer.lastPathUsed)", phase: "TOUCH", level: .success)
                    continuation.resume()
                }
            }
        }

        try? await Task.sleep(nanoseconds: 500_000_000)
        await takeDeviceScreenshot()
    }
}

// MARK: - Liquid Glass Modifier

/// Applies `.glassEffect(.regular.interactive())` on iOS 26+, no-op on older
struct GlassModifier: ViewModifier {
    var tintColor: Color? = nil

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if let tint = tintColor {
                content
                    .glassEffect(.regular.interactive().tint(tint), in: .capsule)
            } else {
                content
                    .glassEffect(.regular.interactive(), in: .capsule)
            }
        } else {
            content
        }
    }
}
