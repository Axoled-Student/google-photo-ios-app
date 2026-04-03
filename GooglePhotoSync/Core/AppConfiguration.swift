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
        """
        Add a Google OAuth client for iOS in `Config/Base.xcconfig`, then set \
        `GOOGLE_CLIENT_ID`, `GOOGLE_REDIRECT_SCHEME`, and `GOOGLE_REDIRECT_URI`.
        """
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
