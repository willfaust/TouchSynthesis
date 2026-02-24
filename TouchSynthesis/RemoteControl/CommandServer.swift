import Foundation
import Network
import UIKit

/// Accepts NWConnections from any transport (WiFi Aware or TCP),
/// reads length-prefixed JSON commands, dispatches to TouchSynthesizer,
/// and sends responses back. Supports continuous screenshot streaming.
@MainActor
class CommandServer: ObservableObject {
    private var tcpServer: TCPServer?
    private var wifiAwareService: AnyObject?  // WiFiAwareService (iOS 26+), type-erased
    private var connections: [ObjectIdentifier: ClientConnection] = [:]
    weak var tunnel: IdeviceTunnel?
    private let logger: ProtocolLogger

    @Published var connectedClients: Int = 0
    @Published var tcpRunning = false
    @Published var wifiAwareRunning = false

    private let screenshotQueue = DispatchQueue(label: "com.touchremote.screenshot")
    private var screenshotInProgress = false

    /// Per-finger touch stream accumulators.
    private var touchAccumulators: [Int: TouchAccumulator] = [:]

    /// When true, touch streaming uses IOKit HID (real-time) instead of XCTest (batched on touchEnded).
    private var useHID = false

    init(logger: ProtocolLogger) {
        self.logger = logger
    }

    func start() {
        startTCP()
        startWiFiAware()
    }

    func stop() {
        tcpServer?.stop()
        tcpServer = nil
        tcpRunning = false

        if #available(iOS 26.0, *) {
            (wifiAwareService as? WiFiAwareService)?.stop()
        }
        wifiAwareService = nil
        wifiAwareRunning = false

        for (_, conn) in connections {
            conn.stopStreaming()
            conn.cancel()
        }
        connections.removeAll()
        connectedClients = 0

        logger.log("Remote server stopped", phase: "REMOTE", level: .info)
    }

    // MARK: - Transports

    private func startTCP() {
        let server = TCPServer()
        server.onConnection = { [weak self] conn in
            self?.acceptConnection(conn, transport: "TCP")
        }
        server.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.tcpRunning = true
                self.logger.log("TCP server listening on port 8347", phase: "REMOTE", level: .success)
            case .failed(let error):
                self.tcpRunning = false
                self.logger.log("TCP server failed: \(error)", phase: "REMOTE", level: .error)
            case .cancelled:
                self.tcpRunning = false
            default:
                break
            }
        }
        do {
            try server.start()
            tcpServer = server
        } catch {
            logger.log("TCP server start failed: \(error)", phase: "REMOTE", level: .error)
        }
    }

    private func startWiFiAware() {
        guard #available(iOS 26.0, *) else {
            logger.log("WiFi Aware requires iOS 26+", phase: "REMOTE", level: .warning)
            return
        }
        let service = WiFiAwareService()
        service.onConnection = { [weak self] conn in
            self?.acceptConnection(conn, transport: "WiFiAware")
        }
        do {
            try service.start()
            wifiAwareService = service
            wifiAwareRunning = true
            logger.log("WiFi Aware service publishing", phase: "REMOTE", level: .success)
        } catch {
            logger.log("WiFi Aware: \(error.localizedDescription)", phase: "REMOTE", level: .warning)
        }
    }

    // MARK: - Connection Handling

    private func acceptConnection(_ nwConn: NWConnection, transport: String) {
        let client = ClientConnection(nwConn: nwConn, transport: transport)
        let key = ObjectIdentifier(client)
        connections[key] = client
        connectedClients = connections.count

        let endpoint = nwConn.endpoint
        logger.log("Client connected via \(transport): \(endpoint)", phase: "REMOTE", level: .success)

        client.onDisconnect = { [weak self] in
            guard let self else { return }
            self.connections.removeValue(forKey: key)
            self.connectedClients = self.connections.count
            self.touchAccumulators.removeAll()
            self.logger.log("Client disconnected (\(transport)): \(endpoint)", phase: "REMOTE", level: .info)
        }

        client.onCommand = { [weak self] cmd in
            guard let self else { return }
            Task { @MainActor in
                do {
                    let response = await self.dispatch(cmd, client: client)
                    if let response { client.send(response) }
                } catch {
                    self.logger.log("Dispatch error: \(error)", phase: "REMOTE", level: .error)
                    let errResponse = CommandResponse(id: cmd.id, success: false, error: "\(error)")
                    client.send(errResponse)
                }
            }
        }

        client.start()
    }

    // MARK: - Command Dispatch

    private func dispatch(_ cmd: Command, client: ClientConnection) async -> CommandResponse? {
        let action = cmd.action

        switch action {
        // Fire-and-forget: respond immediately, run synthesis in background
        case "tap":
            let point = pointFrom(cmd.params, xKey: "x", yKey: "y")
            fireAndForget(id: cmd.id) { TouchSynthesizer.tap(at: point, completion: $0) }
            return CommandResponse(id: cmd.id, success: true)

        case "longPress":
            let point = pointFrom(cmd.params, xKey: "x", yKey: "y")
            let duration = cmd.params?["duration"]?.doubleValue ?? 1.0
            fireAndForget(id: cmd.id) { TouchSynthesizer.longPress(at: point, duration: duration, completion: $0) }
            return CommandResponse(id: cmd.id, success: true)

        case "swipe":
            let from = pointFrom(cmd.params, xKey: "fromX", yKey: "fromY")
            let to = pointFrom(cmd.params, xKey: "toX", yKey: "toY")
            let duration = cmd.params?["duration"]?.doubleValue ?? 0.5
            fireAndForget(id: cmd.id) { TouchSynthesizer.swipe(from: from, to: to, duration: duration, completion: $0) }
            return CommandResponse(id: cmd.id, success: true)

        case "pinch":
            let center = pointFrom(cmd.params, xKey: "centerX", yKey: "centerY")
            let radius = CGFloat(cmd.params?["radius"]?.doubleValue ?? 100)
            let scale = CGFloat(cmd.params?["scale"]?.doubleValue ?? 1.0)
            let duration = cmd.params?["duration"]?.doubleValue ?? 0.5
            fireAndForget(id: cmd.id) { TouchSynthesizer.pinch(atCenter: center, radius: radius, scale: scale, duration: duration, completion: $0) }
            return CommandResponse(id: cmd.id, success: true)

        case "multiFingerTap":
            guard let pointDicts = cmd.params?["points"]?.arrayValue else {
                return CommandResponse(id: cmd.id, success: false, error: "Missing 'points' array")
            }
            let nsPoints = pointDicts.compactMap { item -> NSValue? in
                guard let dict = item.dictValue,
                      let x = dict["x"]?.doubleValue,
                      let y = dict["y"]?.doubleValue else { return nil }
                return NSValue(cgPoint: CGPoint(x: x, y: y))
            }
            fireAndForget(id: cmd.id) { TouchSynthesizer.multiFingerTap(atPoints: nsPoints, completion: $0) }
            return CommandResponse(id: cmd.id, success: true)

        case "bezierSwipe":
            let start = pointFromDict(cmd.params?["start"]?.dictValue)
            let cp1 = pointFromDict(cmd.params?["cp1"]?.dictValue)
            let cp2 = pointFromDict(cmd.params?["cp2"]?.dictValue)
            let end = pointFromDict(cmd.params?["end"]?.dictValue)
            let duration = cmd.params?["duration"]?.doubleValue ?? 0.5
            fireAndForget(id: cmd.id) {
                TouchSynthesizer.bezierSwipe(from: start, controlPoint1: cp1, controlPoint2: cp2, to: end, duration: duration, completion: $0)
            }
            return CommandResponse(id: cmd.id, success: true)

        // Real-time touch streaming
        case "touchBegan":
            let point = pointFrom(cmd.params, xKey: "x", yKey: "y")
            let finger = Int(cmd.params?["finger"]?.doubleValue ?? 0)
            touchAccumulators[finger] = TouchAccumulator(point: point)
            if useHID {
                TouchSynthesizer.hidDispatchFinger(at: point, touching: true, inRange: true)
            }
            return CommandResponse(id: cmd.id, success: true)

        case "touchMoved":
            let finger = Int(cmd.params?["finger"]?.doubleValue ?? 0)
            let pointDicts = cmd.params?["points"]?.arrayValue ?? []
            let cgPoints = pointDicts.compactMap { item -> CGPoint? in
                guard let dict = item.dictValue,
                      let x = dict["x"]?.doubleValue,
                      let y = dict["y"]?.doubleValue else { return nil }
                return CGPoint(x: x, y: y)
            }
            if useHID {
                // Dispatch each point immediately for real-time HID
                for pt in cgPoints {
                    TouchSynthesizer.hidDispatchFinger(at: pt, touching: true, inRange: true)
                }
            }
            if var accumulator = touchAccumulators[finger] {
                accumulator.addPoints(cgPoints)
                touchAccumulators[finger] = accumulator
            }
            return CommandResponse(id: cmd.id, success: true)

        case "touchEnded":
            let endPoint = pointFrom(cmd.params, xKey: "x", yKey: "y")
            let finger = Int(cmd.params?["finger"]?.doubleValue ?? 0)
            if useHID {
                TouchSynthesizer.hidDispatchFinger(at: endPoint, touching: false, inRange: false)
                touchAccumulators.removeValue(forKey: finger)
            } else if let accumulator = touchAccumulators.removeValue(forKey: finger) {
                synthesizeAccumulatedTouch(accumulator, endPoint: endPoint, id: cmd.id)
            } else {
                fireAndForget(id: cmd.id) { TouchSynthesizer.tap(at: endPoint, completion: $0) }
            }
            return CommandResponse(id: cmd.id, success: true)

        case "setHID":
            let enabled = cmd.params?["enabled"]?.doubleValue ?? 0
            useHID = enabled != 0
            logger.log("HID mode: \(useHID ? "ON" : "OFF")", phase: "REMOTE", level: .info)
            if useHID {
                // Force IOKit load and log status
                let _ = TouchSynthesizer.hidDispatchFinger(at: .zero, touching: false, inRange: false)
                let status = TouchSynthesizer.hidStatus()
                logger.log("HID Status:\n\(status)", phase: "REMOTE", level: .info)
            }
            return CommandResponse(id: cmd.id, success: true)

        case "hidTap":
            let point = pointFrom(cmd.params, xKey: "x", yKey: "y")
            fireAndForget(id: cmd.id) { TouchSynthesizer.hidTap(at: point, completion: $0) }
            return CommandResponse(id: cmd.id, success: true)

        case "typeText":
            let text = cmd.params?["text"]?.stringValue ?? ""
            let speed = Int(cmd.params?["speed"]?.doubleValue ?? 60)
            fireAndForget(id: cmd.id) { TouchSynthesizer.typeText(text, typingSpeed: speed, completion: $0) }
            return CommandResponse(id: cmd.id, success: true)

        case "typeKey":
            let key = cmd.params?["key"]?.stringValue ?? ""
            let modifiers = UInt(cmd.params?["modifiers"]?.doubleValue ?? 0)
            fireAndForget(id: cmd.id) { TouchSynthesizer.typeKey(key, modifiers: modifiers, completion: $0) }
            return CommandResponse(id: cmd.id, success: true)

        case "pressButton":
            let button = UInt(cmd.params?["button"]?.doubleValue ?? 0)
            fireAndForget(id: cmd.id) { TouchSynthesizer.pressButton(button, completion: $0) }
            return CommandResponse(id: cmd.id, success: true)

        case "screenshot":
            return await takeScreenshot(id: cmd.id)

        case "startStream":
            let quality = cmd.params?["quality"]?.doubleValue ?? 0.3
            startStreaming(client: client, quality: quality)
            return CommandResponse(id: cmd.id, success: true)

        case "stopStream":
            client.stopStreaming()
            return CommandResponse(id: cmd.id, success: true)

        case "xctest_diag":
            let path = NSTemporaryDirectory() + "xctest_diag.txt"
            if let data = try? String(contentsOfFile: path, encoding: .utf8) {
                return CommandResponse(id: cmd.id, success: true, data: data)
            } else {
                return CommandResponse(id: cmd.id, success: false, error: "No diag file found")
            }

        default:
            return CommandResponse(id: cmd.id, success: false, error: "Unknown action: \(action)")
        }
    }

    // MARK: - Streaming

    private func startStreaming(client: ClientConnection, quality: Double) {
        logger.log("Starting stream (quality=\(quality))", phase: "REMOTE", level: .info)
        client.streaming = true
        let jpegQuality = CGFloat(max(0.1, min(1.0, quality)))

        // Try XCTest daemon proxy screenshots first (much faster, no CDTunnel per frame)
        if TouchSynthesizer.isLoaded {
            startXCTestStream(client: client, quality: jpegQuality)
        } else if let tunnel = tunnel {
            startCDTunnelStream(client: client, tunnel: tunnel, quality: jpegQuality)
        }
    }

    /// Stream screenshots via XCTest daemon proxy (reuses existing XPC connection).
    /// Uses callback-based pipeline: capture overlaps with send for maximum throughput.
    private func startXCTestStream(client: ClientConnection, quality: CGFloat) {
        logger.log("Using XCTest screenshot path", phase: "REMOTE", level: .info)

        // All state accessed only from screenshotQueue (serial)
        var frameCount = 0
        var fpsTimer = CACurrentMediaTime()
        var consecutiveErrors = 0
        var captureInFlight = false
        var sendInFlight = false

        // Recursive capture function — each capture triggers the next
        func captureNext() {
            self.screenshotQueue.async { [weak self, weak client] in
                guard let self, let client, client.streaming else {
                    DispatchQueue.main.async { self?.logger.log("XCTest stream stopped", phase: "REMOTE", level: .info) }
                    return
                }
                guard !captureInFlight else { return }
                captureInFlight = true

                TouchSynthesizer.takeScreenshot(withQuality: quality) { [weak self, weak client] data, error in
                    self?.screenshotQueue.async {
                        captureInFlight = false
                        guard let self, let client, client.streaming else { return }

                        guard let jpegData = data as Data? else {
                            consecutiveErrors += 1
                            if consecutiveErrors >= 5 {
                                DispatchQueue.main.async {
                                    self.logger.log("XCTest screenshot failed 5x (\(error ?? "unknown")), falling back to CDTunnel", phase: "REMOTE", level: .warning)
                                }
                                if let tunnel = self.tunnel {
                                    self.startCDTunnelStream(client: client, tunnel: tunnel, quality: quality)
                                }
                                return
                            }
                            captureNext()
                            return
                        }
                        consecutiveErrors = 0

                        // If we got PNG, convert to JPEG
                        var finalData = jpegData
                        if jpegData.count > 2, jpegData[0] == 0x89, jpegData[1] == 0x50 {
                            if let img = UIImage(data: jpegData),
                               let converted = img.jpegData(compressionQuality: quality) {
                                finalData = converted
                            }
                        }

                        // Backpressure: drop this frame if previous send still in flight
                        if sendInFlight {
                            captureNext()
                            return
                        }

                        // Send frame
                        let frame = FrameCodec.encodeBinary(finalData)
                        sendInFlight = true
                        client.nwConn.send(content: frame, completion: .contentProcessed { [weak self] _ in
                            self?.screenshotQueue.async {
                                sendInFlight = false
                                captureNext()  // Kick capture if it was waiting on backpressure
                            }
                        })

                        // FPS logging every 3 seconds
                        frameCount += 1
                        let now = CACurrentMediaTime()
                        if now - fpsTimer >= 3.0 {
                            let fps = Double(frameCount) / (now - fpsTimer)
                            let kb = finalData.count / 1024
                            DispatchQueue.main.async { [weak self] in
                                self?.logger.log(
                                    String(format: "XCTest Stream: %.1f FPS, %dKB/frame", fps, kb),
                                    phase: "REMOTE", level: .debug
                                )
                            }
                            frameCount = 0
                            fpsTimer = now
                        }

                        // Start next capture immediately — overlaps with network send
                        captureNext()
                    }
                }
            }
        }

        captureNext()
    }

    /// Stream screenshots via CDTunnel (fallback — creates a new tunnel per frame).
    private func startCDTunnelStream(client: ClientConnection, tunnel: IdeviceTunnel, quality: CGFloat) {
        logger.log("Using CDTunnel screenshot path (fallback)", phase: "REMOTE", level: .info)

        screenshotQueue.async { [weak self, weak client] in
            var frameCount = 0
            var fpsTimer = CACurrentMediaTime()
            var sendInFlight = false

            while let client, client.streaming {
                guard self != nil else { break }

                // Backpressure: wait instead of capturing screenshots to discard
                if sendInFlight {
                    Thread.sleep(forTimeInterval: 0.02)
                    continue
                }

                let captureStart = CACurrentMediaTime()

                var outError: NSString?
                guard let pngData = tunnel.takeScreenshotAndReturnError(&outError) as Data? else {
                    Thread.sleep(forTimeInterval: 0.05)
                    continue
                }

                guard let uiImage = UIImage(data: pngData),
                      let jpegData = uiImage.jpegData(compressionQuality: quality) else {
                    continue
                }

                let captureTime = CACurrentMediaTime() - captureStart

                let frame = FrameCodec.encodeBinary(jpegData)
                sendInFlight = true
                client.nwConn.send(content: frame, completion: .contentProcessed { _ in
                    sendInFlight = false
                })

                Thread.sleep(forTimeInterval: 0.01)

                frameCount += 1
                let now = CACurrentMediaTime()
                if now - fpsTimer >= 3.0 {
                    let fps = Double(frameCount) / (now - fpsTimer)
                    let jpegKB = jpegData.count / 1024
                    DispatchQueue.main.async { [weak self] in
                        self?.logger.log(
                            String(format: "CDTunnel Stream: %.1f FPS, capture=%.0fms, %dKB/frame",
                                   fps, captureTime * 1000, jpegKB),
                            phase: "REMOTE", level: .debug
                        )
                    }
                    frameCount = 0
                    fpsTimer = now
                }
            }

            DispatchQueue.main.async {
                self?.logger.log("CDTunnel stream stopped", phase: "REMOTE", level: .info)
            }
        }
    }

    // MARK: - Single Screenshot

    private func takeScreenshot(id: String) async -> CommandResponse {
        guard let tunnel = tunnel else {
            return CommandResponse(id: id, success: false, error: "No tunnel connected")
        }
        guard !screenshotInProgress else {
            return CommandResponse(id: id, success: false, error: "Screenshot already in progress")
        }
        screenshotInProgress = true

        let result: (data: Data?, error: String?) = await withCheckedContinuation { continuation in
            screenshotQueue.async {
                var outError: NSString?
                let data = tunnel.takeScreenshotAndReturnError(&outError)
                continuation.resume(returning: (data as Data?, outError as String?))
            }
        }

        screenshotInProgress = false

        if let error = result.error {
            logger.log("Screenshot error: \(error)", phase: "REMOTE", level: .error)
            return CommandResponse(id: id, success: false, error: error)
        }
        guard let pngData = result.data else {
            return CommandResponse(id: id, success: false, error: "No image data")
        }
        let base64 = pngData.base64EncodedString()
        return CommandResponse(id: id, success: true, data: base64)
    }

    // MARK: - Helpers

    /// Fire-and-forget: runs the synthesis block in the background, logs errors but doesn't block the caller.
    private func fireAndForget(id: String, _ block: @escaping (@escaping (String?) -> Void) -> Void) {
        let logger = self.logger
        block { error in
            if let error {
                DispatchQueue.main.async {
                    logger.log("Synthesis error (\(id)): \(error)", phase: "REMOTE", level: .error)
                }
            }
        }
    }

    /// Build a complete gesture from accumulated touch stream and synthesize.
    private func synthesizeAccumulatedTouch(_ accumulator: TouchAccumulator, endPoint: CGPoint, id: String) {
        let points = accumulator.points
        let totalDuration = max(accumulator.duration, 0.05)
        let startTime = accumulator.startTime

        // Classify: if very few points and short distance, treat as tap or long press
        let totalDistance = points.count >= 2
            ? hypot(points.last!.point.x - points.first!.point.x,
                    points.last!.point.y - points.first!.point.y)
            : 0.0

        if points.count <= 3 && totalDistance < 10.0 && totalDuration < 0.3 {
            fireAndForget(id: id) { TouchSynthesizer.tap(at: accumulator.startPoint, completion: $0) }
            return
        }

        if points.count <= 3 && totalDistance < 10.0 && totalDuration >= 0.5 {
            fireAndForget(id: id) { TouchSynthesizer.longPress(at: accumulator.startPoint, duration: totalDuration, completion: $0) }
            return
        }

        // Multi-point gesture: build XCPointerEventPath with all points and timing
        let nsPoints = points.map { NSValue(cgPoint: $0.point) }
        let nsOffsets = points.map { NSNumber(value: $0.time - startTime) }
        let liftOffset = totalDuration + 0.05

        fireAndForget(id: id) { completion in
            TouchSynthesizer.synthesizeMultiPointGesture(
                withPoints: nsPoints,
                offsets: nsOffsets,
                end: endPoint,
                liftOffset: liftOffset,
                completion: completion
            )
        }
    }

    private func pointFrom(_ params: [String: AnyCodable]?, xKey: String, yKey: String) -> CGPoint {
        CGPoint(
            x: params?[xKey]?.doubleValue ?? 0,
            y: params?[yKey]?.doubleValue ?? 0
        )
    }

    private func pointFromDict(_ dict: [String: AnyCodable]?) -> CGPoint {
        CGPoint(
            x: dict?["x"]?.doubleValue ?? 0,
            y: dict?["y"]?.doubleValue ?? 0
        )
    }
}

// MARK: - Touch Accumulator

/// Accumulates streamed touch points for a single finger gesture.
private struct TouchAccumulator {
    let startPoint: CGPoint
    let startTime: CFAbsoluteTime
    var points: [(point: CGPoint, time: CFAbsoluteTime)]

    init(point: CGPoint) {
        self.startPoint = point
        self.startTime = CFAbsoluteTimeGetCurrent()
        self.points = [(point: point, time: self.startTime)]
    }

    mutating func addPoints(_ newPoints: [CGPoint]) {
        let now = CFAbsoluteTimeGetCurrent()
        let lastTime = points.last?.time ?? startTime
        let interval = (now - lastTime) / Double(max(newPoints.count, 1))
        for (i, pt) in newPoints.enumerated() {
            // Skip near-duplicates (finger stationary)
            if let last = points.last, abs(last.point.x - pt.x) < 0.5 && abs(last.point.y - pt.y) < 0.5 {
                continue
            }
            let t = lastTime + interval * Double(i + 1)
            points.append((point: pt, time: t))
        }
    }

    var duration: TimeInterval {
        let lastTime = points.last?.time ?? startTime
        return lastTime - startTime
    }
}

// MARK: - Client Connection

/// Manages a single NWConnection: reads length-prefixed frames, calls back with commands.
class ClientConnection {
    let nwConn: NWConnection
    let transport: String
    var buffer = Data()
    var onCommand: ((Command) -> Void)?
    var onDisconnect: (() -> Void)?
    var streaming = false

    init(nwConn: NWConnection, transport: String) {
        self.nwConn = nwConn
        self.transport = transport
    }

    func start() {
        nwConn.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.handleDisconnect() }
            if case .cancelled = state { self?.handleDisconnect() }
        }
        nwConn.start(queue: .main)
        readLoop()
    }

    func cancel() {
        stopStreaming()
        nwConn.cancel()
    }

    func stopStreaming() {
        streaming = false
    }

    func send(_ response: CommandResponse) {
        guard let frame = FrameCodec.encode(response) else { return }
        nwConn.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func readLoop() {
        nwConn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            if let data = content {
                self.buffer.append(data)
                self.processBuffer()
            }
            if isComplete || error != nil {
                self.handleDisconnect()
                return
            }
            self.readLoop()
        }
    }

    private func processBuffer() {
        while let (cmd, consumed) = FrameCodec.decode(buffer) {
            buffer = Data(buffer.dropFirst(consumed))
            onCommand?(cmd)
        }
    }

    private func handleDisconnect() {
        streaming = false
        DispatchQueue.main.async { [weak self] in
            self?.onDisconnect?()
        }
    }
}
