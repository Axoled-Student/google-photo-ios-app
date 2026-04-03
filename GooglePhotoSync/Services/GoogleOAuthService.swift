import AppAuth
import Foundation
import UIKit

@MainActor
final class GoogleOAuthService: NSObject {
    private let configuration: AppConfiguration
    private let keychain = KeychainStore(service: "GooglePhotoSync")
    private let keychainAccount = "google-auth-state"
    private var authState: OIDAuthState? {
        didSet {
            persistAuthState()
            profile = Self.decodeProfile(from: authState)
        }
    }
    private var currentAuthorizationFlow: OIDExternalUserAgentSession?

    private(set) var profile: GoogleUserProfile?

    init(configuration: AppConfiguration) {
        self.configuration = configuration
        self.authState = Self.restoreAuthState(
            from: KeychainStore(service: "GooglePhotoSync"),
            account: "google-auth-state"
        )
        self.profile = Self.decodeProfile(from: authState)
        super.init()
    }

    var isSignedIn: Bool {
        authState != nil
    }

    func signIn() async throws -> GoogleUserProfile {
        guard configuration.isConfigured, let redirectURL = configuration.redirectURL else {
            throw GoogleAuthError.invalidConfiguration(configuration.configurationMessage)
        }

        let serviceConfiguration = OIDServiceConfiguration(
            authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!
        )

        let request = OIDAuthorizationRequest(
            configuration: serviceConfiguration,
            clientId: configuration.clientID,
            clientSecret: nil,
            scopes: [
                OIDScopeOpenID,
                OIDScopeProfile,
                OIDScopeEmail,
                "https://www.googleapis.com/auth/photoslibrary.appendonly",
                "https://www.googleapis.com/auth/photoslibrary.readonly.appcreateddata"
            ],
            redirectURL: redirectURL,
            responseType: OIDResponseTypeCode,
            additionalParameters: [
                "access_type": "offline",
                "prompt": "consent",
                "include_granted_scopes": "true"
            ]
        )

        let presenter = try topViewController()

        let state = try await withCheckedThrowingContinuation { continuation in
            currentAuthorizationFlow = OIDAuthState.authState(
                byPresenting: request,
                presenting: presenter
            ) { [weak self] authState, error in
                guard let self else {
                    continuation.resume(throwing: GoogleAuthError.cancelled)
                    return
                }

                self.currentAuthorizationFlow = nil

                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let authState else {
                    continuation.resume(throwing: GoogleAuthError.missingAuthState)
                    return
                }

                continuation.resume(returning: authState)
            }
        }

        authState = state
        return profile ?? GoogleUserProfile(email: nil, displayName: nil)
    }

    func signOut() {
        authState = nil
        profile = nil
        try? keychain.delete(account: keychainAccount)
    }

    func freshAccessToken() async throws -> String {
        guard let authState else {
            throw GoogleAuthError.missingAuthState
        }

        return try await withCheckedThrowingContinuation { continuation in
            authState.performAction { accessToken, _, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let accessToken, !accessToken.isEmpty else {
                    continuation.resume(throwing: GoogleAuthError.missingAccessToken)
                    return
                }

                continuation.resume(returning: accessToken)
            }
        }
    }

    private func persistAuthState() {
        guard let authState else {
            try? keychain.delete(account: keychainAccount)
            return
        }

        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: authState, requiringSecureCoding: true)
            try keychain.save(data, account: keychainAccount)
        } catch {
            assertionFailure("Failed to persist Google auth state: \(error)")
        }
    }

    private func topViewController() throws -> UIViewController {
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController

        guard let root else {
            throw GoogleAuthError.missingPresenter
        }

        return Self.topViewController(from: root)
    }

    private static func topViewController(from controller: UIViewController) -> UIViewController {
        if let presented = controller.presentedViewController {
            return topViewController(from: presented)
        }

        if let navigation = controller as? UINavigationController, let visible = navigation.visibleViewController {
            return topViewController(from: visible)
        }

        if let tabBar = controller as? UITabBarController, let selected = tabBar.selectedViewController {
            return topViewController(from: selected)
        }

        return controller
    }

    private static func restoreAuthState(from keychain: KeychainStore, account: String) -> OIDAuthState? {
        guard let data = try? keychain.load(account: account), let data else {
            return nil
        }

        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: data)
    }

    private static func decodeProfile(from authState: OIDAuthState?) -> GoogleUserProfile? {
        let idToken = authState?.lastTokenResponse?.idToken
            ?? authState?.lastAuthorizationResponse.additionalParameters?["id_token"]

        guard
            let idToken,
            let payload = idToken.split(separator: ".").dropFirst().first,
            let data = Data(base64URLEncoded: String(payload)),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        return GoogleUserProfile(
            email: json["email"] as? String,
            displayName: json["name"] as? String
        )
    }
}

enum GoogleAuthError: LocalizedError {
    case invalidConfiguration(String)
    case missingPresenter
    case missingAuthState
    case missingAccessToken
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return message
        case .missingPresenter:
            return "Unable to present the Google sign-in flow right now."
        case .missingAuthState:
            return "Google sign-in did not return an authorization state."
        case .missingAccessToken:
            return "Google sign-in succeeded, but no access token was available."
        case .cancelled:
            return "The Google sign-in flow was cancelled."
        }
    }
}

private extension Data {
    init?(base64URLEncoded string: String) {
        var value = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let padding = value.count % 4
        if padding > 0 {
            value += String(repeating: "=", count: 4 - padding)
        }

        self.init(base64Encoded: value)
    }
}
