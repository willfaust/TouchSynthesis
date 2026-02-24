import Foundation

// MARK: - Wire Format

/// Request from a remote client.
/// Framing: 4-byte big-endian UInt32 length prefix + UTF-8 JSON payload.
struct Command: Codable {
    let id: String
    let action: String
    let params: [String: AnyCodable]?
}

/// Response sent back to the client.
struct CommandResponse: Codable {
    let id: String
    let success: Bool
    var error: String?
    var data: String?  // base64 for screenshot
}

// MARK: - AnyCodable

/// Lightweight type-erased Codable wrapper for JSON values (Double, String, Bool, Array, Dict).
struct AnyCodable: Codable {
    let value: Any

    var doubleValue: Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return nil
    }

    var stringValue: String? { value as? String }
    var boolValue: Bool? { value as? Bool }
    var arrayValue: [AnyCodable]? { value as? [AnyCodable] }
    var dictValue: [String: AnyCodable]? { value as? [String: AnyCodable] }

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let d = try? container.decode(Double.self) { value = d }
        else if let b = try? container.decode(Bool.self) { value = b }
        else if let s = try? container.decode(String.self) { value = s }
        else if let a = try? container.decode([AnyCodable].self) { value = a }
        else if let d = try? container.decode([String: AnyCodable].self) { value = d }
        else { value = NSNull() }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let d = value as? Double { try container.encode(d) }
        else if let b = value as? Bool { try container.encode(b) }
        else if let s = value as? String { try container.encode(s) }
        else if let a = value as? [AnyCodable] { try container.encode(a) }
        else if let d = value as? [String: AnyCodable] { try container.encode(d) }
        else { try container.encodeNil() }
    }
}

// MARK: - Framing Helpers

enum FrameCodec {
    /// Encode a response into a length-prefixed frame.
    static func encode(_ response: CommandResponse) -> Data? {
        guard let json = try? JSONEncoder().encode(response) else { return nil }
        var length = UInt32(json.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(json)
        return frame
    }

    /// Encode raw binary data (e.g. JPEG screenshot) into a length-prefixed frame.
    /// Distinguished from JSON frames by payload starting with 0xFF (JPEG SOI marker).
    static func encodeBinary(_ data: Data) -> Data {
        var length = UInt32(data.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(data)
        return frame
    }

    /// Try to extract one frame from a buffer. Returns (command, bytesConsumed) or nil if incomplete.
    /// Note: buffer may be a Data slice with non-zero startIndex after removeFirst(),
    /// so all subscript access must be relative to buffer.startIndex.
    static func decode(_ buffer: Data) -> (Command, Int)? {
        guard buffer.count >= 4 else { return nil }
        let length: UInt32 = buffer.withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self)
        }.bigEndian
        guard length < 16_000_000 else { return nil }
        let total = 4 + Int(length)
        guard buffer.count >= total else { return nil }
        // Use dropFirst/prefix instead of absolute indices — Data may be a slice
        let json = Data(buffer.dropFirst(4).prefix(Int(length)))
        guard let cmd = try? JSONDecoder().decode(Command.self, from: json) else { return nil }
        return (cmd, total)
    }
}
