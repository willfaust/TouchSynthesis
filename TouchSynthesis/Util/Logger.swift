import Foundation
import SwiftUI

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: Level
    let phase: String
    let message: String

    enum Level: String {
        case info = "INFO"
        case success = "OK"
        case warning = "WARN"
        case error = "ERR"
        case debug = "DBG"

        var color: Color {
            switch self {
            case .info: return .primary
            case .success: return .green
            case .warning: return .orange
            case .error: return .red
            case .debug: return .gray
            }
        }
    }

    var formatted: String {
        let ts = Self.formatter.string(from: timestamp)
        return "[\(ts)] [\(level.rawValue)] [\(phase)] \(message)"
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

@MainActor
class ProtocolLogger: ObservableObject {
    @Published var entries: [LogEntry] = []

    func log(_ message: String, phase: String, level: LogEntry.Level = .info) {
        let entry = LogEntry(timestamp: Date(), level: level, phase: phase, message: message)
        entries.append(entry)
        print(entry.formatted)
    }

    func hexDump(_ data: Data, label: String, phase: String) {
        let hex = data.prefix(128).map { String(format: "%02x", $0) }.joined(separator: " ")
        let truncated = data.count > 128 ? " ... (\(data.count) bytes total)" : ""
        log("\(label): \(hex)\(truncated)", phase: phase, level: .debug)
    }

    func clear() {
        entries.removeAll()
    }

    var allText: String {
        entries.map { $0.formatted }.joined(separator: "\n")
    }
}
