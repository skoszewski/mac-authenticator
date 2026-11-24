# Architectural Decision Records

## The menu is a SwiftUI MenuBarExtra with an observable store

The menu is `MenuBarExtra` in the `.menu` style, the way the menu of serve-markdown is built,
and `LSUIElement` keeps the app out of the Dock. The app also sets the accessory activation
policy at launch, since a run from Xcode has no bundle and so no `Info.plist`; without the
policy the dialogs do not take the keyboard. The state is `AccountStore`, an `@Observable`
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

## Settings is an owned window hosting SwiftUI, and the menu keeps what is used with the codes

The menu holds what is used while working with codes: the accounts with Copy Code, Show and
Show in Menu Bar, Settings, Launch at Login, About and Quit. Adding, generating, importing and
removing accounts, and the vaults with their sign-in, are in the Settings window, which keeps the
menu short.

The window is an `NSWindow` made on the first request and hosting a SwiftUI `TabView`, like
the code panels, and not a `Settings` scene. SwiftUI's `openSettings` and `SettingsLink` open
the scene from a view hierarchy of an active app, which a `MenuBarExtra` app lacks; reports of
it failing there, and needing a hidden window and switching the activation policy to work, made
the plain window the safer choice. It is activated with the same call as the alerts, so it takes
the keyboard. The add and remove confirmations and the dialogs that add, generate and import an
account of a vault stay alerts, opened from the window; the vault form, which was too
large for an alert, is a SwiftUI form with Save and Revert.

A vault is signed in and out from the window, since the menu has no sign-in item; an OIDC vault
needs it after each launch.

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
identity spares the question macOS asks after an ad-hoc rebuild. The identity of the developer's
machine is read from the untracked `Makefile.local`, so a checkout builds ad hoc by default and
no identity is committed; the command line overrides both.

The bundle is assembled and signed in `.build/stage` and moved into `dist` whole. Assembled in
place, it would exist for the seconds the icon compiler takes without its `Info.plist`, which
Launch Services and Finder register as it is, leaving the finished app with a no-entry sign.

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

## Vault keys are generated or imported only under a new name

`POST <mount>/keys/<key>` replaces the secret of a key that exists, which would silently break
every account and authenticator using it. The app reads the key first and refuses a name that
is taken. Generated keys answer with `barcode`, a base64 PNG QR code, and `url`, an otpauth
URI; both are shown once and never stored, since Vault does not return the secret again. An
import is limited to what Vault keeps, SHA1, SHA256 or SHA512 with 6 or 8 digits, and is
refused before the call, so no key is stored that the app could not show. A failure to add the
account after Vault holds the key is reported, and does not repeat the write.

## Vault codes are fetched, never computed

An account of the Vault TOTP engine has no secret in the app: the code comes from
`GET <mount>/code/<key>`, once for each period of each shown account, at the whole second the
period changes. The engine's answer holds the code alone, so the algorithm, digits, period and
issuer are read once, when the key is added, from `GET <mount>/keys/<key>`, and kept with the
account in the same `algorithm=...&digits=...&period=...` form as a keychain item. A code is
kept with the period count it was fetched for and is shown for that period alone, so a stale
code is never shown; a failed fetch is not repeated within its period.

## Each Vault profile is one keychain item, its accounts are in the user defaults

A Vault account holds nothing secret, only its profile and the name of its key, so it is a
record in the user defaults and has no keychain item. A profile is one generic password item of
a service of its own, `<service>.vault`, so that listing the accounts, which reads the attributes
of every item of the main service, never meets it. The item's label is the profile name, which
Keychain Access shows; its account attribute is the profile's UUID, so a rename changes the
label and nothing that refers to the profile. The settings are the item's generic attribute, as
the parameters of a TOTP account are, so listing the profiles reads no secret; the credential,
a token, password or SecretID, is its data, empty for OIDC.

Each profile has a session of its own, so accounts of several servers show codes together. A
profile's removal removes its accounts, whose keys stay in Vault, since they cannot show a code
without it.

## The OIDC token is kept in memory and the sign-in is explicit

The identity provider signs the user in, so the app stores no credential for OIDC, and it keeps
the resulting Vault token in memory alone: a sign-in is repeated after each launch and when the
token ends. The browser is opened from Sign In to Vault only, never because a code was needed,
so a window opening in the background cannot start a login nobody expects. The other methods
sign in by themselves, since they need no user.

The redirect is received by a listener on the loopback interface, as `vault login -method=oidc`
does it: the redirect URI is `http://localhost:<port>/oidc/callback`, 8250 by default, which the
role's `allowed_redirect_uris` must hold. The listener answers one request and stops. The state
of the authorisation URL is compared with the state of the redirect before the code is passed
to Vault.

## Vault is reached over HTTPS and tested against a dev server

Requests go through `URLSession`, so App Transport Security and the system trust store apply;
`NSAllowsLocalNetworking` allows plain HTTP to local addresses alone, for a dev server.

`VaultTests` start `vault server -dev`, which keeps its storage in memory, once for the whole
suite, through a suite trait that provides the test scope, and configure it through its HTTP
API with plain `URLSession` calls, apart from the client under test. The `vault` binary is a
requirement of the tests, and a missing one fails them. The namespace header is checked on the
request alone, since namespaces exist only in Vault Enterprise. The exchange of the code with
an identity provider needs a browser sign-in and is checked by hand.

## QR codes are read with Vision

`DetectBarcodesRequest` of Vision, limited to QR codes, reads the image that `NSImage` makes
from the clipboard. The first payload starting with `otpauth://` fills the Add Account dialog
rather than being added at once, so the name can be changed and a duplicate or invalid code is
reported the way a typed one is.
