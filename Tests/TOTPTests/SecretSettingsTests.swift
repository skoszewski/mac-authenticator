import Testing
@testable import TOTP

@Suite struct SecretSettingsTests {
    @Test func theDefaultsAskEveryTimeAndHideAfterThirtySeconds() {
        let settings = SecretSettings()
        #expect(settings.requiresAuthentication)
        #expect(settings.authenticationSeconds == 0)
        #expect(settings.hideSeconds == 30)
    }

    @Test func theStoredTextRoundTrips() throws {
        let settings = SecretSettings(requiresAuthentication: false, authenticationSeconds: 90, hideSeconds: 0)
        #expect(settings.attribute == "authenticate=0&seconds=90&hide=0")
        #expect(try #require(SecretSettings(attribute: settings.attribute)) == settings)
    }

    @Test(arguments: [
        ("", SecretSettings()),
        ("authenticate=0", SecretSettings(requiresAuthentication: false)),
        ("authenticate=1", SecretSettings()),
        ("authenticate=1&seconds=60", SecretSettings(authenticationSeconds: 60)),
        ("authenticate=1&seconds=60&hide=5", SecretSettings(authenticationSeconds: 60, hideSeconds: 5)),
        ("hide=0", SecretSettings(hideSeconds: 0)),
    ])
    func theFormsOfEarlierBuildsAndMissingKeysTakeDefaults(attribute: String, expected: SecretSettings) throws {
        #expect(try #require(SecretSettings(attribute: attribute)) == expected)
    }

    @Test(arguments: ["garbage", "authenticate=2", "seconds=-1", "hide=-5", "seconds=ten", "authenticate=1&hide"])
    func aTextThatIsNotValidIsNil(attribute: String) {
        #expect(SecretSettings(attribute: attribute) == nil)
    }

    @Test func negativeNumbersAreRaisedToZero() {
        let settings = SecretSettings(authenticationSeconds: -3, hideSeconds: -1)
        #expect(settings.authenticationSeconds == 0)
        #expect(settings.hideSeconds == 0)
    }
}
