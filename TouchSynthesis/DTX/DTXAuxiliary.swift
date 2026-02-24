import Foundation

/// DTXPrimitiveDictionary encoder/decoder.
///
/// Binary format matching the idevice/go-ios/pymobiledevice3 implementations.
///
/// Layout:
///   [16 bytes AuxHeader: buffer_size(496) | 0 | values_size | 0]
///   For each entry:
///     [4 bytes: 0x0A separator]
///     [4 bytes: type tag]
///     [type-specific data]
///
/// Type tags:
///   0x01 = UTF-8 string: [length U32] [string bytes]
///   0x02 = Byte array / NSKeyedArchiver object: [length U32] [data bytes]
///   0x03 = UInt32/Int32: [value U32] (NO length prefix)
///   0x06 = Int64: [value I64] (NO length prefix)
enum DTXAuxiliary {
    /// Entry separator value (0x0A) that prefixes each auxiliary entry
    static let entrySeparator: UInt32 = 0x0a

    // MARK: - Encode

    static func encode(objects: [Any]) throws -> Data {
        // Encode entries (values payload, without header)
        var entries = Data()

        for obj in objects {
            // Every entry starts with 0x0A separator
            entries.appendLE(entrySeparator)

            switch obj {
            case let n as Int32:
                entries.appendLE(UInt32(0x03))                  // type: u32
                entries.appendLE(UInt32(bitPattern: n))         // value directly

            case let n as UInt32:
                entries.appendLE(UInt32(0x03))                  // type: u32
                entries.appendLE(n)                             // value directly

            case let n as Int:
                entries.appendLE(UInt32(0x06))                  // type: i64
                entries.appendLE(Int64(n))                      // value directly

            case let n as Int64:
                entries.appendLE(UInt32(0x06))                  // type: i64
                entries.appendLE(n)                             // value directly

            case let n as UInt64:
                entries.appendLE(UInt32(0x06))                  // type: i64
                entries.appendLE(Int64(bitPattern: n))          // value directly

            default:
                // Anything else: NSKeyedArchiver encode → type 0x02 (byte array)
                let archived = try NSKeyedArchiver.archivedData(
                    withRootObject: obj, requiringSecureCoding: false)
                entries.appendLE(UInt32(0x02))                  // type: archived/array
                entries.appendLE(UInt32(archived.count))        // length prefix
                entries.append(archived)                        // data bytes
            }
        }

        // Build 16-byte AuxHeader: [buffer_size][unknown][aux_size][unknown2]
        var data = Data()
        data.appendLE(UInt32(496))                  // buffer_size (convention from go-ios)
        data.appendLE(UInt32(0))                    // unknown
        data.appendLE(UInt32(entries.count))         // actual size of values data
        data.appendLE(UInt32(0))                    // unknown2

        data.append(entries)
        return data
    }

    // MARK: - Decode

    static func decode(from data: Data) throws -> [Any] {
        guard data.count >= 16 else {
            throw DTXError.invalidAuxiliary("Too short: \(data.count) bytes")
        }

        // 16-byte AuxHeader: [buffer_size U32][unknown U32][aux_size U32][unknown2 U32]
        // buffer_size is typically 496 (0x1F0)
        var offset = 16 // skip 16-byte header
        var results: [Any] = []

        while offset + 4 <= data.count {
            let tag: UInt32 = data.readLE(at: offset)
            offset += 4

            switch tag {
            case 0x0a:
                // Separator — skip, next u32 will be the type tag
                continue

            case 0x01: // UTF-8 string: [length][bytes]
                guard offset + 4 <= data.count else { break }
                let length = Int(data.readLE(at: offset) as UInt32)
                offset += 4
                guard offset + length <= data.count else { break }
                let strData = data.subdata(in: offset..<offset + length)
                if let str = String(data: strData, encoding: .utf8) {
                    results.append(str)
                }
                offset += length

            case 0x02: // Byte array / archived object: [length][data]
                guard offset + 4 <= data.count else { break }
                let length = Int(data.readLE(at: offset) as UInt32)
                offset += 4
                guard offset + length <= data.count else { break }
                let payload = data.subdata(in: offset..<offset + length)
                offset += length
                do {
                    let unarchiver = try NSKeyedUnarchiver(forReadingFrom: payload)
                    unarchiver.requiresSecureCoding = false
                    if let obj = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) {
                        results.append(obj)
                    } else {
                        results.append(payload)
                    }
                    unarchiver.finishDecoding()
                } catch {
                    results.append(payload)
                }

            case 0x03: // UInt32: [value] (no length prefix)
                guard offset + 4 <= data.count else { break }
                let val: UInt32 = data.readLE(at: offset)
                results.append(Int32(bitPattern: val))
                offset += 4

            case 0x06: // Int64: [value] (no length prefix)
                guard offset + 8 <= data.count else { break }
                let val: Int64 = data.readLE(at: offset)
                results.append(val)
                offset += 8

            default:
                // Unknown type — can't determine size, stop parsing
                break
            }
        }

        return results
    }
}
