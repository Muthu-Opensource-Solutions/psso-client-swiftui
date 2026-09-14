import Cocoa
import AuthenticationServices
import CryptoKit
import IOKit
import jose_swift
import WebKit
import SwiftUI
import os

class AuthenticationViewController: NSViewController {
    // Strong reference to keep registration window alive during interactive flow
    private var registrationWindowController: NSWindowController?

    var authorizationRequest: ASAuthorizationProviderExtensionAuthorizationRequest?

    override func loadView() {
        super.loadView()
        // Do any additional setup after loading the view.
    }

    override var nibName: NSNib.Name? {
        return NSNib.Name("AuthenticationViewController")
    }
}

final class RegistrationWindowController: NSWindowController, NSWindowDelegate {
    var onCancel: (() -> Void)?

    init(rootView: some View, title: String = "Sign in", onCancel: (() -> Void)? = nil) {
        self.onCancel = onCancel
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        super.init(window: window)
        window.delegate = self
        self.contentViewController = hostingController
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func centerOnScreen() {
        guard let window = self.window else { return }
        let targetScreen = NSScreen.main ?? NSScreen.screens.first
        if let screen = targetScreen {
            let screenFrame = screen.visibleFrame
            let windowWidth: CGFloat = 900
            let windowHeight: CGFloat = 700
            let originX = screenFrame.origin.x + (screenFrame.width - windowWidth) / 2.0
            let originY = screenFrame.origin.y + (screenFrame.height - windowHeight) / 2.0
            window.setFrame(NSRect(x: originX, y: originY, width: windowWidth, height: windowHeight), display: true)
        } else {
            window.center()
        }
    }

    func windowWillClose(_ notification: Notification) {
        onCancel?()
        onCancel = nil
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
        let title = (loginManager.extensionData["accountDisplayName"] as? String) ?? "Sign in"

        let registrationView = UserRegistrationView(
            discoveryURL: discoveryURL,
            onResult: { [weak self] result in
                DispatchQueue.main.async {
                    self?.dismissRegistrationWindow()
                }

                switch result {
                case .success(let encodedResult):
                    AppLog.userRegistration.info("OIDC callback received, extracting user identity")
                    guard let userIdentifier = self?.extractUserIdentifier(from: encodedResult) else {
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
            }
        )

        DispatchQueue.main.async {
            self.presentRegistrationWindow(
                rootView: registrationView,
                title: title,
                onCancel: {
                    AppLog.userRegistration.notice("User registration cancelled: window closed by user")
                    completion(.failed)
                }
            )
        }
    }

    // MARK: - Registration Window Presentation Helpers

    private func presentRegistrationWindow(rootView: some View, title: String, onCancel: @escaping () -> Void) {
        dismissRegistrationWindow()
        AppLog.userRegistration.info("Presenting user registration window: '\(title, privacy: .public)'")
        let wc = RegistrationWindowController(rootView: rootView, title: title, onCancel: onCancel)
        self.registrationWindowController = wc
        wc.centerOnScreen()
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func dismissRegistrationWindow() {
        if let wc = self.registrationWindowController as? RegistrationWindowController {
            wc.onCancel = nil // Prevent firing cancellation when dismissing after success
        }
        AppLog.userRegistration.debug("Dismissing user registration window")
        self.registrationWindowController?.close()
        self.registrationWindowController = nil
    }

    private func extractUserIdentifier(from base64EncodedResult: String) -> String? {
        guard let data = Data(base64Encoded: base64EncodedResult),
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
