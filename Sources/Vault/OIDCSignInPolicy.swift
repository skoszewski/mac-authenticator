import Foundation

/// What the identity provider sent to the redirect URI.
public struct OIDCCallback: Sendable, Equatable {
    public var state: String?
    public var code: String?
    /// The provider's `error_description`, or its `error`, when the login was refused.
    public var error: String?

    public init(state: String?, code: String?, error: String?) {
        self.state = state
        self.code = code
        self.error = error
    }

    /// The callback in the query of the redirect URI.
    public init(url: URL) {
        var values: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            values[item.name] = item.value ?? ""
        }
        self.init(state: values["state"], code: values["code"], error: values["error_description"] ?? values["error"])
    }
}

/// What the sign-in window does with a navigation.
public enum OIDCNavigation: Sendable, Equatable {
    /// The navigation is the redirect: the sign-in ends with the callback and the page is not loaded.
    case callback(OIDCCallback)
    case allow
    /// The navigation is refused, for the reason.
    case block(String)
}

/// Decides which navigations of the sign-in window may happen: the redirect URI ends the sign-in,
/// pages over HTTPS load, and everything else is refused.
public struct OIDCSignInPolicy: Sendable {
    public let redirect: URL

    public init(redirect: URL) {
        self.redirect = redirect
    }

    public func decide(_ url: URL?) -> OIDCNavigation {
        guard let url, let scheme = url.scheme?.lowercased() else {
            return .block("The page has no address.")
        }
        if scheme == redirect.scheme?.lowercased(), url.host?.lowercased() == redirect.host?.lowercased(),
           url.port == redirect.port, url.path == redirect.path {
            return .callback(OIDCCallback(url: url))
        }
        switch scheme {
        case "https":
            return .allow
        case "about" where url.absoluteString == "about:blank":
            return .allow
        case "http":
            return .block("The page \(url.host ?? "") is not served over HTTPS.")
        default:
            return .block("Pages of the kind \(scheme): are not opened.")
        }
    }
}
