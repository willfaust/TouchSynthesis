import Foundation

// MARK: - DTX Message Header (32 bytes, little-endian)

struct DTXMessageHeader {
    static let magic: UInt32 = 0x1F3D5B79
    static let headerSize: Int = 32

    var fragmentId: UInt16 = 0
    var fragmentCount: UInt16 = 1
    var messageLength: UInt32 = 0
    var identifier: UInt32 = 0
    var conversationIndex: UInt32 = 0
    var channelCode: Int32 = 0
    var expectsReply: UInt32 = 0

    func encode() -> Data {
        var data = Data(capacity: Self.headerSize)
        data.appendLE(Self.magic)
        data.appendLE(UInt32(Self.headerSize))
        data.appendLE(fragmentId)
        data.appendLE(fragmentCount)
        data.appendLE(messageLength)
        data.appendLE(identifier)
        data.appendLE(conversationIndex)
        data.appendLE(UInt32(bitPattern: channelCode))
        data.appendLE(expectsReply)
        return data
    }

    static func decode(from data: Data) throws -> DTXMessageHeader {
        guard data.count >= headerSize else {
            throw DTXError.invalidHeader("Too short: \(data.count) bytes")
        }

        let magic: UInt32 = data.readLE(at: 0)
        guard magic == Self.magic else {
            throw DTXError.invalidHeader("Bad magic: 0x\(String(magic, radix: 16))")
        }

        return DTXMessageHeader(
            fragmentId: data.readLE(at: 8),
            fragmentCount: data.readLE(at: 10),
            messageLength: data.readLE(at: 12),
            identifier: data.readLE(at: 16),
            conversationIndex: data.readLE(at: 20),
            channelCode: Int32(bitPattern: data.readLE(at: 24) as UInt32),
            expectsReply: data.readLE(at: 28)
        )
    }
}

// MARK: - DTX Payload Header (16 bytes, little-endian)

struct DTXPayloadHeader {
    static let headerSize: Int = 16

    var flags: UInt32 = 0
    var auxiliaryLength: UInt32 = 0
    var totalPayloadLength: UInt64 = 0

    var messageType: DTXMessageType {
        DTXMessageType(rawValue: flags & 0xFF) ?? .cycled
    }

    func encode() -> Data {
        var data = Data(capacity: Self.headerSize)
        data.appendLE(flags)
        data.appendLE(auxiliaryLength)
        data.appendLE(totalPayloadLength)
        return data
    }

    static func decode(from data: Data) throws -> DTXPayloadHeader {
        guard data.count >= headerSize else {
            throw DTXError.invalidPayloadHeader("Too short: \(data.count) bytes")
        }
        return DTXPayloadHeader(
            flags: data.readLE(at: 0),
            auxiliaryLength: data.readLE(at: 4),
            totalPayloadLength: data.readLE(at: 8)
        )
    }
}

// MARK: - Message Types

enum DTXMessageType: UInt32 {
    case cycled = 0
    case unknown = 1
    case methodInvocation = 2
    case responseWithReturnValue = 3
    case error = 4
}

// MARK: - DTX Message

class DTXMessage {
    var header: DTXMessageHeader
    var payloadHeader: DTXPayloadHeader
    var payloadObject: Any?
    var auxiliaryObjects: [Any]
    var rawAuxiliary: Data?
    var rawPayload: Data?

    init(
        identifier: UInt32 = 0,
        channelCode: Int32 = 0,
        conversationIndex: UInt32 = 0,
        expectsReply: Bool = false,
        messageType: DTXMessageType = .methodInvocation,
        payloadObject: Any? = nil,
        auxiliaryObjects: [Any] = []
    ) {
        self.header = DTXMessageHeader(
            identifier: identifier,
            conversationIndex: conversationIndex,
            channelCode: channelCode,
            expectsReply: expectsReply ? 1 : 0
        )
        self.payloadHeader = DTXPayloadHeader(flags: messageType.rawValue)
        self.payloadObject = payloadObject
        self.auxiliaryObjects = auxiliaryObjects
    }

    /// Encode the full message to bytes
    func encode() throws -> Data {
        // Encode auxiliary
        let auxData: Data
        if !auxiliaryObjects.isEmpty {
            auxData = try DTXAuxiliary.encode(objects: auxiliaryObjects)
        } else {
            auxData = Data()
        }

        // Encode payload (NSKeyedArchiver)
        let payloadData: Data
        if let obj = payloadObject {
            payloadData = try NSKeyedArchiver.archivedData(
                withRootObject: obj, requiringSecureCoding: false)
        } else {
            payloadData = Data()
        }

        // Build payload header
        var ph = DTXPayloadHeader()
        ph.flags = payloadHeader.flags
        ph.auxiliaryLength = UInt32(auxData.count)
        ph.totalPayloadLength = UInt64(auxData.count + payloadData.count)
        let phData = ph.encode()

        // Build message header
        var mh = header
        mh.messageLength = UInt32(phData.count + auxData.count + payloadData.count)
        mh.fragmentId = 0
        mh.fragmentCount = 1
        let mhData = mh.encode()

        // Assemble
        var result = Data(capacity: mhData.count + phData.count + auxData.count + payloadData.count)
        result.append(mhData)
        result.append(phData)
        result.append(auxData)
        result.append(payloadData)

        return result
    }

    /// Decode a complete DTX message from raw bytes (header + payload)
    static func decode(headerData: Data, bodyData: Data) throws -> DTXMessage {
        let header = try DTXMessageHeader.decode(from: headerData)

        guard !bodyData.isEmpty else {
            // Ack/empty message
            let msg = DTXMessage(
                identifier: header.identifier,
                channelCode: header.channelCode,
                conversationIndex: header.conversationIndex,
                messageType: .cycled
            )
            msg.header = header
            return msg
        }

        let ph = try DTXPayloadHeader.decode(from: bodyData)

        let auxLen = Int(ph.auxiliaryLength)
        let totalLen = Int(ph.totalPayloadLength)
        let payloadLen = totalLen - auxLen

        let auxStart = DTXPayloadHeader.headerSize
        let payloadStart = auxStart + auxLen

        // Decode auxiliary objects
        var auxObjects: [Any] = []
        var rawAux: Data?
        if auxLen > 0 && bodyData.count >= auxStart + auxLen {
            let auxData = bodyData.subdata(in: auxStart..<auxStart + auxLen)
            rawAux = auxData
            do {
                auxObjects = try DTXAuxiliary.decode(from: auxData)
            } catch {
                // Keep raw data for debugging
            }
        }

        // Decode payload object
        var payloadObj: Any?
        var rawPayload: Data?
        if payloadLen > 0 && bodyData.count >= payloadStart + payloadLen {
            let pData = bodyData.subdata(in: payloadStart..<payloadStart + payloadLen)
            rawPayload = pData
            do {
                payloadObj = try NSKeyedUnarchiver.unarchivedObject(
                    ofClasses: [
                        NSString.self, NSNumber.self, NSDictionary.self,
                        NSArray.self, NSData.self, NSNull.self, NSUUID.self,
                        NSSet.self, NSDate.self, NSError.self,
                    ],
                    from: pData
                )
            } catch {
                // Some objects may fail secure coding — try insecure
                let unarchiver = try NSKeyedUnarchiver(forReadingFrom: pData)
                unarchiver.requiresSecureCoding = false
                payloadObj = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
                unarchiver.finishDecoding()
            }
        }

        let msg = DTXMessage(
            identifier: header.identifier,
            channelCode: header.channelCode,
            conversationIndex: header.conversationIndex,
            expectsReply: header.expectsReply != 0,
            messageType: ph.messageType,
            payloadObject: payloadObj,
            auxiliaryObjects: auxObjects
        )
        msg.header = header
        msg.payloadHeader = ph
        msg.rawAuxiliary = rawAux
        msg.rawPayload = rawPayload
        return msg
    }

    /// Create a method invocation message
    static func methodInvocation(
        selector: String,
        arguments: [Any] = [],
        channel: Int32 = 0,
        identifier: UInt32 = 0,
        expectsReply: Bool = true
    ) -> DTXMessage {
        DTXMessage(
            identifier: identifier,
            channelCode: channel,
            expectsReply: expectsReply,
            messageType: .methodInvocation,
            payloadObject: selector as NSString,
            auxiliaryObjects: arguments
        )
    }

    /// Create a reply message
    static func reply(
        to request: DTXMessage,
        returnValue: Any? = nil
    ) -> DTXMessage {
        DTXMessage(
            identifier: request.header.identifier,
            channelCode: request.header.channelCode,
            conversationIndex: 1,
            messageType: .responseWithReturnValue,
            payloadObject: returnValue
        )
    }
}

// MARK: - DTX Errors

enum DTXError: LocalizedError {
    case invalidHeader(String)
    case invalidPayloadHeader(String)
    case invalidAuxiliary(String)
    case connectionClosed
    case timeout
    case sendFailed(String)
    case channelError(String)
    case methodFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidHeader(let d): return "Invalid DTX header: \(d)"
        case .invalidPayloadHeader(let d): return "Invalid DTX payload header: \(d)"
        case .invalidAuxiliary(let d): return "Invalid DTX auxiliary: \(d)"
        case .connectionClosed: return "DTX connection closed"
        case .timeout: return "DTX operation timed out"
        case .sendFailed(let d): return "DTX send failed: \(d)"
        case .channelError(let d): return "DTX channel error: \(d)"
        case .methodFailed(let d): return "DTX method invocation failed: \(d)"
        }
    }
}

// MARK: - Data Helpers

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: MemoryLayout<T>.size))
    }

    func readLE<T: FixedWidthInteger>(at offset: Int) -> T {
        let size = MemoryLayout<T>.size
        guard count >= offset + size else { return 0 }
        return subdata(in: offset..<offset + size)
            .withUnsafeBytes { $0.load(as: T.self).littleEndian }
    }
}
