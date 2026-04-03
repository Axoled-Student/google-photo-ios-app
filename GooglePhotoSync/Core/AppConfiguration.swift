import Foundation

struct AppConfiguration: Sendable {
    let clientID: String
    let redirectScheme: String
    let redirectURI: String
    let albumTitle: String

    static func load(bundle: Bundle = .main) -> AppConfiguration {
        let bundledClientConfiguration = BundledOAuthClientConfiguration.load(bundle: bundle)

        return AppConfiguration(
            clientID: bundle.infoDictionaryString(forKey: "GoogleOAuthClientID")
                ?? bundledClientConfiguration?.clientID
                ?? "",
            redirectScheme: bundle.infoDictionaryString(forKey: "GoogleOAuthRedirectScheme")
                ?? bundledClientConfiguration?.redirectScheme
                ?? "",
            redirectURI: bundle.infoDictionaryString(forKey: "GoogleOAuthRedirectURI")
                ?? bundledClientConfiguration?.redirectURI
                ?? "",
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

private struct BundledOAuthClientConfiguration: Sendable {
    let clientID: String
    let redirectScheme: String
    let redirectURI: String

    static func load(bundle: Bundle) -> BundledOAuthClientConfiguration? {
        guard
            let url = bundle.url(forResource: "GoogleOAuthClient", withExtension: "plist"),
            let data = try? Data(contentsOf: url),
            let rawValue = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dictionary = rawValue as? [String: Any],
            let clientID = dictionary["CLIENT_ID"] as? String,
            let redirectScheme = dictionary["REVERSED_CLIENT_ID"] as? String,
            !clientID.isEmpty,
            !redirectScheme.isEmpty
        else {
            return nil
        }

        return BundledOAuthClientConfiguration(
            clientID: clientID,
            redirectScheme: redirectScheme,
            redirectURI: "\(redirectScheme):/oauthredirect"
        )
    }
}

private extension String {
    var isPlaceholder: Bool {
        isEmpty || hasPrefix("REPLACE_WITH_")
    }
}
