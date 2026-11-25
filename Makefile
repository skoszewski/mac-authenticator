# Builds, checks and assembles the Mac Authenticator menu bar app.
#
#   make            build the app and write dist/Mac Authenticator.app (target app)
#   make build      build the app's executable
#   make tests      run the tests of the TOTP and Vault libraries
#   make clean      remove the build products and dist/
#
# The Vault tests start an in-memory "vault server -dev"; the vault binary must be on PATH, or
# named by VAULT_BINARY. VAULT_TEST_PORT changes the server's port, 18200 by default.
#
# The bundle's version is that of the newest entry of CHANGELOG.md, read by tools/version.py.
#
# SIGN_IDENTITY names the code signing identity, ad hoc (-) by default. It is set in the
# command line, or in the untracked Makefile.local. The active developer directory must be
# Xcode's, whose actool compiles Resources/AppIcon.icon.

PYTHON = python3
VERSION := $(shell $(PYTHON) tools/version.py)
ifeq ($(VERSION),)
$(error tools/version.py found no version in CHANGELOG.md)
endif
-include Makefile.local
SIGN_IDENTITY ?= -
APP = dist/Mac Authenticator.app
STAGE = .build/stage/Mac Authenticator.app

.PHONY: app build tests clean

app: build
	rm -rf "$(STAGE)"
	mkdir -p "$(STAGE)/Contents/MacOS" "$(STAGE)/Contents/Resources"
	cp "$$(swift build -c release --show-bin-path)/MacAuthenticator" "$(STAGE)/Contents/MacOS/MacAuthenticator"
	xcrun actool Resources/AppIcon.icon --compile "$(STAGE)/Contents/Resources" --app-icon AppIcon \
		--platform macosx --minimum-deployment-target 27.0 \
		--output-partial-info-plist .build/AppIcon-partial.plist \
		--warnings --errors --output-format human-readable-text
	cp Resources/Info.plist "$(STAGE)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Merge .build/AppIcon-partial.plist" "$(STAGE)/Contents/Info.plist"
	plutil -replace CFBundleShortVersionString -string "$(VERSION)" "$(STAGE)/Contents/Info.plist"
	plutil -replace CFBundleVersion -string "$(VERSION)" "$(STAGE)/Contents/Info.plist"
	plutil -lint "$(STAGE)/Contents/Info.plist"
	codesign --force --sign "$(SIGN_IDENTITY)" "$(STAGE)"
	codesign --verify --strict --verbose=2 "$(STAGE)"
	rm -rf "$(APP)"
	mkdir -p dist
	mv "$(STAGE)" "$(APP)"

build:
	swift build -c release --product MacAuthenticator

tests:
	swift test

clean:
	swift package clean
	rm -rf dist
