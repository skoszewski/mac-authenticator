# Builds, checks and assembles the Mac Authenticator menu bar app.
#
#   make            check the TOTP code and write dist/Mac Authenticator.app (target app)
#   make build      build the app's executable
#   make test       run the tests of the TOTP library
#   make clean      remove the build products and dist/
#
# SIGN_IDENTITY names the code signing identity, ad hoc (-) by default. The active developer
# directory must be Xcode's, whose actool compiles Resources/AppIcon.icon.

VERSION = 0.1.0
SIGN_IDENTITY = -
APP = dist/Mac Authenticator.app

.PHONY: app build test clean

app: test build
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$$(swift build -c release --show-bin-path)/MacAuthenticator" "$(APP)/Contents/MacOS/MacAuthenticator"
	xcrun actool Resources/AppIcon.icon --compile "$(APP)/Contents/Resources" --app-icon AppIcon \
		--platform macosx --minimum-deployment-target 27.0 \
		--output-partial-info-plist .build/AppIcon-partial.plist \
		--warnings --errors --output-format human-readable-text
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Merge .build/AppIcon-partial.plist" "$(APP)/Contents/Info.plist"
	plutil -replace CFBundleShortVersionString -string "$(VERSION)" "$(APP)/Contents/Info.plist"
	plutil -replace CFBundleVersion -string "$(VERSION)" "$(APP)/Contents/Info.plist"
	plutil -lint "$(APP)/Contents/Info.plist"
	codesign --force --sign "$(SIGN_IDENTITY)" "$(APP)"
	codesign --verify --strict --verbose=2 "$(APP)"

build:
	swift build -c release --product MacAuthenticator

test:
	swift test

clean:
	swift package clean
	rm -rf dist
