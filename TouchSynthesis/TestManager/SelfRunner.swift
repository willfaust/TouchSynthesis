import Foundation

/// Orchestrates the self-runner mode for on-device touch synthesis.
///
/// Instead of launching a separate test runner (like WDA), we act as both
/// the IDE (via DTX to testmanagerd) and the runner (via XCTest dlopen).
/// This bypasses AMFI environment variable stripping on iOS 26+.
class SelfRunner {
    let lockdown: LockdownClient
    let testManager: TestManagerClient
    let tunnel: IdeviceTunnel?
    let logger: ProtocolLogger?

    init(lockdown: LockdownClient, testManager: TestManagerClient,
         tunnel: IdeviceTunnel? = nil, logger: ProtocolLogger? = nil) {
        self.lockdown = lockdown
        self.testManager = testManager
        self.tunnel = tunnel
        self.logger = logger
    }

    /// Start self-runner mode: set up testmanagerd DTX, load XCTest, enable automation.
    ///
    /// Flow:
    /// 1. Set XCTest env vars in our own process
    /// 2. Connect to testmanagerd via DTX (two connections for control + test sessions)
    /// 3. Load XCTest.framework via dlopen
    /// 4. Initialize XCTRunnerDaemonSession (XPC to testmanagerd.runner)
    /// 5. Enable automation mode (ONLY `enableAutomationModeWithError:`)
    /// 6. Verify touch synthesis works via daemonProxy
    func start() async throws {
        log("Starting self-runner mode...", level: .info)

        // Step 1: Set XCTest env vars BEFORE anything else.
        let sessionID = testManager.sessionUUID.uuidString.uppercased()
        setenv("XCTestSessionIdentifier", sessionID, 1)
        setenv("XCTestManagerVariant", "DDI", 1)
        setenv("XCTestConfigurationFilePath", "", 1)
        setenv("NSUnbufferedIO", "YES", 1)
        setenv("OS_ACTIVITY_DT_MODE", "YES", 1)
        log("Set XCTestSessionIdentifier: \(sessionID)", level: .info)

        // Step 2: Connect to testmanagerd via DTX (IDE side).
        log("Connecting to testmanagerd via DTX...", level: .info)
        try await testManager.connect()
        log("DTX connected", level: .success)

        try await testManager.initiateControlSession()
        log("Control session initiated", level: .success)

        try await testManager.initiateTestSession()
        log("Test session initiated", level: .success)

        // Step 3: Load XCTest.framework via dlopen.
        let loadError = TouchSynthesizer.loadFramework()
        if let err = loadError {
            throw TestManagerError.launchFailed("XCTest load failed: \(err)")
        }
        log("XCTest.framework loaded", level: .success)

        // Step 4: Initialize the daemon session (XPC to testmanagerd.runner).
        // This call blocks for ~50s on first invocation (XPC handshake).
        TouchSynthesizer.reinitializeSession()
        let available = TouchSynthesizer.isDaemonSessionAvailable
        log("Daemon session available: \(available)", level: available ? .success : .warning)

        // Brief wait for XPC registration to complete
        try await Task.sleep(nanoseconds: 1_000_000_000)

        // Step 5: Enable automation mode via XPC.
        // CRITICAL: Only call enableAutomationModeWithError: — nothing else.
        // Calling finishInitializationForUIAutomation, requestAutomationSession, etc.
        // KILLS the automation overlay after a split second.
        log("Enabling automation mode...", level: .info)
        let automationResult = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            TouchSynthesizer.enableAutomationMode { info in
                continuation.resume(returning: info)
            }
        }
        if let info = automationResult {
            for line in info.components(separatedBy: "\n") where !line.isEmpty {
                log("  \(line)", level: .info)
            }
        }
        log("Automation mode enabled", level: .success)

        // Step 6: Verify touch synthesis works.
        log("Testing touch synthesis...", level: .info)
        let tapResult = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            TouchSynthesizer.tap(at: CGPoint(x: 195, y: 400)) { error in
                continuation.resume(returning: error)
            }
        }
        if let err = tapResult {
            log("Tap test: \(err)", level: .warning)
        } else {
            let path = TouchSynthesizer.lastPathUsed
            log("Tap test succeeded via \(path)!", level: .success)
        }

        log("Self-runner active! Touch synthesis ready.", level: .success)
    }

    // MARK: - Logging

    private func log(_ message: String, level: LogEntry.Level) {
        Task { @MainActor in
            logger?.log(message, phase: "RUNNER", level: level)
        }
    }
}
