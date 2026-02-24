import Foundation

/// DTX connection over a TCP socket.
/// Handles message framing, fragment reassembly, channel multiplexing,
/// and request/response correlation.
class DTXConnection {
    let host: String
    let port: UInt16
    let useTLS: Bool
    let pairingRecord: PairingRecord?

    private var socketFD: Int32 = -1
    private var sslContext: SSLContext?

    private var channels: [Int32: DTXChannel] = [:]
    private var messageIDCounter: UInt32 = 0
    private var channelCodeCounter: Int32 = 0

    // Pending replies: message identifier → continuation
    private var pendingReplies: [UInt32: CheckedContinuation<DTXMessage, Error>] = [:]
    private let pendingLock = NSLock()

    // Fragment reassembly buffer
    private var fragmentBuffer: [UInt32: Data] = [:]

    private var readTask: Task<Void, Never>?
    private(set) var isConnected = false

    // Global message handler for unrouted messages
    var globalMessageHandler: ((DTXMessage) -> Void)?

    init(host: String, port: UInt16, useTLS: Bool = false, pairingRecord: PairingRecord? = nil) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.pairingRecord = pairingRecord
    }

    deinit {
        close()
    }

    // MARK: - Connection

    func connect() async throws {
        socketFD = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard socketFD >= 0 else {
            throw DTXError.sendFailed("socket() failed: \(errno)")
        }

        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            Darwin.close(socketFD); socketFD = -1
            throw DTXError.sendFailed("Invalid host: \(host)")
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(socketFD, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let err = errno; Darwin.close(socketFD); socketFD = -1
            throw DTXError.sendFailed("connect() failed: errno=\(err)")
        }

        if useTLS {
            try setupTLS()
        }

        isConnected = true
        startReadLoop()
    }

    func close() {
        readTask?.cancel()
        readTask = nil

        if let ctx = sslContext {
            SSLClose(ctx)
            sslContext = nil
        }
        if socketFD >= 0 {
            Darwin.close(socketFD)
            socketFD = -1
        }
        isConnected = false

        // Fail all pending replies
        pendingLock.lock()
        let pending = pendingReplies
        pendingReplies.removeAll()
        pendingLock.unlock()
        for (_, continuation) in pending {
            continuation.resume(throwing: DTXError.connectionClosed)
        }
    }

    // MARK: - Channel Management

    func nextMessageID() -> UInt32 {
        messageIDCounter += 1
        return messageIDCounter
    }

    /// Request a new DTX channel by identifier string
    func requestChannel(identifier: String) async throws -> DTXChannel {
        channelCodeCounter += 1
        let code = channelCodeCounter

        // Send channel request on the control channel (channel 0)
        let msg = DTXMessage.methodInvocation(
            selector: "_requestChannelWithCode:identifier:",
            arguments: [Int32(code) as Any, identifier as NSString],
            channel: 0,
            identifier: nextMessageID(),
            expectsReply: true
        )

        let reply = try await sendAndWaitForReply(msg)

        // Check for error
        if reply.payloadHeader.messageType == .error {
            throw DTXError.channelError("Channel request rejected for '\(identifier)': \(reply.payloadObject ?? "unknown")")
        }

        let channel = DTXChannel(code: code, identifier: identifier, connection: self)
        channels[code] = channel
        return channel
    }

    // MARK: - Send

    func send(_ message: DTXMessage) async throws {
        let data = try message.encode()
        try writeAll(data)
    }

    func sendAndWaitForReply(_ message: DTXMessage, timeout: TimeInterval = 30) async throws -> DTXMessage {
        let id = message.header.identifier

        return try await withCheckedThrowingContinuation { continuation in
            pendingLock.lock()
            pendingReplies[id] = continuation
            pendingLock.unlock()

            do {
                let data = try message.encode()
                try writeAll(data)
            } catch {
                pendingLock.lock()
                pendingReplies.removeValue(forKey: id)
                pendingLock.unlock()
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Read Loop

    private func startReadLoop() {
        readTask = Task.detached { [weak self] in
            while let self, self.isConnected, !Task.isCancelled {
                do {
                    let message = try self.readMessage()
                    self.dispatchMessage(message)
                } catch {
                    if self.isConnected {
                        print("[DTX] Read error: \(error)")
                        self.close()
                    }
                    break
                }
            }
        }
    }

    private func readMessage() throws -> DTXMessage {
        // Read 32-byte header
        let headerData = try readExactly(DTXMessageHeader.headerSize)
        let header = try DTXMessageHeader.decode(from: headerData)

        // Handle fragmented messages
        if header.fragmentCount > 1 {
            return try handleFragment(header: header)
        }

        // Read body (messageLength bytes after header)
        let bodyLen = Int(header.messageLength)
        let bodyData: Data
        if bodyLen > 0 {
            bodyData = try readExactly(bodyLen)
        } else {
            bodyData = Data()
        }

        return try DTXMessage.decode(headerData: headerData, bodyData: bodyData)
    }

    private func handleFragment(header: DTXMessageHeader) throws -> DTXMessage {
        let id = header.identifier

        if header.fragmentId == 0 {
            // First fragment — only contains total size info
            fragmentBuffer[id] = Data()
            // Read the body of this fragment (which may be empty or contain size info)
            if header.messageLength > 0 {
                let data = try readExactly(Int(header.messageLength))
                fragmentBuffer[id]?.append(data)
            }
            // Continue reading until we get all fragments
            return try readMessage()
        }

        // Subsequent fragment — append data
        let bodyLen = Int(header.messageLength)
        if bodyLen > 0 {
            let data = try readExactly(bodyLen)
            fragmentBuffer[id, default: Data()].append(data)
        }

        // Check if complete
        if header.fragmentId == header.fragmentCount - 1 {
            // All fragments received — reassemble
            let fullBody = fragmentBuffer.removeValue(forKey: id) ?? Data()
            // Create a synthetic unfragmented header
            var syntheticHeader = headerData(from: header)
            return try DTXMessage.decode(headerData: syntheticHeader, bodyData: fullBody)
        }

        // Not complete yet — read next message
        return try readMessage()
    }

    private func headerData(from header: DTXMessageHeader) -> Data {
        var h = header
        h.fragmentId = 0
        h.fragmentCount = 1
        return h.encode()
    }

    private func dispatchMessage(_ message: DTXMessage) {
        let id = message.header.identifier
        let convIdx = message.header.conversationIndex

        // Check if this is a reply to a pending request
        if convIdx > 0 {
            pendingLock.lock()
            if let continuation = pendingReplies.removeValue(forKey: id) {
                pendingLock.unlock()
                continuation.resume(returning: message)
                return
            }
            pendingLock.unlock()
        }

        // Route to channel handler
        // Note: testmanagerd sends callbacks with NEGATIVE channel codes (e.g. -1 for channel 1)
        // so we use abs() to match our positive channel keys, matching the idevice Rust library behavior
        let channelCode = abs(message.header.channelCode)
        if let channel = channels[channelCode] {
            channel.dispatchIncoming(message)
        } else if channelCode == 0 {
            // Control channel message
            globalMessageHandler?(message)
        } else {
            // Unknown channel
            globalMessageHandler?(message)
        }
    }

    // MARK: - TLS

    private func setupTLS() throws {
        guard let ctx = SSLCreateContext(kCFAllocatorDefault, .clientSide, .streamType) else {
            throw DTXError.sendFailed("SSLCreateContext failed")
        }
        sslContext = ctx

        SSLSetIOFuncs(ctx, dtxSSLRead, dtxSSLWrite)

        let fdPtr = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        fdPtr.pointee = socketFD
        SSLSetConnection(ctx, UnsafeMutableRawPointer(fdPtr))

        SSLSetSessionOption(ctx, .breakOnServerAuth, true)

        if let record = pairingRecord, let identity = try? record.getSecIdentity() {
            SSLSetCertificate(ctx, [identity] as CFArray)
        }

        var status: OSStatus
        repeat {
            status = SSLHandshake(ctx)
        } while status == errSSLWouldBlock || status == errSSLPeerAuthCompleted

        guard status == errSecSuccess else {
            throw DTXError.sendFailed("DTX TLS handshake failed: \(status)")
        }
    }

    // MARK: - Raw I/O

    private func writeAll(_ data: Data) throws {
        if let ctx = sslContext {
            var written = 0
            let status = data.withUnsafeBytes { ptr in
                SSLWrite(ctx, ptr.baseAddress!, data.count, &written)
            }
            guard status == errSecSuccess else {
                throw DTXError.sendFailed("SSLWrite failed: \(status)")
            }
        } else {
            let sent = data.withUnsafeBytes { ptr in
                Darwin.send(socketFD, ptr.baseAddress!, data.count, 0)
            }
            guard sent == data.count else {
                throw DTXError.sendFailed("send() wrote \(sent)/\(data.count)")
            }
        }
    }

    private func readExactly(_ count: Int) throws -> Data {
        var buffer = Data(count: count)
        var totalRead = 0

        while totalRead < count {
            let remaining = count - totalRead
            let bytesRead: Int

            if let ctx = sslContext {
                var processed = 0
                let status = buffer.withUnsafeMutableBytes { ptr in
                    SSLRead(ctx, ptr.baseAddress! + totalRead, remaining, &processed)
                }
                guard status == errSecSuccess || (status == errSSLWouldBlock && processed > 0) else {
                    throw DTXError.connectionClosed
                }
                bytesRead = processed
            } else {
                bytesRead = buffer.withUnsafeMutableBytes { ptr in
                    recv(socketFD, ptr.baseAddress! + totalRead, remaining, 0)
                }
                guard bytesRead > 0 else {
                    throw DTXError.connectionClosed
                }
            }

            totalRead += bytesRead
        }

        return buffer
    }
}

// MARK: - SSL Callbacks for DTX

private func dtxSSLRead(
    connection: SSLConnectionRef, data: UnsafeMutableRawPointer,
    dataLength: UnsafeMutablePointer<Int>
) -> OSStatus {
    let fd = connection.assumingMemoryBound(to: Int32.self).pointee
    let n = recv(fd, data, dataLength.pointee, 0)
    if n > 0 {
        dataLength.pointee = n
        return n < dataLength.pointee ? errSSLWouldBlock : errSecSuccess
    } else if n == 0 {
        dataLength.pointee = 0
        return errSSLClosedGraceful
    } else {
        dataLength.pointee = 0
        return errSSLClosedAbort
    }
}

private func dtxSSLWrite(
    connection: SSLConnectionRef, data: UnsafeRawPointer,
    dataLength: UnsafeMutablePointer<Int>
) -> OSStatus {
    let fd = connection.assumingMemoryBound(to: Int32.self).pointee
    let n = Darwin.send(fd, data, dataLength.pointee, 0)
    if n > 0 {
        dataLength.pointee = n
        return n < dataLength.pointee ? errSSLWouldBlock : errSecSuccess
    } else {
        dataLength.pointee = 0
        return errSSLClosedAbort
    }
}
