import Foundation
import Security

struct PairingRecord {
    let hostID: String
    let systemBUID: String
    let hostCertificate: Data
    let hostPrivateKey: Data
    let deviceCertificate: Data
    let rootCertificate: Data
    let escrowBag: Data?
    let wifiMACAddress: String?

    init(fromData data: Data) throws {
        guard let plist = try PropertyListSerialization.propertyList(
            from: data, format: nil) as? [String: Any] else {
            throw PairingError.invalidFormat
        }

        guard let hostID = plist["HostID"] as? String else {
            throw PairingError.missingField("HostID")
        }
        guard let systemBUID = plist["SystemBUID"] as? String else {
            throw PairingError.missingField("SystemBUID")
        }
        guard let hostCert = plist["HostCertificate"] as? Data else {
            throw PairingError.missingField("HostCertificate")
        }
        guard let hostKey = plist["HostPrivateKey"] as? Data else {
            throw PairingError.missingField("HostPrivateKey")
        }
        guard let deviceCert = plist["DeviceCertificate"] as? Data else {
            throw PairingError.missingField("DeviceCertificate")
        }
        guard let rootCert = plist["RootCertificate"] as? Data else {
            throw PairingError.missingField("RootCertificate")
        }

        self.hostID = hostID
        self.systemBUID = systemBUID
        self.hostCertificate = hostCert
        self.hostPrivateKey = hostKey
        self.deviceCertificate = deviceCert
        self.rootCertificate = rootCert
        self.escrowBag = plist["EscrowBag"] as? Data
        self.wifiMACAddress = plist["WiFiMACAddress"] as? String
    }

    init(fromFile url: URL) throws {
        let data = try Data(contentsOf: url)
        try self.init(fromData: data)
    }

    /// Diagnostic: log info about the key data for debugging import failures
    func debugKeyInfo() -> String {
        var keyData = stripPEMHeaders(hostPrivateKey)
        let certData = stripPEMHeaders(hostCertificate)

        var info = "Key data: \(keyData.count) bytes"
        info += ", first bytes: \(keyData.prefix(8).map { String(format: "%02x", $0) }.joined())"

        // Check if PEM or DER
        if let str = String(data: hostPrivateKey, encoding: .utf8) {
            if str.contains("-----BEGIN RSA PRIVATE KEY") {
                info += ", format: PKCS#1 PEM"
            } else if str.contains("-----BEGIN PRIVATE KEY") {
                info += ", format: PKCS#8 PEM"
            } else if str.contains("-----BEGIN") {
                let header = str.components(separatedBy: "\n").first ?? ""
                info += ", format: PEM (\(header))"
            } else {
                info += ", format: raw DER (no PEM header)"
            }
        } else {
            info += ", format: binary (not UTF-8)"
        }

        info += ". Cert data: \(certData.count) bytes"

        // Check PKCS#8 unwrap
        if Self.unwrapPKCS8(keyData) != nil {
            info += ", PKCS#8 unwrap: YES"
        }

        return info
    }

    /// Get SecIdentity for TLS client authentication
    func getSecIdentity() throws -> SecIdentity {
        var keyData = stripPEMHeaders(hostPrivateKey)
        let certData = stripPEMHeaders(hostCertificate)

        // Try to unwrap PKCS#8 to PKCS#1 if needed
        if let unwrapped = Self.unwrapPKCS8(keyData) {
            keyData = unwrapped
        }

        // Try importing the private key — auto-detect key size
        let privateKey = try importPrivateKey(keyData)

        guard let certificate = SecCertificateCreateWithData(nil, certData as CFData) else {
            throw PairingError.certImportFailed
        }

        // Add key to Keychain
        let tag = "com.computeruseproto.hostkey"
        // Delete old entries first
        SecItemDelete([
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag.data(using: .utf8)!,
        ] as CFDictionary)

        let addKeyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecValueRef as String: privateKey,
            kSecAttrApplicationTag as String: tag.data(using: .utf8)!,
            kSecAttrIsPermanent as String: true,
        ]
        let status = SecItemAdd(addKeyQuery as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw PairingError.keychainError(status)
        }

        // Add cert to Keychain
        let certLabel = "com.computeruseproto.hostcert"
        SecItemDelete([
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: certLabel,
        ] as CFDictionary)

        let addCertQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: certLabel,
        ]
        let certStatus = SecItemAdd(addCertQuery as CFDictionary, nil)
        guard certStatus == errSecSuccess || certStatus == errSecDuplicateItem else {
            throw PairingError.keychainError(certStatus)
        }

        // Retrieve identity (cert + matching key)
        let identityQuery: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecAttrLabel as String: certLabel,
        ]
        var identityRef: CFTypeRef?
        let idStatus = SecItemCopyMatching(identityQuery as CFDictionary, &identityRef)
        guard idStatus == errSecSuccess, let identity = identityRef else {
            throw PairingError.identityNotFound(idStatus)
        }

        return identity as! SecIdentity
    }

    /// Import a private key trying multiple formats and key sizes
    private func importPrivateKey(_ keyData: Data) throws -> SecKey {
        // Try without specifying key size first (let Security framework detect)
        let attrsNoSize: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        if let key = SecKeyCreateWithData(keyData as CFData, attrsNoSize as CFDictionary, &error) {
            return key
        }
        let firstError = error?.takeRetainedValue().localizedDescription ?? "unknown"

        // Try common key sizes explicitly
        for keySize in [2048, 4096, 1024, 3072] {
            error = nil
            let attrs: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                kSecAttrKeySizeInBits as String: keySize,
            ]
            if let key = SecKeyCreateWithData(keyData as CFData, attrs as CFDictionary, &error) {
                return key
            }
        }

        // Try as ECC key (newer pairing records might use ECC)
        error = nil
        let eccAttrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        if let key = SecKeyCreateWithData(keyData as CFData, eccAttrs as CFDictionary, &error) {
            return key
        }

        throw PairingError.keyImportFailed(
            "All import attempts failed. First error: \(firstError). "
            + "Key data size: \(keyData.count) bytes. "
            + "First 4 bytes: \(keyData.prefix(4).map { String(format: "%02x", $0) }.joined())"
        )
    }

    /// Unwrap a PKCS#8 PrivateKeyInfo wrapper to get the raw PKCS#1 RSA key.
    /// PKCS#8 wraps the key with an AlgorithmIdentifier; SecKeyCreateWithData
    /// on iOS expects raw PKCS#1 for RSA keys.
    static func unwrapPKCS8(_ data: Data) -> Data? {
        // PKCS#8 PrivateKeyInfo starts with SEQUENCE { version INTEGER, AlgorithmIdentifier, OCTET STRING { key } }
        // The RSA OID is 1.2.840.113549.1.1.1
        // Minimum: 30 8x ... 30 0d 06 09 2a 86 48 86 f7 0d 01 01 01 05 00 04 8x ...
        guard data.count > 26 else { return nil }

        // Check for SEQUENCE tag (0x30)
        guard data[data.startIndex] == 0x30 else { return nil }

        // Look for the RSA OID: 06 09 2a 86 48 86 f7 0d 01 01 01
        let rsaOID: [UInt8] = [0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01]

        // Search for the OID in the first 30 bytes
        let searchRange = data.startIndex..<min(data.startIndex + 30, data.endIndex)
        var oidStart: Data.Index?
        for i in searchRange {
            if data.startIndex.distance(to: i) + rsaOID.count <= data.count {
                let slice = data[i..<(i + rsaOID.count)]
                if slice.elementsEqual(rsaOID) {
                    oidStart = i
                    break
                }
            }
        }

        guard let oidIdx = oidStart else { return nil }

        // After OID comes NULL (05 00), then OCTET STRING (04) containing the PKCS#1 key
        var pos = oidIdx + rsaOID.count
        // Skip NULL parameter (05 00)
        if pos + 2 <= data.endIndex && data[pos] == 0x05 && data[pos + 1] == 0x00 {
            pos += 2
        }
        // Should be OCTET STRING (04)
        guard pos < data.endIndex && data[pos] == 0x04 else { return nil }
        pos += 1

        // Parse length
        guard pos < data.endIndex else { return nil }
        let lenByte = data[pos]
        pos += 1
        if lenByte & 0x80 != 0 {
            let numLenBytes = Int(lenByte & 0x7f)
            pos += numLenBytes // skip the length bytes
        }

        // The rest is the PKCS#1 RSA private key
        guard pos < data.endIndex else { return nil }
        return Data(data[pos...])
    }

    func getRootCertificate() -> SecCertificate? {
        let certData = stripPEMHeaders(rootCertificate)
        return SecCertificateCreateWithData(nil, certData as CFData)
    }

    func getDeviceCertificate() -> SecCertificate? {
        let certData = stripPEMHeaders(deviceCertificate)
        return SecCertificateCreateWithData(nil, certData as CFData)
    }

    /// Strip PEM headers (-----BEGIN ...-----) if present, returning raw DER bytes.
    /// Handles both \n and \r\n line endings.
    private func stripPEMHeaders(_ data: Data) -> Data {
        guard let str = String(data: data, encoding: .utf8) else { return data }

        // Check if it's PEM-encoded
        if str.contains("-----BEGIN") {
            // Normalize line endings and split
            let normalized = str.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            let lines = normalized.components(separatedBy: "\n")
            let base64Lines = lines.filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return !trimmed.isEmpty && !trimmed.hasPrefix("-----")
            }
            let base64 = base64Lines.joined()
            if let decoded = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) {
                return decoded
            }
            return data
        }

        return data
    }
}

enum PairingError: LocalizedError {
    case invalidFormat
    case missingField(String)
    case keyImportFailed(String)
    case certImportFailed
    case keychainError(OSStatus)
    case identityNotFound(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "Pairing file is not a valid plist"
        case .missingField(let field):
            return "Pairing file missing required field: \(field)"
        case .keyImportFailed(let reason):
            return "Failed to import private key: \(reason)"
        case .certImportFailed:
            return "Failed to import certificate"
        case .keychainError(let status):
            return "Keychain error: \(status)"
        case .identityNotFound(let status):
            return "Could not create identity from cert+key: \(status)"
        }
    }
}
