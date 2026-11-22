import Foundation
import Testing
import TOTP

/// The base32 text of an ASCII seed, as the RFC 6238 seeds are given.
private func base32(_ ascii: String) -> String {
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    var text = ""
    var buffer: UInt32 = 0
    var bits = 0
    for byte in ascii.utf8 {
        buffer = (buffer << 8) | UInt32(byte)
        bits += 8
        while bits >= 5 {
            bits -= 5
            text.append(alphabet[Int((buffer >> UInt32(bits)) & 0x1F)])
        }
    }
    if bits > 0 {
        text.append(alphabet[Int((buffer << UInt32(5 - bits)) & 0x1F)])
    }
    return text
}

private let rfcSeeds: [Algorithm: String] = [
    .sha1: "12345678901234567890",
    .sha256: "12345678901234567890123456789012",
    .sha512: "1234567890123456789012345678901234567890123456789012345678901234",
]

/// The test vectors of RFC 6238 Appendix B: time, algorithm, 8-digit code.
private let rfcVectors: [(TimeInterval, Algorithm, String)] = [
    (59, .sha1, "94287082"), (59, .sha256, "46119246"), (59, .sha512, "90693936"),
    (1111111109, .sha1, "07081804"), (1111111109, .sha256, "68084774"), (1111111109, .sha512, "25091201"),
    (1111111111, .sha1, "14050471"), (1111111111, .sha256, "67062674"), (1111111111, .sha512, "99943326"),
    (1234567890, .sha1, "89005924"), (1234567890, .sha256, "91819424"), (1234567890, .sha512, "93441116"),
    (2000000000, .sha1, "69279037"), (2000000000, .sha256, "90698825"), (2000000000, .sha512, "38618901"),
    (20000000000, .sha1, "65353130"), (20000000000, .sha256, "77737706"), (20000000000, .sha512, "47863826"),
]

/// Codes printed by `otp.py code` of linux-cloud-router for one secret with a 45 s period:
/// time, algorithm, digits, code.
private let otpPySecret = "URA3F2HGC7E47VE5A7PTOJOJLJT7EYT6"
private let otpPyCodes: [(TimeInterval, Algorithm, Int, String)] = [
    (0, .sha1, 6, "807499"), (0, .sha1, 10, "0447807499"),
    (1700000000, .sha1, 6, "520751"), (1700000000, .sha1, 10, "0192520751"),
    (1999999999.5, .sha1, 6, "545436"), (1999999999.5, .sha1, 10, "2027545436"),
    (0, .sha256, 6, "467694"), (0, .sha256, 10, "0151467694"),
    (1700000000, .sha256, 6, "143759"), (1700000000, .sha256, 10, "1590143759"),
    (1999999999.5, .sha256, 6, "893692"), (1999999999.5, .sha256, 10, "1391893692"),
    (0, .sha512, 6, "038044"), (0, .sha512, 10, "2145038044"),
    (1700000000, .sha512, 6, "271912"), (1700000000, .sha512, 10, "1853271912"),
    (1999999999.5, .sha512, 6, "396365"), (1999999999.5, .sha512, 10, "1722396365"),
]

@Test("RFC 6238 Appendix B", arguments: rfcVectors)
func rfc6238(time: TimeInterval, algorithm: Algorithm, expected: String) throws {
    let account = try Account(name: "rfc", algorithm: algorithm, digits: 8)
    #expect(account.code(secret: base32(rfcSeeds[algorithm]!), at: Date(timeIntervalSince1970: time)) == expected)
}

@Test("Same codes as otp.py", arguments: otpPyCodes)
func otpPy(time: TimeInterval, algorithm: Algorithm, digits: Int, expected: String) throws {
    let account = try Account(name: "otp.py", algorithm: algorithm, digits: digits, period: 45)
    #expect(account.code(secret: otpPySecret, at: Date(timeIntervalSince1970: time)) == expected)
}

@Test func sixDigitsByDefault() throws {
    let account = try Account(name: "rfc")
    #expect(account.code(secret: base32(rfcSeeds[.sha1]!), at: Date(timeIntervalSince1970: 59)) == "287082")
}

@Test func parametersRoundTrip() throws {
    let account = try Account(name: "x", algorithm: .sha512, digits: 10, period: 45)
    #expect(account.parameters == "algorithm=SHA512&digits=10&period=45")
    let read = try Account(id: account.id, name: "x", issuer: nil, parameters: account.parameters)
    #expect(read == account)
}

@Test func badParameters() {
    #expect(throws: TOTPError.badParameters("digits")) {
        try Account(id: UUID(), name: "x", issuer: nil, parameters: "digits")
    }
    #expect(throws: TOTPError.badDigits("5")) {
        try Account(id: UUID(), name: "x", issuer: nil, parameters: "algorithm=SHA1&digits=5&period=30")
    }
}

@Test func secondsLeft() throws {
    let account = try Account(name: "rfc")
    #expect(account.secondsLeft(at: Date(timeIntervalSince1970: 59)) == 1)
    #expect(account.secondsLeft(at: Date(timeIntervalSince1970: 60)) == 30)
}

@Test func base32Decoding() {
    #expect(Base32.decode("jbsw y3dp-ehpk 3pxp==") == Data("Hello!".utf8) + Data([0xDE, 0xAD, 0xBE, 0xEF]))
    #expect(Base32.decode("JBSWY3DP1") == nil)
    #expect(Base32.decode("") == nil)
}
