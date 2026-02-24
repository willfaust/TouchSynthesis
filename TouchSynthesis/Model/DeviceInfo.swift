import Foundation

struct DeviceInfo {
    let deviceName: String
    let productType: String
    let productVersion: String
    let buildVersion: String
    let uniqueDeviceID: String

    static func fetch(via lockdown: LockdownClient) throws -> DeviceInfo {
        let name = try lockdown.getValue(key: "DeviceName") as? String ?? "Unknown"
        let type = try lockdown.getValue(key: "ProductType") as? String ?? "Unknown"
        let version = try lockdown.getValue(key: "ProductVersion") as? String ?? "Unknown"
        let build = try lockdown.getValue(key: "BuildVersion") as? String ?? "Unknown"
        let udid = try lockdown.getValue(key: "UniqueDeviceID") as? String ?? "Unknown"

        return DeviceInfo(
            deviceName: name,
            productType: type,
            productVersion: version,
            buildVersion: build,
            uniqueDeviceID: udid
        )
    }
}
