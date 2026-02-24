import Foundation

enum LockdownError: LocalizedError {
    case connectionFailed(String)
    case notConnected
    case sendFailed(String)
    case receiveFailed(String)
    case unexpectedResponse(String)
    case serviceError(String)
    case tlsFailed(String)
    case sessionNotStarted
    case vpnNotActive

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let reason):
            return "Connection to lockdownd failed: \(reason). Is LocalDevVPN running?"
        case .notConnected:
            return "Not connected to lockdownd"
        case .sendFailed(let reason):
            return "Failed to send to lockdownd: \(reason)"
        case .receiveFailed(let reason):
            return "Failed to receive from lockdownd: \(reason)"
        case .unexpectedResponse(let detail):
            return "Unexpected lockdownd response: \(detail)"
        case .serviceError(let error):
            return "Lockdownd service error: \(error)"
        case .tlsFailed(let reason):
            return "TLS handshake failed: \(reason)"
        case .sessionNotStarted:
            return "Must call startSession() before accessing services"
        case .vpnNotActive:
            return "VPN loopback not active. Start LocalDevVPN first."
        }
    }

    /// Short error string for compact log output
    var shortDescription: String {
        switch self {
        case .serviceError(let e): return e
        default: return errorDescription ?? "unknown"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .connectionFailed:
            return "1. Open LocalDevVPN\n2. Enable the VPN\n3. Try again"
        case .tlsFailed:
            return "Check that the pairing file matches this device"
        case .vpnNotActive:
            return "Open LocalDevVPN and enable the VPN tunnel"
        default:
            return nil
        }
    }
}
