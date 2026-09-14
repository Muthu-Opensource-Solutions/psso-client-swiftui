import Foundation
import os

public struct PlatformSSOURLs {
    public let domainFQDN: String
    
    public init(domainName: String) {
        self.domainFQDN = domainName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func resolveURL(path: String) -> URL {
        let baseURL = URL(string: "https://\(self.domainFQDN)")!
        let fullURL = baseURL.appendingPathComponent(path)
        AppLog.urls.info("Resolved Platform SSO URL for \(path, privacy: .public): \(fullURL.absoluteString, privacy: .public)")
        return fullURL
    }
    
    public var deviceRegistrationURL: URL {
        return resolveURL(path: "/psso/deviceRegistration")
    }
    
    public var tokenURL: URL {
        return resolveURL(path: "/psso/token")
    }
    
    public var jwksURL: URL {
        return resolveURL(path: "/psso/jwks")
    }
    
    public var nonceURL: URL {
        return resolveURL(path: "/psso/nonce")
    }
    
    public var keyURL: URL {
        return resolveURL(path: "/psso/key")
    }
    
    public var refreshURL: URL {
        return resolveURL(path: "/psso/refresh")
    }
    
    public var userRegistrationDiscoveryURL: URL {
        return resolveURL(path: "/oidc/authCode/discovery")
    }
    
    public var openIDDiscoveryURL : URL {
        return resolveURL(path: "/oidc/webAuth/discovery")
    }
}
