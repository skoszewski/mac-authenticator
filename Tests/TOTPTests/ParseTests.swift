import Testing
import TOTP

/// The parsed account as name|issuer|secret|algorithm|digits|period, or the error message.
private func parsed(_ name: String, _ input: String) -> String {
    do {
        let new = try Account.parse(name: name, input: input)
        let account = new.account
        return "\(account.name)|\(account.issuer ?? "-")|\(new.secret)|\(account.algorithm.rawValue)|\(account.digits)|\(account.period)"
    } catch {
        return "error: \(error.localizedDescription)"
    }
}

/// Typed name, typed secret or URI, and the expected result of `parsed`.
private let cases: [(String, String, String)] = [
    ("Box", "jbsw y3dp ehpk 3pxp==", "Box|-|JBSWY3DPEHPK3PXP|SHA1|6|30"),
    ("", "JBSWY3DPEHPK3PXP", "error: Give the account a name."),
    ("Box", "JBSWY3DP1", "error: The secret is not base32 (the letters A to Z and the digits 2 to 7)."),
    ("", "otpauth://totp/Example:alice@google.com?secret=JBSWY3DPEHPK3PXP&issuer=Example",
     "Example: alice@google.com|Example|JBSWY3DPEHPK3PXP|SHA1|6|30"),
    ("", "otpauth://totp/Big%20Corporation%3A%20alice%40bigco.com?secret=JBSWY3DPEHPK3PXP",
     "Big Corporation: alice@bigco.com|Big Corporation|JBSWY3DPEHPK3PXP|SHA1|6|30"),
    ("", "otpauth://totp/Old:bob?secret=JBSWY3DPEHPK3PXP&issuer=New%20Name",
     "New Name: bob|New Name|JBSWY3DPEHPK3PXP|SHA1|6|30"),
    ("Router", "OTPAUTH://TOTP/lcr?secret=jbswy3dpehpk3pxp&algorithm=sha256&digits=8&period=60",
     "Router|-|JBSWY3DPEHPK3PXP|SHA256|8|60"),
    ("", "otpauth://totp/otp?secret=JBSWY3DPEHPK3PXP&algorithm=SHA512&digits=10&period=30",
     "otp|-|JBSWY3DPEHPK3PXP|SHA512|10|30"),
    ("", "otpauth://totp/x?issuer=y", "error: The otpauth URI holds no secret."),
    ("", "otpauth://hotp/x?secret=JBSWY3DPEHPK3PXP&counter=1",
     "error: Only time-based (totp) accounts are supported, not hotp."),
    ("", "otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&digits=11", "error: The number of digits must be 6 to 10, not 11."),
    ("", "otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&period=0",
     "error: The period must be a whole number of seconds, at least 1, not 0."),
    ("", "otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&algorithm=MD5",
     "error: The algorithm must be SHA1, SHA256 or SHA512, not MD5."),
]

@Test("Secrets and otpauth URIs", arguments: cases)
func parse(name: String, input: String, expected: String) {
    #expect(parsed(name, input) == expected)
}
