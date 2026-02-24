import Foundation

/// Client for Apple's testmanagerd service.
/// Implements the DTX-based RPC protocol to manage XCTest sessions
/// for touch event synthesis via the self-runner approach.
class TestManagerClient {
    let lockdown: LockdownClient
    let tunnel: IdeviceTunnel?  // Optional: for RSD proxy path
    let logger: ProtocolLogger?

    private var conn1: DTXConnection? // IDE↔Daemon (test session)
    private var conn2: DTXConnection? // Control session

    private var daemonChannel1: DTXChannel?
    private var daemonChannel2: DTXChannel?

    let sessionUUID = UUID()

    // Service names to try (varies by iOS version)
    static let serviceNames = [
        "com.apple.testmanagerd.lockdown.secure",
        "com.apple.testmanagerd.lockdown",
    ]

    // RSD service names (iOS 17+/26+)
    static let rsdServiceNames = [
        "com.apple.dt.testmanagerd.remote",
        "com.apple.dt.testmanagerd.remote.automation",
    ]

    static let ideToDaemonProxy =
        "dtxproxy:XCTestManager_IDEInterface:XCTestManager_DaemonConnectionInterface"

    // Continuations for async callback handling
    private var testBundleReadyContinuation: CheckedContinuation<Void, Error>?
    private var testPlanStartedContinuation: CheckedContinuation<Void, Error>?

    init(lockdown: LockdownClient, tunnel: IdeviceTunnel? = nil, logger: ProtocolLogger? = nil) {
        self.lockdown = lockdown
        self.tunnel = tunnel
        self.logger = logger
    }

    // MARK: - Connect to testmanagerd

    func connect() async throws {
        log("Starting testmanagerd connections...", level: .info)

        // Try lockdownd path first, then fall back to RSD proxy
        var servicePort1: UInt16 = 0
        var serviceSSL1 = false
        var servicePort2: UInt16 = 0
        var serviceSSL2 = false
        var useRSD = false

        var lastError: String = ""
        for serviceName in Self.serviceNames {
            do {
                log("Trying lockdown service: \(serviceName)", level: .debug)
                let (p1, s1) = try lockdown.startService(name: serviceName)
                servicePort1 = p1
                serviceSSL1 = s1
                log("Service started on port \(p1) (SSL: \(s1))", level: .success)

                let (p2, s2) = try lockdown.startService(name: serviceName)
                servicePort2 = p2
                serviceSSL2 = s2
                log("Second service on port \(p2) (SSL: \(s2))", level: .success)
                break
            } catch {
                lastError = error.localizedDescription
                log("Service \(serviceName) failed: \(lastError)", level: .warning)
                continue
            }
        }

        // If lockdownd failed, try RSD proxy path
        if servicePort1 == 0 || servicePort2 == 0 {
            guard let tunnel = tunnel else {
                log("Lockdownd failed and no tunnel available for RSD fallback", level: .error)
                throw TestManagerError.serviceNotAvailable
            }

            log("Lockdownd path unavailable. Trying RSD proxy...", level: .info)

            // Try each RSD service name
            for rsdName in Self.rsdServiceNames {
                let port1Result: (port: UInt16, error: String?) = await Task.detached {
                    var outError: NSString?
                    let port = tunnel.createProxy(toRSDService: rsdName, error: &outError)
                    return (port, outError as String?)
                }.value

                if let err = port1Result.error {
                    log("RSD proxy for \(rsdName): \(err)", level: .warning)
                    continue
                }
                guard port1Result.port > 0 else {
                    log("RSD proxy returned port 0 for \(rsdName)", level: .warning)
                    continue
                }

                // Got first proxy, now create second
                let port2Result: (port: UInt16, error: String?) = await Task.detached {
                    var outError: NSString?
                    let port = tunnel.createProxy(toRSDService: rsdName, error: &outError)
                    return (port, outError as String?)
                }.value

                if let err = port2Result.error {
                    log("Second RSD proxy for \(rsdName): \(err)", level: .warning)
                    continue
                }
                guard port2Result.port > 0 else { continue }

                servicePort1 = port1Result.port
                servicePort2 = port2Result.port
                serviceSSL1 = false  // CDTunnel handles encryption
                serviceSSL2 = false
                useRSD = true
                log("RSD proxies created: 127.0.0.1:\(servicePort1) and :\(servicePort2) → \(rsdName)", level: .success)
                break
            }

            guard servicePort1 > 0 && servicePort2 > 0 else {
                log("All service paths failed", level: .error)
                throw TestManagerError.serviceNotAvailable
            }
        }

        // Create DTX connections
        let host = useRSD ? "127.0.0.1" : lockdown.host
        conn1 = DTXConnection(
            host: host, port: servicePort1,
            useTLS: serviceSSL1, pairingRecord: useRSD ? nil : lockdown.pairingRecord)
        conn2 = DTXConnection(
            host: host, port: servicePort2,
            useTLS: serviceSSL2, pairingRecord: useRSD ? nil : lockdown.pairingRecord)

        // Wait a moment for proxy accept threads
        if useRSD {
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        try await conn1!.connect()
        log("DTX connection 1 established\(useRSD ? " (via RSD proxy)" : "")", level: .success)

        try await conn2!.connect()
        log("DTX connection 2 established\(useRSD ? " (via RSD proxy)" : "")", level: .success)

        // Request proxy channels
        daemonChannel1 = try await conn1!.requestChannel(identifier: Self.ideToDaemonProxy)
        log("Channel 1 opened: IDE↔Daemon proxy", level: .success)

        daemonChannel2 = try await conn2!.requestChannel(identifier: Self.ideToDaemonProxy)
        log("Channel 2 opened: IDE↔Daemon proxy", level: .success)

        // Set up callback handler for incoming _XCT_ methods
        daemonChannel1?.messageHandler = { [weak self] msg in
            self?.handleIDECallback(msg)
        }
        daemonChannel2?.messageHandler = { [weak self] msg in
            self?.handleIDECallback(msg)
        }
    }

    // MARK: - Session Management

    func initiateControlSession() async throws {
        guard let ch = daemonChannel2 else { throw TestManagerError.notConnected }

        log("Initiating control session...", level: .info)

        let capabilities: NSDictionary = [
            "XCTIssue capability" as NSString: NSNumber(value: 1),
            "skipped test capability" as NSString: NSNumber(value: 1),
            "test timeout capability" as NSString: NSNumber(value: 1),
        ]

        let reply = try await ch.invoke(
            selector: "_IDE_initiateControlSessionWithCapabilities:",
            arguments: [capabilities]
        )

        if let r = reply, r.payloadHeader.messageType == .error {
            throw TestManagerError.sessionRejected("Control session: \(r.payloadObject ?? "unknown")")
        }

        log("Control session initiated", level: .success)
    }

    func initiateTestSession() async throws {
        guard let ch = daemonChannel1 else { throw TestManagerError.notConnected }

        log("Initiating test session (UUID: \(sessionUUID))...", level: .info)

        let capabilities: NSDictionary = [
            "XCTIssue capability" as NSString: NSNumber(value: 1),
            "skipped test capability" as NSString: NSNumber(value: 1),
            "test timeout capability" as NSString: NSNumber(value: 1),
        ]

        // IMPORTANT: Pass NSUUID, not NSString — testmanagerd archives UUIDs as NSUUID,
        // and the session match depends on the type being correct.
        let reply = try await ch.invoke(
            selector: "_IDE_initiateSessionWithIdentifier:capabilities:",
            arguments: [sessionUUID as NSUUID, capabilities]
        )

        if let r = reply, r.payloadHeader.messageType == .error {
            throw TestManagerError.sessionRejected("Test session: \(r.payloadObject ?? "unknown")")
        }

        log("Test session initiated", level: .success)
    }

    func authorizeSession(pid: Int) async throws {
        guard let ch = daemonChannel1 else { throw TestManagerError.notConnected }

        log("Authorizing session for PID \(pid)...", level: .info)

        let reply = try await ch.invoke(
            selector: "_IDE_authorizeTestSessionWithProcessID:",
            arguments: [NSNumber(value: pid)]
        )

        if let r = reply, r.payloadHeader.messageType == .error {
            throw TestManagerError.authorizationFailed("\(r.payloadObject ?? "unknown")")
        }

        log("Session authorized for PID \(pid)", level: .success)
    }

    func startTestPlan() async throws {
        guard let ch = daemonChannel1 else { throw TestManagerError.notConnected }

        log("Starting test plan (protocol v36)...", level: .info)

        let reply = try await ch.invoke(
            selector: "_IDE_startExecutingTestPlanWithProtocolVersion:",
            arguments: [NSNumber(value: 36)]
        )

        if let r = reply, r.payloadHeader.messageType == .error {
            throw TestManagerError.launchFailed("Start test plan: \(r.payloadObject ?? "unknown")")
        }

        log("Test plan execution started", level: .success)
    }

    // MARK: - Event Synthesis via DTX

    /// Send a synthesized event directly through the DTX daemon channel.
    /// This bypasses XCTest's XPC and goes straight to testmanagerd.
    func synthesizeEvent(_ eventRecord: NSObject) async throws {
        guard let ch = daemonChannel1 else { throw TestManagerError.notConnected }

        log("Sending _XCT_synthesizeEvent via DTX...", level: .info)

        let reply = try await ch.invoke(
            selector: "_XCT_synthesizeEvent:completion:",
            arguments: [eventRecord]
        )

        if let r = reply, r.payloadHeader.messageType == .error {
            throw TestManagerError.launchFailed("synthesizeEvent: \(r.payloadObject ?? "unknown")")
        }

        log("synthesizeEvent sent via DTX", level: .success)
    }

    // MARK: - Async Waiters

    func waitForTestBundleReady(timeout: TimeInterval = 30) async throws {
        log("Waiting for test bundle ready...", level: .info)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            testBundleReadyContinuation = continuation

            // Timeout
            Task {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let c = testBundleReadyContinuation {
                    testBundleReadyContinuation = nil
                    c.resume(throwing: TestManagerError.timeout("test bundle ready"))
                }
            }
        }
        log("Test bundle ready", level: .success)
    }

    func waitForTestPlanStarted(timeout: TimeInterval = 30) async throws {
        log("Waiting for test plan to start...", level: .info)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            testPlanStartedContinuation = continuation

            Task {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let c = testPlanStartedContinuation {
                    testPlanStartedContinuation = nil
                    c.resume(throwing: TestManagerError.timeout("test plan start"))
                }
            }
        }
        log("Test plan started", level: .success)
    }

    // MARK: - IDE Callback Handler

    private func handleIDECallback(_ message: DTXMessage) {
        // Log ALL incoming messages for debugging
        let msgType = message.payloadHeader.messageType
        let aux = message.auxiliaryObjects
        log("DTX msg: type=\(msgType) payload=\(type(of: message.payloadObject)) aux=\(aux.count) ch=\(message.header.channelCode)", level: .debug)

        guard let selector = message.payloadObject as? String else {
            log("Non-string payload: \(String(describing: message.payloadObject))", level: .debug)
            if let data = message.payloadObject as? Data {
                log("  Data payload: \(data.count) bytes", level: .debug)
            }
            // Still try to reply
            Task { try? await replyToCallback(message) }
            return
        }

        log("IDE callback: \(selector)", level: .info)

        switch selector {
        case let s where s.contains("testBundleReady"):
            if let c = testBundleReadyContinuation {
                testBundleReadyContinuation = nil
                c.resume()
            }
            // Send reply acknowledging the callback
            Task {
                try? await replyToCallback(message)
            }

        case let s where s.contains("didBeginExecutingTestPlan"):
            if let c = testPlanStartedContinuation {
                testPlanStartedContinuation = nil
                c.resume()
            }

        case let s where s.contains("testRunnerReady"):
            // Respond with test configuration
            Task {
                try? await replyToCallback(message)
            }

        default:
            // Log and auto-reply to keep the session alive
            Task {
                try? await replyToCallback(message)
            }
        }
    }

    private func replyToCallback(_ message: DTXMessage) async throws {
        // Send a generic OK reply
        let channelCode = message.header.channelCode
        if let channel = channelCode == daemonChannel1?.code ? daemonChannel1 :
                         channelCode == daemonChannel2?.code ? daemonChannel2 : nil {
            try await channel.reply(to: message)
        }
    }

    // MARK: - Cleanup

    func disconnect() {
        conn1?.close()
        conn2?.close()
        conn1 = nil
        conn2 = nil
        daemonChannel1 = nil
        daemonChannel2 = nil
    }

    // MARK: - Logging

    private func log(_ message: String, level: LogEntry.Level) {
        Task { @MainActor in
            logger?.log(message, phase: "P3", level: level)
        }
    }
}

// MARK: - Errors

enum TestManagerError: LocalizedError {
    case serviceNotAvailable
    case notConnected
    case sessionRejected(String)
    case authorizationFailed(String)
    case launchFailed(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .serviceNotAvailable:
            return "testmanagerd service not available. Is the DDI mounted? Use StikDebug to mount it."
        case .notConnected:
            return "Not connected to testmanagerd"
        case .sessionRejected(let d):
            return "Test session rejected: \(d)"
        case .authorizationFailed(let d):
            return "Session authorization failed: \(d)"
        case .launchFailed(let d):
            return "Launch failed: \(d)"
        case .timeout(let what):
            return "Timed out waiting for \(what)"
        }
    }
}
