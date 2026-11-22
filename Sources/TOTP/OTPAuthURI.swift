import Foundation

/// Why an account could not be made from what was typed.
public enum TOTPError: LocalizedError, Equatable {
    case badSecret
    case badDigits(String)
    case badPeriod(String)
    case badAlgorithm(String)
    case badURI
    case notTOTP(String)
    case missingSecret
    case missingName
    case badParameters(String)

    public var errorDescription: String? {
        switch self {
        case .badSecret:
            return "The secret is not base32 (the letters A to Z and the digits 2 to 7)."
        case let .badDigits(value):
            return "The number of digits must be 6 to 10, not \(value)."
        case let .badPeriod(value):
            return "The period must be a whole number of seconds, at least 1, not \(value)."
        case let .badAlgorithm(value):
            return "The algorithm must be SHA1, SHA256 or SHA512, not \(value)."
        case .badURI:
            return "The otpauth URI cannot be read."
        case let .notTOTP(type):
            return "Only time-based (totp) accounts are supported, not \(type)."
        case .missingSecret:
            return "The otpauth URI holds no secret."
        case .missingName:
            return "Give the account a name."
        case let .badParameters(value):
            return "The stored parameters \(value) cannot be read."
        }
    }
}

extension Account {
    /// An account from a typed name and a base32 secret or an otpauth://totp/ URI; an empty name
    /// is taken from the URI's issuer and account name.
    public static func parse(name typedName: String, input: String) throws -> NewAccount {
        let name = typedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.lowercased().hasPrefix("otpauth://") else {
            guard !name.isEmpty else {
                throw TOTPError.missingName
            }
            return try NewAccount(account: Account(name: name), secret: text)
        }

        guard let components = URLComponents(string: text) else {
            throw TOTPError.badURI
        }
        let type = (components.host ?? "").lowercased()
        guard type == "totp" else {
            throw TOTPError.notTOTP(type.isEmpty ? "an empty type" : type)
        }
        var parameters: [String: String] = [:]
        for item in components.queryItems ?? [] {
            parameters[item.name.lowercased()] = item.value ?? ""
        }

        // The label is the account name, optionally after the issuer and a colon.
        let label = String(components.path.drop { $0 == "/" })
        var labelIssuer: String?
        var accountName = label
        if let colon = label.firstIndex(of: ":") {
            labelIssuer = String(label[..<colon]).trimmingCharacters(in: .whitespaces)
            accountName = String(label[label.index(after: colon)...])
        }
        accountName = accountName.trimmingCharacters(in: .whitespaces)
        let issuer = [parameters["issuer"], labelIssuer]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }

        guard let secret = parameters["secret"], !secret.isEmpty else {
            throw TOTPError.missingSecret
        }

        // The typed name wins; else the issuer and the account name of the URI.
        var resolvedName = name
        if resolvedName.isEmpty {
            switch (issuer, accountName.isEmpty) {
            case let (issuer?, false):
                resolvedName = "\(issuer): \(accountName)"
            case let (issuer?, true):
                resolvedName = issuer
            case (nil, false):
                resolvedName = accountName
            case (nil, true):
                throw TOTPError.missingName
            }
        }
        let account = try Account(name: resolvedName, issuer: issuer, algorithm: parameters["algorithm"],
                                  digits: parameters["digits"], period: parameters["period"])
        return try NewAccount(account: account, secret: secret)
    }
}
