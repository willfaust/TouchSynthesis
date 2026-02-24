import Foundation
import Network

// WiFi Aware requires:
// 1. iOS 26+
// 2. WiFiAware framework (import WiFiAware)
// 3. com.apple.developer.wifi-aware entitlement (paid Apple Developer Program only)
// 4. WiFiAwareServices declared in Info.plist
//
// Since the entitlement isn't available on personal dev teams, WiFi Aware
// support is compile-time gated. TCP fallback handles all connectivity.
// When a paid dev program is available, remove the #if false guard below.

/// WiFi Aware (NAN) service publisher. iOS 26+ only.
/// Publishes a service over WiFi Aware and hands accepted NWConnections
/// to a callback for CommandServer to manage.
///
/// Currently stubbed — WiFi Aware requires a paid developer program entitlement.
/// The real implementation uses WAPublisherListener from the WiFiAware framework:
///
/// ```swift
/// import WiFiAware
/// let service = WAPublishableService.allServices["_touchsynth._tcp"]!
/// let listener = try NetworkListener(
///     for: .wifiAware(.connecting(to: service, from: .allPairedDevices, datapath: .realtime))
/// ) { ... }
/// ```
@available(iOS 26.0, *)
class WiFiAwareService {
    var onConnection: ((NWConnection) -> Void)?
    var onStateChange: ((String) -> Void)?

    func start() throws {
        // WiFi Aware entitlement not available on personal dev teams.
        // This will be implemented when the entitlement is provisioned.
        throw WiFiAwareError.entitlementUnavailable
    }

    func stop() {}

    var isRunning: Bool { false }

    enum WiFiAwareError: Error, LocalizedError {
        case entitlementUnavailable

        var errorDescription: String? {
            "WiFi Aware requires com.apple.developer.wifi-aware entitlement (paid Apple Developer Program)"
        }
    }
}
