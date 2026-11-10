import Foundation
import Security

/// A TLS server identity for deceive-localhost.molenzwiebel.xyz, plus the chain to present to clients.
struct ProxyIdentity {
    let identity: SecIdentity
    /// Leaf first, followed by intermediates.
    let chain: [SecCertificate]
    let notAfter: Date?
}

enum ProxyCertificateError: Error, CustomStringConvertible {
    case openssl(String)
    case noCertificate
    case noPrivateKey
    case malformedKey(String)
    case identityUnavailable

    var description: String {
        switch self {
        case .openssl(let output): return "openssl failed to read the certificate: \(output)"
        case .noCertificate: return "The certificate bundle did not contain a certificate."
        case .noPrivateKey: return "The certificate bundle did not contain a private key."
        case .malformedKey(let reason): return "The certificate's private key could not be read: \(reason)"
        case .identityUnavailable: return "macOS refused to create a TLS identity from the certificate."
        }
    }
}

/// Port of Utils.GetProxyCertificateAsync.
///
/// macOS cannot use the upstream PFX as-is: it is protected with an empty password and legacy RC2
/// encryption, and its EC private scalar is stored with its leading zero byte stripped. SecPKCS12Import
/// silently drops the identity in that case. So we decrypt the bundle with the system's LibreSSL,
/// rebuild the key ourselves and pair it with the certificate in memory, without touching the keychain.
enum ProxyCertificate {
    static let downloadURL = URL(string: "https://mln.cx/deceive/localhost.pfx")!

    /// Returns a certificate that is valid for at least 20 days, from cache or freshly downloaded.
    static func obtain() async -> ProxyIdentity? {
        let cached = Persistence.cachedCertificate().flatMap { try? load(pfx: $0) }
        if let cached, let notAfter = cached.notAfter, notAfter > Date().addingTimeInterval(20 * 86_400) {
            Log.write("Cached certificate is valid until \(notAfter), using cached certificate.")
            return cached
        }

        do {
            Log.write("Cached certificate is missing or expiring soon, downloading new certificate.")
            var request = URLRequest(url: downloadURL)
            request.setValue("Deceive/\(Utils.version)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let identity = try load(pfx: data)
            Persistence.setCachedCertificate(data)
            return identity
        } catch {
            Log.write("Failed to download certificate: \(error)")
            // Unlike upstream, keep going with a cached certificate as long as it has not expired yet.
            if let cached, let notAfter = cached.notAfter, notAfter > Date() {
                return cached
            }
            return nil
        }
    }

    static func load(pfx: Data) throws -> ProxyIdentity {
        let pem = try decryptPFX(pfx)
        let blocks = PEM.parse(pem)

        let certificates = blocks
            .filter { $0.label == "CERTIFICATE" }
            .compactMap { SecCertificateCreateWithData(nil, $0.der as CFData) }
        let leaf = certificates.first { SecCertificateCopySubjectSummary($0) as String? == ConfigProxy.localhostDomain }
            ?? certificates.first
        guard let leaf else { throw ProxyCertificateError.noCertificate }
        guard let keyBlock = blocks.first(where: { $0.label.hasSuffix("PRIVATE KEY") }) else {
            throw ProxyCertificateError.noPrivateKey
        }

        let key = try makePrivateKey(label: keyBlock.label, der: keyBlock.der, certificate: leaf)
        guard let identity = createIdentity(certificate: leaf, key: key) else {
            throw ProxyCertificateError.identityUnavailable
        }

        let chain = [leaf] + certificates.filter { $0 !== leaf }
        return ProxyIdentity(identity: identity, chain: chain, notAfter: notAfter(of: leaf))
    }

    /// Decrypts the PFX with the LibreSSL build that ships with every copy of macOS.
    private static func decryptPFX(_ pfx: Data) throws -> String {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("deceive-\(UUID().uuidString).pfx")
        try pfx.write(to: tempURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = ["pkcs12", "-in", tempURL.path, "-passin", "pass:", "-nodes"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ProxyCertificateError.openssl(String(decoding: errorOutput, as: UTF8.self))
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static let ecPublicKeyOID: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
    private static let rsaEncryptionOID: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]

    private static func makePrivateKey(label: String, der: Data, certificate: SecCertificate) throws -> SecKey {
        var label = label
        var keyDER = [UInt8](der)

        // Unwrap PKCS#8 into the algorithm-specific structure.
        if label == "PRIVATE KEY" {
            guard let info = try DER.parse(keyDER).first, info.children.count >= 3,
                  let oid = info.children[1].children.first?.content else {
                throw ProxyCertificateError.malformedKey("invalid PKCS#8 structure")
            }
            keyDER = info.children[2].content
            switch oid {
            case ecPublicKeyOID: label = "EC PRIVATE KEY"
            case rsaEncryptionOID: label = "RSA PRIVATE KEY"
            default: throw ProxyCertificateError.malformedKey("unsupported key algorithm")
            }
        }

        let attributes: [String: Any]
        let keyData: Data
        switch label {
        case "EC PRIVATE KEY":
            // ECPrivateKey ::= SEQUENCE { version INTEGER, privateKey OCTET STRING, ... }
            guard let sequence = try DER.parse(keyDER).first, sequence.children.count >= 2 else {
                throw ProxyCertificateError.malformedKey("invalid ECPrivateKey structure")
            }
            let scalar = sequence.children[1].content
            // Apple wants the X9.63 form 04 || X || Y || D, with D padded to the field size.
            guard let publicKey = SecCertificateCopyKey(certificate),
                  let publicData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
                  publicData.first == 0x04 else {
                throw ProxyCertificateError.malformedKey("certificate does not carry an EC public key")
            }
            let fieldSize = (publicData.count - 1) / 2
            guard scalar.count <= fieldSize + 1 else {
                throw ProxyCertificateError.malformedKey("private scalar is too long")
            }
            let paddedScalar = [UInt8](repeating: 0, count: max(0, fieldSize - scalar.count)) + scalar.suffix(fieldSize)
            keyData = publicData + Data(paddedScalar)
            attributes = [
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                kSecAttrKeySizeInBits as String: fieldSize * 8,
            ]
        case "RSA PRIVATE KEY":
            keyData = Data(keyDER)
            attributes = [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            ]
        default:
            throw ProxyCertificateError.malformedKey("unsupported key format \(label)")
        }

        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, &error) else {
            let reason = error.map { String(describing: $0.takeRetainedValue()) } ?? "unknown error"
            throw ProxyCertificateError.malformedKey(reason)
        }
        return key
    }

    /// SecIdentityCreate has shipped in Security.framework for well over a decade but is not in the
    /// public headers. It is the only way to pair a certificate with an in-memory key on macOS without
    /// adding both to a keychain.
    private static func createIdentity(certificate: SecCertificate, key: SecKey) -> SecIdentity? {
        typealias SecIdentityCreateFunction = @convention(c) (CFAllocator?, SecCertificate, SecKey) -> Unmanaged<SecIdentity>?
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW),
              let symbol = dlsym(handle, "SecIdentityCreate") else {
            return nil
        }
        let create = unsafeBitCast(symbol, to: SecIdentityCreateFunction.self)
        return create(kCFAllocatorDefault, certificate, key)?.takeRetainedValue()
    }

    private static func notAfter(of certificate: SecCertificate) -> Date? {
        let keys = [kSecOIDX509V1ValidityNotAfter] as CFArray
        guard let values = SecCertificateCopyValues(certificate, keys, nil) as? [String: Any],
              let entry = values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any],
              let seconds = entry[kSecPropertyKeyValue as String] as? NSNumber else {
            return nil
        }
        return Date(timeIntervalSinceReferenceDate: seconds.doubleValue)
    }
}

enum PEM {
    struct Block {
        let label: String
        let der: Data
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var label: String?
        var body = ""
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("-----BEGIN "), line.hasSuffix("-----") {
                label = String(line.dropFirst(11).dropLast(5))
                body = ""
            } else if line.hasPrefix("-----END "), let current = label {
                if let der = Data(base64Encoded: body) {
                    blocks.append(Block(label: current, der: der))
                }
                label = nil
            } else if label != nil {
                body += line
            }
        }
        return blocks
    }
}

/// Just enough of a DER reader to pull apart PKCS#8 and SEC1 private keys.
struct DER {
    struct ParseError: Error {}

    let tag: UInt8
    let content: [UInt8]

    var children: [DER] { (try? DER.parse(content)) ?? [] }

    static func parse(_ bytes: [UInt8]) throws -> [DER] {
        var nodes: [DER] = []
        var index = 0
        while index < bytes.count {
            guard index + 2 <= bytes.count else { throw ParseError() }
            let tag = bytes[index]
            var length = Int(bytes[index + 1])
            index += 2
            if length & 0x80 != 0 {
                let lengthBytes = length & 0x7F
                guard lengthBytes > 0, lengthBytes <= 4, index + lengthBytes <= bytes.count else { throw ParseError() }
                length = bytes[index..<index + lengthBytes].reduce(0) { $0 << 8 | Int($1) }
                index += lengthBytes
            }
            guard index + length <= bytes.count else { throw ParseError() }
            nodes.append(DER(tag: tag, content: Array(bytes[index..<index + length])))
            index += length
        }
        return nodes
    }
}
