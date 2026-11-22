# Architectural Decision Records

## The menu is a SwiftUI MenuBarExtra with an observable store

The menu is `MenuBarExtra` in the `.menu` style, the way the menu of serve-markdown is built,
and `LSUIElement` keeps the app out of the Dock. The state is `AccountStore`, an `@Observable`
class owned by the `App` as `@State` and passed to the menu, the menu bar label and the code
windows, which redraw when the properties they read change.

The store's `now` is advanced by a one-second `Timer` started on a whole second and added to
the main run loop in the `.common` mode, so a view reading `now` is drawn again each second.
Apple's documentation does not say whether a `.menu` MenuBarExtra redraws while it is open; on
macOS 27.2 it does, and a menu redrawn each second is unsettled to use. The menu therefore
reads no clock and holds no codes: it lists the accounts as submenus, and the codes are shown
by the views that read `now`, the menu bar label and the code windows. The Launch at Login
tick is a property of the store, set after each change, since `SMAppService`'s status is not
observable and nothing else redraws the menu.

## The codes are shown in floating panels and beside the menu bar icon

A code window is an `NSPanel` with the utility window style, hosting a SwiftUI view. It is a
floating panel that does not hide when the app is inactive, and joins every Space, so it stays
over the window the code is typed into. It is non-activating, so clicking Copy leaves the other
app in front. There is at most one window per account, kept after it is closed and brought
forward by the next Show; removing the account closes it.

The `MenuBarExtra` label holds the icon and, for the one account chosen with Show in Menu Bar,
its code. Only that account's id is kept in the user defaults; the code windows are not
restored at launch.

## Each account is an item of the login keychain

TN3137 recommends the data protection keychain, but its access groups come from entitlements
that must be authorised by a provisioning profile, which an ad-hoc signed app does not have.
The app uses the file-based login keychain: `SecItem` calls without
`kSecUseDataProtectionKeychain`.

Each account is one generic password item. Its data is the secret alone, as the base32 text
it was given in, and no serialised structure holds a secret. The rest of the account is in the
item's attributes: the id as the account attribute, the name as the label, the issuer as the
comment, and the algorithm, digits and period as `algorithm=SHA1&digits=6&period=30` in the
generic attribute. Listing the items with their attributes alone, `kSecMatchLimitAll` with
`kSecReturnAttributes`, reads no secret and was found to ask for no access even from another
program; returning data cannot be combined with `kSecMatchLimitAll` for password items anyway.

Keychain items have no order, so the menu order is a list of ids in the user defaults; an item
missing from it follows by its creation date.

A secret is read when its code is needed and held in memory only while the code is shown, in
an open code window or beside the menu bar icon; Copy Code reads it for that one copy. The
price is that an ad-hoc rebuild brings one access question per account, when its code is first
needed, rather than one for all accounts at launch.

## The code is a library with its own tests

The TOTP code, the base32 decoding and the otpauth URI reading are the library `TOTP`, which
imports CryptoKit and Foundation alone, so its tests run without the app. `TOTPTests` uses
Swift Testing with parameterised tests: the RFC 6238 Appendix B vectors, codes printed by
`otp.py` of linux-cloud-router for one secret, as a second implementation to agree with, and
the secret and URI cases. `make` runs them before the bundle is assembled.

## The bundle is assembled by make and signed ad hoc

SwiftPM builds the executable but not an app bundle. The Makefile copies the executable and
`Resources/Info.plist` into `dist/Mac Authenticator.app`, writes `VERSION` into the copy with
`plutil`, and signs the bundle with `SIGN_IDENTITY`, ad hoc by default, which needs no Apple
Developer Program membership. The keychain item's access follows the signature, so a stable
identity spares the question macOS asks after an ad-hoc rebuild.

The app's name, Mac Authenticator, is `CFBundleDisplayName`. `CFBundleName` can hold up to 15
characters, so it is the shorter `Authenticator`; the About panel, which shows `CFBundleName`
by default, is given the full name as its `applicationName` option. The bundle identifier and
the keychain service are `pl.waw.koszewscy.MacAuthenticator`, and the executable and the Swift
target are `MacAuthenticator`.

## The app icon is an Icon Composer document compiled by actool

Apple's app icon guidelines for Liquid Glass ask for square layers, a background and up to
four groups, with no pre-masked shape, shadows or highlights: macOS masks the icon and adds
specular highlights, refraction, translucency and the dark, clear and tinted appearances. A
single bitmap `.icns` carries none of the layers these effects work on. The icon is therefore
`Resources/AppIcon.icon`, made in Icon Composer from the flat SVG layers in
`Resources/AppIconLayers`.

`actool` compiles a `.icon` document directly: `make` runs `xcrun actool` with `--app-icon
AppIcon` and `--compile` into the bundle's `Resources`, which writes `Assets.car` and an
`AppIcon.icns`, and merges the partial `Info.plist` it writes, `CFBundleIconName` and
`CFBundleIconFile`, into the bundle's `Info.plist` with `PlistBuddy`. `actool` ships with Xcode
alone, so the build needs Xcode as the active developer directory; the `.icon` and its layers
are the icon's only sources in the repository.

## QR codes are read with Vision

`DetectBarcodesRequest` of Vision, limited to QR codes, reads the image that `NSImage` makes
from the clipboard. The first payload starting with `otpauth://` fills the Add Account dialog
rather than being added at once, so the name can be changed and a duplicate or invalid code is
reported the way a typed one is.
