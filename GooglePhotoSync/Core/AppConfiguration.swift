import Foundation

struct AppConfiguration: Sendable {
    let clientID: String
    let redirectScheme: String
    let redirectURI: String
    let albumTitle: String

    static func load(bundle: Bundle = .main) -> AppConfiguration {
        AppConfiguration(
            clientID: bundle.infoDictionaryString(forKey: "GoogleOAuthClientID") ?? "",
            redirectScheme: bundle.infoDictionaryString(forKey: "GoogleOAuthRedirectScheme") ?? "",
            redirectURI: bundle.infoDictionaryString(forKey: "GoogleOAuthRedirectURI") ?? "",
            albumTitle: bundle.infoDictionaryString(forKey: "GooglePhotosAlbumTitle") ?? "Camera Roll Backup"
        )
    }

    var isConfigured: Bool {
        !clientID.isPlaceholder &&
        !redirectScheme.isPlaceholder &&
        !redirectURI.isPlaceholder &&
        !clientID.isEmpty &&
        !redirectScheme.isEmpty &&
        !redirectURI.isEmpty
    }

    var configurationMessage: String {
        "This build is missing Google sign-in setup. Install the latest IPA or rebuild with your iOS OAuth client."
    }

    var redirectURL: URL? {
        URL(string: redirectURI)
    }
}

private extension Bundle {
    func infoDictionaryString(forKey key: String) -> String? {
        object(forInfoDictionaryKey: key) as? String
    }
}

private extension String {
    var isPlaceholder: Bool {
        isEmpty || hasPrefix("REPLACE_WITH_")
    }
}
