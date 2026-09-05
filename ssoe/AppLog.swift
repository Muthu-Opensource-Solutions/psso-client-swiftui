import Foundation
@_exported import os

/// Centralized Apple Unified Logging utility for Platform SSO.
/// Organizes logs by the application bundle identifier and categorized contexts for easy filtering in Console.app.
public enum AppLog {
    /// Subsystem identifier derived from the bundle identifier with fallback.
    public static let subsystem: String = Bundle.main.bundleIdentifier ?? "com.muthuopensource.psso-client-swiftui"

    /// General authorization request handler logs.
    public static let auth = Logger(subsystem: subsystem, category: "Authorization")

    /// Device registration flow, shared device keys, and token verification.
    public static let deviceRegistration = Logger(subsystem: subsystem, category: "DeviceRegistration")
    
    /// Key Rotation
    public static let keyWillRotate = Logger(subsystem: subsystem, category: "KeyRotation")


    /// Interactive user registration, OIDC redirect interception, and UserLoginConfiguration.
    public static let userRegistration = Logger(subsystem: subsystem, category: "UserRegistration")

    /// Platform SSO LoginConfiguration construction, claims, and persistence.
    public static let loginConfig = Logger(subsystem: subsystem, category: "LoginConfiguration")

    /// Key extraction, EC public key representation, JWK formatting, and JWS signing.
    public static let crypto = Logger(subsystem: subsystem, category: "Crypto")

    /// Outgoing HTTP requests, response status codes, and network communication errors.
    public static let network = Logger(subsystem: subsystem, category: "Network")

    /// Endpoint URL resolution and discovery URL lookups.
    public static let urls = Logger(subsystem: subsystem, category: "URLs")

    /// Host application lifecycle events.
    public static let app = Logger(subsystem: subsystem, category: "App")
}
