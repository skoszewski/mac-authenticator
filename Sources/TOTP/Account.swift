import CryptoKit
import Foundation

/// The HMAC hash of an account's codes.
public enum Algorithm: String, CaseIterable, Sendable {
    case sha1 = "SHA1"
    case sha256 = "SHA256"
    case sha512 = "SHA512"
}

/// A registered account: its name and, for an OTP account, the RFC 6238 parameters of its codes,
/// without its secret. A secret account holds a plain string and has no codes; its algorithm,
/// digits and period are the defaults, which nothing reads.
public struct Account: Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case otp
        case secret
    }

    public static let digitsRange = 6...10

    public var id: UUID
    public var kind = Kind.otp
    public var name: String
    public var issuer: String?
    public var algorithm: Algorithm
    public var digits: Int
    public var period: Int

    public init(id: UUID = UUID(), name: String, issuer: String? = nil,
                algorithm: Algorithm = .sha1, digits: Int = 6, period: Int = 30) throws {
        guard Account.digitsRange.contains(digits) else {
            throw TOTPError.badDigits(String(digits))
        }
        guard period >= 1 else {
            throw TOTPError.badPeriod(String(period))
        }
        self.id = id
        self.name = name
        self.issuer = issuer
        self.algorithm = algorithm
        self.digits = digits
        self.period = period
    }

    /// A secret account.
    public init(secretID id: UUID = UUID(), name: String) {
        self.id = id
        self.kind = .secret
        self.name = name
        self.issuer = nil
        self.algorithm = .sha1
        self.digits = 6
        self.period = 30
    }

    /// An account whose algorithm, digits and period are given as the text values of an otpauth
    /// URI or of `parameters`; a value left out takes its default.
    public init(id: UUID = UUID(), name: String, issuer: String?, algorithm: String?, digits: String?,
                period: String?) throws {
        var hash = Algorithm.sha1
        if let algorithm {
            guard let known = Algorithm(rawValue: algorithm.uppercased()) else {
                throw TOTPError.badAlgorithm(algorithm)
            }
            hash = known
        }
        var digitCount = 6
        if let digits {
            guard let number = Int(digits) else {
                throw TOTPError.badDigits(digits)
            }
            digitCount = number
        }
        var seconds = 30
        if let period {
            guard let number = Int(period) else {
                throw TOTPError.badPeriod(period)
            }
            seconds = number
        }
        try self.init(id: id, name: name, issuer: issuer, algorithm: hash, digits: digitCount, period: seconds)
    }

    /// The algorithm, digits and period as `algorithm=SHA1&digits=6&period=30`.
    public var parameters: String {
        "algorithm=\(algorithm.rawValue)&digits=\(digits)&period=\(period)"
    }

    /// An account whose algorithm, digits and period are read from the `parameters` form.
    public init(id: UUID, name: String, issuer: String?, parameters: String) throws {
        var values: [String: String] = [:]
        for pair in parameters.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else {
                throw TOTPError.badParameters(parameters)
            }
            values[String(parts[0])] = String(parts[1])
        }
        try self.init(id: id, name: name, issuer: issuer, algorithm: values["algorithm"],
                      digits: values["digits"], period: values["period"])
    }

    /// The RFC 6238 code of the base32 secret at the given time.
    public func code(secret: String, at date: Date) -> String {
        var counter = UInt64(floor(date.timeIntervalSince1970 / Double(period))).bigEndian
        let message = withUnsafeBytes(of: &counter) { Data($0) }
        let key = SymmetricKey(data: Base32.decode(secret) ?? Data())
        let digest: Data
        switch algorithm {
        case .sha1:
            digest = Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256:
            digest = Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512:
            digest = Data(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }

        // Dynamic truncation of RFC 4226, section 5.3.
        let offset = Int(digest[digest.count - 1] & 0x0F)
        let value = digest[offset ..< offset + 4].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } & 0x7FFF_FFFF
        var modulus: UInt64 = 1
        for _ in 0 ..< digits {
            modulus *= 10
        }
        let text = String(value % modulus)
        return String(repeating: "0", count: digits - text.count) + text
    }

    /// The whole seconds until the code of the given time changes.
    public func secondsLeft(at date: Date) -> Int {
        period - Int(floor(date.timeIntervalSince1970)) % period
    }
}

/// An account to be registered, with its secret.
public struct NewAccount: Sendable {
    public var account: Account
    /// The base32 secret, normalised by `Base32.normalize`.
    public var secret: String

    public init(account: Account, secret: String) throws {
        guard Base32.decode(secret) != nil else {
            throw TOTPError.badSecret
        }
        self.account = account
        self.secret = Base32.normalize(secret)
    }
}
