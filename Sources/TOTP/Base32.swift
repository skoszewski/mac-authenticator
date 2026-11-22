import Foundation

/// RFC 4648 base32, as TOTP secrets are written.
public enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)

    /// The secret in upper case without spaces and padding.
    public static func normalize(_ text: String) -> String {
        text.uppercased().filter { $0 != " " && $0 != "=" && $0 != "-" }
    }

    /// The bytes of a base32 text, case-insensitive, spaces, dashes and padding ignored; nil for
    /// another character or no bytes at all.
    public static func decode(_ text: String) -> Data? {
        var bytes = Data()
        var buffer: UInt32 = 0
        var bits = 0
        for character in normalize(text).utf8 {
            guard let value = alphabet.firstIndex(of: character) else {
                return nil
            }
            buffer = (buffer << 5) | UInt32(value)
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((buffer >> UInt32(bits)) & 0xFF))
            }
        }
        return bytes.isEmpty ? nil : bytes
    }
}
