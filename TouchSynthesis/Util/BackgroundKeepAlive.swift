import CoreLocation

/// Uses background location updates to prevent iOS from suspending the app.
/// Same technique as iSH's `cat /dev/location &`.
class BackgroundKeepAlive: NSObject, CLLocationManagerDelegate {
    static let shared = BackgroundKeepAlive()

    private let manager = CLLocationManager()
    private(set) var isActive = false

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
    }

    func start() {
        guard !isActive else { return }
        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestAlwaysAuthorization()
        } else if status == .authorizedAlways || status == .authorizedWhenInUse {
            manager.startUpdatingLocation()
            isActive = true
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
        isActive = false
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if status == .authorizedAlways || status == .authorizedWhenInUse {
            if !isActive {
                manager.startUpdatingLocation()
                isActive = true
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Intentionally empty — we just need the updates to keep alive
    }
}
