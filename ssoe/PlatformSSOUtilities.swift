import Foundation
import Security
import CryptoKit
import IOKit
import AuthenticationServices
import WebKit
import AppKit
import os
import jose_swift

// Base64URL encoding (no padding)
func base64URLEncode(_ data: Data) -> String {
    let b64 = data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return b64
}

func base64URLDecode(_ s: String) -> Data? {
    var base64 = s
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let padding = (4 - base64.count % 4) % 4
    if padding > 0 {
        base64.append(String(repeating: "=", count: padding))
    }
    return Data(base64Encoded: base64)
}

// SHA256 digest
func sha256(_ data: Data) -> Data {
    let digest = SHA256.hash(data: data)
    return Data(digest)
}

// Obtain a public key from a SecKey (if the input is private), or return the key if already public
func publicKey(from key: SecKey?) -> SecKey? {
    guard let key = key else { return nil }
    if let pub = SecKeyCopyPublicKey(key) {
        return pub
    }
    return key
}

enum JWKError: Error {
    case invalidKey
    case invalidX963Length
    case exportFailed
}

/// Represents the Platform SSO authentication type used in custom login requests.
/// Backed by String raw values that are sent under the key "psso_type".
enum PlatformSSOType: String {
    case openID = "openID"
    case password = "urn:ietf:params:oauth:grant-type:token-exchange"
}

// Extract JWK x, y (base64url) and kid (base64url(sha256(x9.63))) from an EC P-256 public key
func extractJWKComponents(from publicKey: SecKey) throws -> (x: String, y: String, kid: String) {
    guard let x963Data = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
        AppLog.crypto.error("Failed to copy external representation of EC public key")
        throw JWKError.exportFailed
    }
    guard x963Data.count == 65, x963Data.first == 0x04 else {
        AppLog.crypto.error("Invalid X9.63 public key format or length: got \(x963Data.count) bytes, expected 65 bytes starting with 0x04")
        throw JWKError.invalidX963Length
    }
    let xy = x963Data.dropFirst()
    let xB64 = base64URLEncode(xy.prefix(32))
    let yB64 = base64URLEncode(xy.suffix(32))
    let kid = sha256(x963Data).base64EncodedString()
    return (x: xB64, y: yB64, kid: kid)
}

// Get Mac serial number via IOKit
func getMacSerialNumber() -> String? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
    guard service != 0 else {
        AppLog.deviceRegistration.error("Failed to find IOPlatformExpertDevice matching service in IOKit")
        return nil
    }
    defer { IOObjectRelease(service) }

    if let serial = IORegistryEntryCreateCFProperty(service, "IOPlatformSerialNumber" as CFString, kCFAllocatorDefault, 0)?.takeUnretainedValue() as? String {
        return serial
    }
    AppLog.deviceRegistration.error("Failed to read IOPlatformSerialNumber from IOPlatformExpertDevice")
    return nil
}

func getLoginConfiguration(loginManager: ASAuthorizationProviderExtensionLoginManager) -> ASAuthorizationProviderExtensionLoginConfiguration? {
    let serial = getMacSerialNumber() ?? ""
    
    guard let domainFQDN = loginManager.extensionData["DOMAIN_FQDN"] as? String else {
        AppLog.loginConfig.error("Missing DOMAIN_FQDN in extensionData when constructing LoginConfiguration")
        return nil
    }
    
    AppLog.loginConfig.debug("Constructing LoginConfiguration for serial: \(serial, privacy: .public), domain: \(domainFQDN, privacy: .public)")
    let platformSSOURLs = PlatformSSOURLs(domainName: domainFQDN)

    let config = ASAuthorizationProviderExtensionLoginConfiguration(clientID: serial,
                                                                    issuer: "psso-idp-proxy-server-java",
                                                                    tokenEndpointURL: platformSSOURLs.tokenURL,
                                                                    jwksEndpointURL: platformSSOURLs.jwksURL,
                                                                    audience: Optional(serial))
    
    //refering PSSO Authentication Type to be used below
    let pssoType : PlatformSSOType
    if #available(macOS 27.0, *), loginManager.authenticationMethod == .openID {
        pssoType = .openID
    } else{
        pssoType = .password
    }
    
    if let displayName = loginManager.extensionData["accountDisplayName"] as? String {
        config.accountDisplayName = displayName
    }
    
    //setting Endpoint URLs
    config.nonceEndpointURL = platformSSOURLs.nonceURL
    config.keyEndpointURL = Optional(platformSSOURLs.keyURL)
    
    //setting Custom values for Nonce Endpoint
    config.customNonceRequestValues = [URLQueryItem(name: "serialNumber", value: serial)]
    config.nonceResponseKeypath = "nonce"
    
    //setting Refresh Request URLs
    config.refreshEndpointURL = platformSSOURLs.refreshURL
    
    do {
        //setting Custom Body Claims for ( Key Requst, Key Exchange, Refresh )
        try config.setCustomKeyRequestBodyClaims(["client_id" : serial])
        try config.setCustomKeyExchangeRequestBodyClaims(["client_id" : serial])
        try config.setCustomRefreshRequestBodyClaims(["client_id":serial,"psso_type": pssoType.rawValue])
        AppLog.loginConfig.debug("Added custom request body claims to LoginConfiguration for Key Requst, Key Exchange, Refresh")
    } catch {
        AppLog.loginConfig.error("Error setting custom key claims on LoginConfiguration: \(error.localizedDescription, privacy: .public)")
    }
    
    return config
}

func getDeviceRegistrationCompactJWS(deviceSigningKey: SecKey?, deviceEncryptionKey: SecKey?, hmacKey: Data) throws -> String {
    guard deviceSigningKey != nil || deviceEncryptionKey != nil else {
        AppLog.crypto.error("Failed to construct JWS: Neither deviceSigningKey nor deviceEncryptionKey was provided")
        throw JWKError.invalidKey
    }
    
    var payload: [String: Any] = [
        "serialNumber": getMacSerialNumber() ?? ""
    ]
    
    if let signingKey = deviceSigningKey {
        guard let signingPublic = publicKey(from: signingKey) else {
            AppLog.crypto.error("Failed to extract public key from deviceSigningKey")
            throw JWKError.exportFailed
        }
        let signingJWK = try extractJWKComponents(from: signingPublic)
        payload["deviceSigningKey"] = [
            "kty": "EC",
            "crv": "P-256",
            "x": signingJWK.x,
            "y": signingJWK.y,
            "kid": signingJWK.kid
        ]
        AppLog.crypto.debug("Extracted JWK components for deviceSigningKey")
    }
    
    if let encryptionKey = deviceEncryptionKey {
        guard let encryptionPublic = publicKey(from: encryptionKey) else {
            AppLog.crypto.error("Failed to extract public key from deviceEncryptionKey")
            throw JWKError.exportFailed
        }
        let encryptionJWK = try extractJWKComponents(from: encryptionPublic)
        payload["deviceEncryptionKey"] = [
            "kty": "EC",
            "crv": "P-256",
            "x": encryptionJWK.x,
            "y": encryptionJWK.y,
            "kid": encryptionJWK.kid
        ]
        AppLog.crypto.debug("Extracted JWK components for deviceEncryptionKey")
    }

    // Serialize payload JSON
    let jwsPayload = try JSONSerialization.data(withJSONObject: payload, options: [])
    
    // Constructing a JWS signed with the HMAC key (HS256 HMAC)
    var jwsHeader = DefaultJWSHeaderImpl(algorithm: .HS256)
    jwsHeader.type = "jws"
    let hmacSymmetricKey = SymmetricKey(data: hmacKey)
    let jwsObject = try JWS(payload: jwsPayload, protectedHeader: jwsHeader, key: hmacSymmetricKey)
    return jwsObject.compactSerialization
}
