import Cocoa
import AuthenticationServices
import CryptoKit
import IOKit
import jose_swift
import WebKit
import SwiftUI
import os

class AuthenticationViewController: NSViewController {

    var authorizationRequest: ASAuthorizationProviderExtensionAuthorizationRequest?

    override func loadView() {
        self.view = NSView()
        self.view.autoresizingMask = [.width, .height]
        self.preferredContentSize = NSSize(width: 760, height: 560)
        self.title = "Sign In"
    }

    override var nibName: NSNib.Name? {
        return nil
    }
}

extension AuthenticationViewController : ASAuthorizationProviderExtensionRegistrationHandler {
    
    var supportedDeviceSigningAlgorithms: [ASAuthorizationProviderExtensionSigningAlgorithm] {
        return [.es256]
    }

    var supportedDeviceEncryptionAlgorithms: [ASAuthorizationProviderExtensionEncryptionAlgorithm] {
        return [.ecdhe_A256GCM]
    }
    
    func supportedGrantTypes() -> ASAuthorizationProviderExtensionSupportedGrantTypes {
        if #available(macOS 27.0, *) {
            return [.password,.tokenExchange]
        } else {
            return .password
        }
    }
    
    func protocolVersion() -> ASAuthorizationProviderExtensionPlatformSSOProtocolVersion {
        return .version2_0
    }
    
    func registrationDidComplete() {
        AppLog.app.info("Registration Completed")
    }
    
    func registrationDidCancel() {
        AppLog.app.error("Registration Cancelled")
    }
    
    func beginDeviceRegistration(loginManager: ASAuthorizationProviderExtensionLoginManager, options: ASAuthorizationProviderExtensionRequestOptions = [], completion: @escaping @Sendable (ASAuthorizationProviderExtensionRegistrationResult) -> Void) {
        AppLog.deviceRegistration.info("Starting device registration flow")
        
        // Retrieve shared device keys
        guard let signingSecKey = loginManager.key(for: .sharedDeviceSigning) else {
            AppLog.deviceRegistration.error("Device registration failed: Missing sharedDeviceSigning key")
            completion(.failed)
            return
        }
        guard let encryptionSecKey = loginManager.key(for: .sharedDeviceEncryption) else {
            AppLog.deviceRegistration.error("Device registration failed: Missing sharedDeviceEncryption key")
            completion(.failed)
            return
        }
        
        upsertRegistrationKeysToServer(
            signingSecKey: signingSecKey,
            encryptionSecKey: encryptionSecKey,
            loginManager: loginManager
        ) { success in
            if success {
                AppLog.deviceRegistration.info("Device registration completed successfully")
                completion(.success)
            } else {
                AppLog.deviceRegistration.error("Device registration flow failed")
                completion(.failed)
            }
            AppLog.deviceRegistration.info("Ended Device registration flow")
        }
    }
    
    func beginUserRegistration(loginManager: ASAuthorizationProviderExtensionLoginManager, userName: String?, method authenticationMethod: ASAuthorizationProviderExtensionAuthenticationMethod, options: ASAuthorizationProviderExtensionRequestOptions = [], completion: @escaping @Sendable (ASAuthorizationProviderExtensionRegistrationResult) -> Void) {
        AppLog.userRegistration.info("Starting user registration flow. userName: \(userName ?? "none"), method: \(authenticationMethod.rawValue)")
        
        
        // Save User Login Configuration only on macOS 27.0+ and when using OpenID
        if #available(macOS 27.0, *), loginManager.authenticationMethod == .openID {
            let loginUserName = userName ?? ""
            let userLoginConfiguration = ASAuthorizationProviderExtensionUserLoginConfiguration(loginUserName: loginUserName)
            do {
                try loginManager.saveUserLoginConfiguration(userLoginConfiguration)
                AppLog.userRegistration.info("Saved UserLoginConfiguration successfully for: \(loginUserName, privacy: .public)")
                completion(.success)
            } catch {
                AppLog.userRegistration.error("Error saving UserLoginConfiguration: \(error.localizedDescription, privacy: .public)")
                completion(.failed)
            }
            return
        }

        guard let domainFQDN = loginManager.extensionData["DOMAIN_FQDN"] as? String else {
            AppLog.userRegistration.error("User registration failed: Missing DOMAIN_FQDN in extensionData")
            completion(.failed)
            return
        }
        let discoveryURL = PlatformSSOURLs(domainName: domainFQDN).userRegistrationDiscoveryURL

        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                completion(.failed)
                return
            }

            let registrationView = UserRegistrationView(
                discoveryURL: discoveryURL,
                onResult: { result in
                    DispatchQueue.main.async {
                        self.clearRegistrationView()
                    }

                    switch result {
                    case .success(let encodedResult):
                        AppLog.userRegistration.info("OIDC callback received, extracting user identity")
                        guard let userIdentifier = self.extractUserIdentifier(from: encodedResult) else {
                            AppLog.userRegistration.error("Failed to extract user email/identity from OIDC callback token")
                            completion(.failed)
                            return
                        }

                        let config = ASAuthorizationProviderExtensionUserLoginConfiguration(loginUserName: userIdentifier)
                        do {
                            try loginManager.saveUserLoginConfiguration(config)
                            AppLog.userRegistration.info("Saved UserLoginConfiguration successfully for: \(userIdentifier, privacy: .public)")
                            completion(.success)
                        } catch {
                            AppLog.userRegistration.error("Error saving UserLoginConfiguration: \(error.localizedDescription, privacy: .public)")
                            completion(.failed)
                        }

                    case .failure(let error):
                        AppLog.userRegistration.error("User registration failed: \(error.localizedDescription, privacy: .public)")
                        completion(.failed)
                    }
                },
                onCancel: {
                    DispatchQueue.main.async {
                        self.clearRegistrationView()
                    }
                    AppLog.userRegistration.info("User registration cancelled by user action")
                    completion(.failed)
                }
            )

            // Mount the registration SwiftUI view inside self.view
            self.presentRegistrationView(rootView: registrationView)

            // Request Platform SSO (AppSSOAgent / Setup Assistant) to display the view controller
            loginManager.presentRegistrationViewController { error in
                if let error = error {
                    AppLog.userRegistration.error("Failed to present registration view controller: \(error.localizedDescription, privacy: .public)")
                    completion(.failed)
                } else {
                    AppLog.userRegistration.info("Platform SSO successfully presented registration view controller on screen")
                }
            }
        }
    }

    // MARK: - Registration View Presentation Helpers

    private func presentRegistrationView(rootView: some View) {
        clearRegistrationView()
        AppLog.userRegistration.info("Presenting user registration view in extension view controller")
        
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.autoresizingMask = [.width, .height]
        
        self.preferredContentSize = NSSize(width: 760, height: 560)
        self.view.addSubview(hostingView)
        
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: self.view.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: self.view.trailingAnchor)
        ])
    }

    private func clearRegistrationView() {
        AppLog.userRegistration.debug("Clearing user registration view controller subviews")
        self.view.subviews.forEach { $0.removeFromSuperview() }
    }

    private func extractUserIdentifier(from base64EncodedResult: String) -> String? {
        let cleanedResult = base64EncodedResult.removingPercentEncoding ?? base64EncodedResult
        guard let data = Data(base64Encoded: cleanedResult) ?? Data(base64Encoded: base64EncodedResult),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = (json["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else {
            return nil
        }
        return email
    }
    
    
    
    func keyWillRotate(for keyType: ASAuthorizationProviderExtensionKeyType, newKey: SecKey, loginManager: ASAuthorizationProviderExtensionLoginManager, completion: @escaping (Bool) -> Void) {
        AppLog.keyWillRotate.info("keyWillRotate called for keyType: \(keyType.rawValue, privacy: .public)")

        guard keyType == .sharedDeviceSigning || keyType == .sharedDeviceEncryption else {
            AppLog.keyWillRotate.error("keyWillRotate called for unsupported keyType: \(keyType.rawValue, privacy: .public)")
            completion(false)
            return
        }

        var signingKey: SecKey?
        var encryptionKey: SecKey?

        switch keyType {
        case .sharedDeviceSigning:
            signingKey = newKey
            encryptionKey = loginManager.key(for: .sharedDeviceEncryption)
        case .sharedDeviceEncryption:
            signingKey = loginManager.key(for: .sharedDeviceSigning)
            encryptionKey = newKey
        default:
            completion(false)
            return
        }

        guard let signingSecKey = signingKey, let encryptionSecKey = encryptionKey else {
            AppLog.keyWillRotate.error("keyWillRotate failed: Missing companion key for keyType: \(keyType.rawValue, privacy: .public)")
            completion(false)
            return
        }

        upsertRegistrationKeysToServer(
            signingSecKey: signingSecKey,
            encryptionSecKey: encryptionSecKey,
            loginManager: loginManager
        ) { success in
            if success {
                AppLog.keyWillRotate.info("KeyWillRotate completed successfully for keyType: \(keyType.rawValue, privacy: .public)")
            } else {
                AppLog.keyWillRotate.error("KeyWillRotate failed for keyType: \(keyType.rawValue, privacy: .public)")
            }
            completion(success)
        }
    }
    
    func upsertRegistrationKeysToServer(
        signingSecKey: SecKey?,
        encryptionSecKey: SecKey?,
        loginManager: ASAuthorizationProviderExtensionLoginManager,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        do {
            guard let deviceRegistrationSharedSecret = loginManager.registrationToken else {
                AppLog.network.error("UpsertRegistrationKeys: Missing registrationToken from loginManager")
                completion(false)
                return
            }
            
            let secretBytes: Data = Data(deviceRegistrationSharedSecret.utf8)
            let digest = SHA256.hash(data: secretBytes)
            let hmacKey = Data(digest) // 32-byte key derived from the shared secret
            
            let jwsCompact = try getDeviceRegistrationCompactJWS(
                deviceSigningKey: signingSecKey,
                deviceEncryptionKey: encryptionSecKey,
                hmacKey: hmacKey
            )
            AppLog.network.debug("Constructed compact JWS for device registration")

            guard let domainFQDN = loginManager.extensionData["DOMAIN_FQDN"] as? String else {
                AppLog.network.error("Device registration failed: Missing DOMAIN_FQDN in extensionData")
                completion(false)
                return
            }
            let platformSSOURLs = PlatformSSOURLs(domainName: domainFQDN)

            var request = URLRequest(url: platformSSOURLs.deviceRegistrationURL)
            request.httpMethod = "POST"
            request.setValue(jwsCompact, forHTTPHeaderField: "Authorization")
            
            AppLog.network.info("Sending registration POST to: \(platformSSOURLs.deviceRegistrationURL.absoluteString, privacy: .public)")
            URLSession.shared.dataTask(with: request) { data, response, error in
                var statusCode: Int = -1
                if let error = error {
                    AppLog.network.error("Device registration network error: \(error.localizedDescription, privacy: .public)")
                    completion(false)
                    return
                }
                
                if let httpResp = response as? HTTPURLResponse {
                    statusCode = httpResp.statusCode
                    AppLog.network.info("Device registration HTTP response status: \(statusCode)")
                }

                guard statusCode == 202 else {
                    AppLog.deviceRegistration.error("Device registration rejected: expected HTTP 202 Accepted, got \(statusCode)")
                    completion(false)
                    return
                }
                
                do {
                    if let loginConfiguration = getLoginConfiguration(loginManager: loginManager) {
                        try loginManager.saveLoginConfiguration(loginConfiguration)
                        AppLog.loginConfig.info("Saved LoginConfiguration successfully following key registration")
                    } else {
                        AppLog.loginConfig.error("getLoginConfiguration returned nil during key registration")
                        completion(false)
                        return
                    }
                } catch {
                    AppLog.loginConfig.error("Error saving LoginConfiguration: \(error.localizedDescription, privacy: .public)")
                    completion(false)
                    return
                }
                
                completion(true)
            }.resume()
            
        } catch {
            AppLog.crypto.error("Error constructing JWK/JWS for upsertRegistrationKeysToServer: \(error.localizedDescription, privacy: .public)")
            completion(false)
        }
    }

}
