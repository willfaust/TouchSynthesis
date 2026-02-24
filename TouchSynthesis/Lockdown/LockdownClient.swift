import Foundation
import Network
import Security

/// Minimal lockdown protocol client using POSIX sockets.
/// Connects to lockdownd at 10.7.0.1:62078 (via VPN loopback),
/// implements plist-over-TCP framing, session management, and TLS upgrade.
class LockdownClient {
    let host: String
    let port: UInt16
    let pairingRecord: PairingRecord
    let label = "ComputerUseProto"

    private var socketFD: Int32 = -1
    private var sslContext: SSLContext?
    private var sessionID: String?
    private(set) var isConnected = false
    private(set) var isTLSActive = false

    init(host: String = "10.7.0.1", port: UInt16 = 62078, pairingRecord: PairingRecord) {
        self.host = host
        self.port = port
        self.pairingRecord = pairingRecord
    }

    deinit {
        disconnect()
    }

    // MARK: - Connection

    func connect() throws {
        // Create socket
        socketFD = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard socketFD >= 0 else {
            throw LockdownError.connectionFailed("socket() failed: \(errno)")
        }

        // Set timeout
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        // Resolve and connect
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            close(socketFD)
            socketFD = -1
            throw LockdownError.connectionFailed("Invalid host: \(host)")
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(socketFD, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard result == 0 else {
            let err = errno
            close(socketFD)
            socketFD = -1
            if err == ECONNREFUSED {
                throw LockdownError.vpnNotActive
            }
            throw LockdownError.connectionFailed("connect() failed: errno=\(err)")
        }

        isConnected = true
    }

    func disconnect() {
        if let ctx = sslContext {
            SSLClose(ctx)
            sslContext = nil
        }
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
        isConnected = false
        isTLSActive = false
        sessionID = nil
    }

    // MARK: - Lockdown Protocol

    func queryType() throws -> String {
        let request: [String: Any] = [
            "Label": label,
            "Request": "QueryType",
        ]
        try sendPlist(request)
        let response = try receivePlist()

        if let error = response["Error"] as? String {
            throw LockdownError.serviceError(error)
        }

        guard let type = response["Type"] as? String else {
            throw LockdownError.unexpectedResponse("No 'Type' in QueryType response")
        }
        return type
    }

    func startSession() throws -> String {
        let request: [String: Any] = [
            "Label": label,
            "Request": "StartSession",
            "HostID": pairingRecord.hostID,
            "SystemBUID": pairingRecord.systemBUID,
        ]
        try sendPlist(request)
        let response = try receivePlist()

        if let error = response["Error"] as? String {
            throw LockdownError.serviceError(error)
        }

        guard let sid = response["SessionID"] as? String else {
            throw LockdownError.unexpectedResponse("No SessionID in StartSession response")
        }

        sessionID = sid

        if let enableSSL = response["EnableSessionSSL"] as? Bool, enableSSL {
            try upgradeTLS()
        }

        return sid
    }

    func getValue(domain: String? = nil, key: String? = nil) throws -> Any? {
        guard sessionID != nil else { throw LockdownError.sessionNotStarted }

        var request: [String: Any] = [
            "Label": label,
            "Request": "GetValue",
        ]
        if let domain { request["Domain"] = domain }
        if let key { request["Key"] = key }

        try sendPlist(request)
        let response = try receivePlist()

        if let error = response["Error"] as? String {
            throw LockdownError.serviceError(error)
        }

        return response["Value"]
    }

    func startService(name: String) throws -> (port: UInt16, enableSSL: Bool) {
        guard sessionID != nil else { throw LockdownError.sessionNotStarted }

        let request: [String: Any] = [
            "Label": label,
            "Request": "StartService",
            "Service": name,
        ]
        try sendPlist(request)
        let response = try receivePlist()

        if let error = response["Error"] as? String {
            throw LockdownError.serviceError(error)
        }

        guard let port = response["Port"] as? Int else {
            throw LockdownError.unexpectedResponse("No Port in StartService response")
        }
        let enableSSL = response["EnableServiceSSL"] as? Bool ?? false

        return (UInt16(port), enableSSL)
    }

    // MARK: - Plist Framing

    func sendPlist(_ dict: [String: Any]) throws {
        guard isConnected else { throw LockdownError.notConnected }

        let data = try PropertyListSerialization.data(
            fromPropertyList: dict, format: .xml, options: 0)

        // 4-byte big-endian length prefix
        var length = UInt32(data.count).bigEndian
        var packet = Data(bytes: &length, count: 4)
        packet.append(data)

        try writeAll(packet)
    }

    func receivePlist() throws -> [String: Any] {
        guard isConnected else { throw LockdownError.notConnected }

        // Read 4-byte length
        let lengthData = try readExactly(4)
        let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

        guard length > 0, length < 1_000_000 else {
            throw LockdownError.receiveFailed("Invalid plist length: \(length)")
        }

        // Read plist body
        let plistData = try readExactly(Int(length))

        guard let plist = try PropertyListSerialization.propertyList(
            from: plistData, format: nil) as? [String: Any] else {
            throw LockdownError.receiveFailed("Response is not a dictionary plist")
        }

        return plist
    }

    // MARK: - TLS Upgrade

    private func upgradeTLS() throws {
        // Create SSL context for client connection
        guard let ctx = SSLCreateContext(kCFAllocatorDefault, .clientSide, .streamType) else {
            throw LockdownError.tlsFailed("SSLCreateContext failed")
        }
        sslContext = ctx

        // Set up I/O functions that read/write from our POSIX socket
        SSLSetIOFuncs(ctx, sslReadFunc, sslWriteFunc)

        // Pass the socket FD as the connection ref
        let fdPtr = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        fdPtr.pointee = socketFD
        SSLSetConnection(ctx, UnsafeMutableRawPointer(fdPtr))

        // Disable certificate chain validation (pairing certs are self-signed)
        SSLSetSessionOption(ctx, .breakOnServerAuth, true)

        // Set client certificate (identity from pairing file)
        do {
            let identity = try pairingRecord.getSecIdentity()

            // Create certificate array for SSLSetCertificate
            // First element is the identity, rest are certs in the chain
            let certArray = [identity] as CFArray
            let status = SSLSetCertificate(ctx, certArray)
            if status != errSecSuccess {
                throw LockdownError.tlsFailed("SSLSetCertificate failed: \(status)")
            }
        } catch let error as PairingError {
            throw LockdownError.tlsFailed("Identity setup failed: \(error.localizedDescription)")
        }

        // Perform TLS handshake
        var status: OSStatus
        repeat {
            status = SSLHandshake(ctx)
            if status == errSSLPeerAuthCompleted {
                // Server auth check — we trust the pairing cert, so continue
                // Optionally verify the server cert matches DeviceCertificate
                status = SSLHandshake(ctx)
            }
        } while status == errSSLWouldBlock

        if status == errSSLPeerAuthCompleted {
            // Server auth callback — we trust pairing certs, continue handshake
            let finalStatus = SSLHandshake(ctx)
            guard finalStatus == errSecSuccess else {
                throw LockdownError.tlsFailed("Final handshake after peer auth failed: \(finalStatus)")
            }
        } else if status != errSecSuccess {
            throw LockdownError.tlsFailed("SSLHandshake failed: \(status)")
        }

        isTLSActive = true
    }

    // MARK: - Raw I/O

    private func writeAll(_ data: Data) throws {
        if isTLSActive, let ctx = sslContext {
            // Write through SSL
            var written = 0
            let status = data.withUnsafeBytes { ptr in
                SSLWrite(ctx, ptr.baseAddress!, data.count, &written)
            }
            guard status == errSecSuccess else {
                throw LockdownError.sendFailed("SSLWrite failed: \(status)")
            }
        } else {
            // Write raw TCP
            let sent = data.withUnsafeBytes { ptr in
                send(socketFD, ptr.baseAddress!, data.count, 0)
            }
            guard sent == data.count else {
                throw LockdownError.sendFailed("send() wrote \(sent)/\(data.count) bytes, errno=\(errno)")
            }
        }
    }

    private func readExactly(_ count: Int) throws -> Data {
        var buffer = Data(count: count)
        var totalRead = 0

        while totalRead < count {
            let remaining = count - totalRead
            let bytesRead: Int

            if isTLSActive, let ctx = sslContext {
                var processed = 0
                let status = buffer.withUnsafeMutableBytes { ptr in
                    SSLRead(ctx, ptr.baseAddress! + totalRead, remaining, &processed)
                }
                guard status == errSecSuccess || (status == errSSLWouldBlock && processed > 0) else {
                    throw LockdownError.receiveFailed("SSLRead failed: \(status)")
                }
                bytesRead = processed
            } else {
                bytesRead = buffer.withUnsafeMutableBytes { ptr in
                    recv(socketFD, ptr.baseAddress! + totalRead, remaining, 0)
                }
                guard bytesRead > 0 else {
                    throw LockdownError.receiveFailed("recv() returned \(bytesRead), errno=\(errno)")
                }
            }

            totalRead += bytesRead
        }

        return buffer
    }
}

// MARK: - SSL I/O Callback Functions

/// SSL read callback — reads from the POSIX socket
private func sslReadFunc(
    connection: SSLConnectionRef,
    data: UnsafeMutableRawPointer,
    dataLength: UnsafeMutablePointer<Int>
) -> OSStatus {
    let fdPtr = connection.assumingMemoryBound(to: Int32.self)
    let fd = fdPtr.pointee
    let requested = dataLength.pointee

    let bytesRead = recv(fd, data, requested, 0)
    if bytesRead > 0 {
        dataLength.pointee = bytesRead
        return bytesRead < requested ? errSSLWouldBlock : errSecSuccess
    } else if bytesRead == 0 {
        dataLength.pointee = 0
        return errSSLClosedGraceful
    } else {
        dataLength.pointee = 0
        return errSSLClosedAbort
    }
}

/// SSL write callback — writes to the POSIX socket
private func sslWriteFunc(
    connection: SSLConnectionRef,
    data: UnsafeRawPointer,
    dataLength: UnsafeMutablePointer<Int>
) -> OSStatus {
    let fdPtr = connection.assumingMemoryBound(to: Int32.self)
    let fd = fdPtr.pointee
    let toWrite = dataLength.pointee

    let bytesWritten = send(fd, data, toWrite, 0)
    if bytesWritten > 0 {
        dataLength.pointee = bytesWritten
        return bytesWritten < toWrite ? errSSLWouldBlock : errSecSuccess
    } else {
        dataLength.pointee = 0
        return errSSLClosedAbort
    }
}
