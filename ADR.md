# Architectural Decision Records

## The menu is a SwiftUI MenuBarExtra with an observable store

The menu is `MenuBarExtra` in the `.menu` style, the way the menu of serve-markdown is built,
and `LSUIElement` keeps the app out of the Dock. The app also sets the accessory activation
policy at launch, since a run from Xcode has no bundle and so no `Info.plist`; without the
policy the dialogs do not take the keyboard. An accessory app is absent from Cmd-Tab, so the
Settings window makes the app regular while it is open and returns it to accessory when it
closes. The state is `AccountStore`, an `@Observable`
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
needs it when it has no token or its token has ended.

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
the secret and URI cases. `make tests` runs them; `make` does not.

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

## Problems are classified once and shown where the user looks

Every failure of a Vault call goes through `VaultProblem` in the library, which turns a
`URLError`, a `VaultError` or an app error that states its own problem into a
title, a detail and a suggestion. The raw system texts name neither the cause nor the next step,
and one mapping keeps every surface saying the same thing. The mapping is in the library so
that it is tested without the app.

A `VaultSession` records the problem of its last call: a failed status holds it, and a call that
works returns the status to signed in, so a token vault whose server goes down shows it, which a
status set only at sign-in did not. The session reports a vault that worked and then failed once,
until it works again; the store retries once a period, and a notification for each retry would be
noise. Notifications need the permission and a bundle, so the permission is asked when the first
vault is saved, where its purpose is clear, and an Xcode run posts none.

The user meets a problem in four places that read the session: a warning beside the menu bar
icon and a menu line that opens the vault, the vault's page with the cause and the time of the
attempt, the account in the list and in its window, and the notification. Test Connection runs
the steps of a connection one by one on the settings as typed, without a session or a saved
setting, so a vault can be checked before it is saved and the failing step is named.

## Vault Setup writes policies for each engine, replaces nothing unasked, and assigns nothing

Setup enables the TOTP engine and writes `totp_creator` and `totp_user`, and, when asked, enables
a KV v2 engine and writes `kv_creator` and `kv_user`, with the identity the
vault's page describes, and stops at the first call that fails: Vault's own answer, such as a
path already in use or a refused write, says what is wrong, and a half-done setup that went on
would hide it. The identity is the page as typed, like Test Connection, so an administrator's
token need not be saved as the vault's credential.

The creator policy holds `read` as well as `create` and `update`, because the app reads a key to
check that the name is free and to make the account. The user policy holds `read` on keys and
`list`, beside `read` on codes: reading a key returns its issuer, account name, algorithm, digits
and period but never the secret, and adding an account from a vault needs them. Neither holds
`delete` or `sudo`. A user who adds accounts and shows codes needs both policies.

A policy of the same name is not replaced unless the dialog is told to, since a write replaces
the whole policy of a vault that may use it for more than this. Policies are assigned by the
vault's administrator, not by the setup, so the setup grants nobody access.

The KV setup is for either version, each its own part of the setup with its own mount and
policy names, `kv_creator` and `kv_user` for version 2 and `kv1_creator` and `kv1_user` for version 1,
and the engine is mounted with the option `version` stated, since the default of an engine is
Vault's to change. A version 2 policy has to name the `data/` and `metadata/` paths; a version 1
policy names the mount's paths alone, `<mount>/*` with `list` and the rest, and has no `patch`,
which version 1 has no call for. The creator policy holds `create`, `update`,
`patch` and `read` on `<mount>/data/*`, since writing a field of a secret that exists is a patch
and of one that does not, a create, and `list` on `<mount>/metadata`; the user policy holds `read`
and `list`. Neither holds `delete`, `destroy` or `sudo`, so a secret cannot be deleted through them.
The TOTP part and the KV part are chosen separately, may not share a mount or a policy name, and
run in that order, the TOTP part first, stopping at the first failure.

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

## The OIDC token is kept in the keychain and the sign-in is explicit

The identity provider signs the user in, so the app stores no credential for OIDC. It keeps the
resulting Vault token in the keychain, in an item of its own per profile, in a service apart from
the profiles: a profile's credential item is a token, a password or a SecretID by the method, and
a token of a sign-in must never be taken for one when the method is changed. The session takes the
kept token up when it is made, unless it has ended, so a sign-in is repeated only when the token
ends or Vault refuses it, not after each launch. Sign Out, a change of the profile, a token
that ended or was refused, and the profile's removal delete the item. A keychain that refuses to
keep the token is logged, and the token works in memory. The tokens of the other methods are
not kept, since those methods log in again by themselves. The sign-in window is opened from Sign
In only, never because a code was needed, so a window opening in the background cannot start a
login nobody expects.

The redirect URI is `http://localhost:<port>/oidc/callback`, 8250 by default, which the role's
`allowed_redirect_uris` must hold, as for `vault login -method=oidc`. The state of the
authorisation URL is compared with the state of the redirect before the code is passed to Vault.

## OIDC signs in in an embedded web view the app controls

The identity provider's pages open in a window of the app, a `WKWebView`, and not in the user's
browser: a login page in another app, with no visible tie to the Authenticator, confuses the user,
and a browser that is sent to `http://localhost` raises unsecured connection prompts. The app
takes the redirect itself: the navigation policy cancels the navigation to the redirect URI and
reads the state and the code from its address, so nothing listens on a port, nothing loads from
localhost, and two OIDC vaults can use one redirect port, which only builds the URI.

The policy is a pure type of the library, `OIDCSignInPolicy`, so it is tested without WebKit: the
redirect ends the sign-in, a page over HTTPS loads, and plain HTTP, `data:`, `file:`,
`javascript:` and custom schemes are refused with the reason shown in the window. A page that
opens a window loads in the same view. The header names the host of the page at all times, which
is the user's only check of where a password goes. Certificate trust is the system's, so the
user's own CA applies and WebKit shows no certificate pop-up; a failed load shows an error line.

The provider's cookies live in a persistent data store of the app, identified by a fixed UUID and
apart from Safari's, so a provider's session survives and a sign-in after a launch is often one
click; the cost is that the session is kept on disk in the app's container.

An embedded view has costs that the choice accepts: RFC 8252 recommends an external user agent
for native apps, the view has no Safari session, no Kerberos or enterprise single sign-on
extension and no platform passkeys without a browser entitlement, some providers refuse embedded
views, and the app can in principle see what is typed in it. A provider for which this matters
needs the browser, which an `ASWebAuthenticationSession` would give.

## Vault is reached through URLSession, over HTTPS or plain HTTP, and tested against a dev server

Requests go through `URLSession`, so the system trust store applies. App Transport Security is
off for the app, `NSAllowsArbitraryLoads` in `Resources/Info.plist`, so a Vault at any address can
be reached over plain HTTP, such as one on a private network without TLS, and the address of a
Vault is a setting that no build knows. The app makes no other connections; the pages of the OIDC
sign-in load in a web view, which ATS does not govern, and are limited to HTTPS by the app. The
credential and the codes cross the network unencrypted over HTTP, which is the user's choice for
that Vault; an HTTPS address keeps the checks of the system trust store.

`VaultTests` start `vault server -dev`, which keeps its storage in memory, once for the whole
suite, through a suite trait that provides the test scope, and configure it through its HTTP
API with plain `URLSession` calls, apart from the client under test. The `vault` binary is a
requirement of the tests, and a missing one fails them. The namespace header is checked on the
request alone, since namespaces exist only in Vault Enterprise. The exchange of the code with
an identity provider needs the sign-in window and is checked by hand.

## QR codes are read with Vision

`DetectBarcodesRequest` of Vision, limited to QR codes, reads the image that `NSImage` makes
from the clipboard. The first payload starting with `otpauth://` fills the Add Account dialog
rather than being added at once, so the name can be changed and a duplicate or invalid code is
reported the way a typed one is.

## A secret account is a kind of account, in the same list

An account is an OTP account or a secret account (`Account.Kind`, OTP by default). A secret account
has no algorithm, digits or period that anything reads, but it shares the id, the name, the
unique-name rule, the menu order and the removal of the other accounts, so the menu, the Accounts
tab and the stored order need no second list. Everything that computes or shows a code works on
OTP accounts alone: a secret account is not a shown account, has no window and cannot be chosen
for the menu bar, so a secret is never drawn on the screen unasked. It is copied, or revealed in
the Settings window until the user hides it.

## A secret account in the keychain has a service of its own

The items of OTP accounts have the generic attribute `algorithm=...&digits=...&period=...`, and an
account whose attribute does not parse is dropped, but one with other keys parses as a default
TOTP account. A secret kept in the OTP service would be read by a build that knows no secret
accounts as a TOTP secret, and shown as codes computed from a password. A service of its own,
`...MacAuthenticator.secret`, makes such a build ignore the items.

## A Vault secret is a reference to one field, and the KV version is the user's choice

The reference is the KV version, the mount, the secret's name and the field: a secret is a single
level of fields, and the account is one of them. The user names the KV version, since the call
that tells it, `sys/internal/ui/mounts/<mount>`, has no stability guarantee in Vault's
documentation, and a wrong guess reads or writes the wrong paths. The records of Vault accounts
in the user defaults gain a kind and a reference, both optional, so records written before
secret accounts decode as OTP records.

Writing sets one field and keeps the rest of the secret. KV v2 patches the secret
(`application/merge-patch+json`) and, when it does not exist, creates it with `cas` 0, so a
concurrent creation is not overwritten. KV v1 has no merge, so the secret is read, the field set
and the secret written back from the JSON the vault returned, which keeps fields of other types.

## A copied secret is concealed and cleared

A copied secret carries `org.nspasteboard.ConcealedType`, which clipboard managers honour by not
recording it, and the clipboard is emptied after 30 seconds if its change count is still that of
the copy, so a later copy of the user's is not lost. A TOTP code expires on its own and is copied
as plain text.
