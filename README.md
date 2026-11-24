# Mac Authenticator

A macOS menu bar app holding TOTP accounts and showing their current codes, in a small window
floating over the others or beside the menu bar icon. The codes follow RFC 6238 and refresh as
their period passes. The app shows an icon in the menu bar, and no Dock icon.

## Requirements

- macOS 27 or later.
- Xcode 27, selected as the active developer directory, since `make` compiles the app icon
  with its `actool`:

  ```sh
  sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
  ```

- The `vault` binary on `PATH`, or named by `VAULT_BINARY`, for `make test`: the Vault tests
  start an in-memory `vault server -dev` on 127.0.0.1, port 18200 or `VAULT_TEST_PORT`, and stop
  it afterwards.

## Building

```sh
make            # run the checks and write "dist/Mac Authenticator.app"
make test       # run the checks alone
make build      # build the executable alone
make clean      # remove the build products and dist/
```

## The app icon

The app icon, a shield with a keyhole inside a countdown ring, is `Resources/AppIcon.icon`, an
Icon Composer document: a gradient background and two groups of layers, to which macOS adds
its Liquid Glass effects and its dark, clear and tinted appearances. `make` compiles it with
`actool` into the bundle's `Assets.car` and adds the `CFBundleIconName` and `CFBundleIconFile`
keys that `actool` writes to the bundle's `Info.plist`.

The icon is changed in Icon Composer (Xcode > Open Developer Tool > Icon Composer). Its layers
are kept as flat SVG files in `Resources/AppIconLayers`, whose README holds the settings the
icon was composed with.

`tools/make-windows-icon.swift` draws the icon of Windows Authenticator into that repository,
whose path it is given:

```sh
swift tools/make-windows-icon.swift <windows-authenticator>/src/WindowsAuthenticator/Resources/AppIcon.ico
```

`make test` runs `swift test`: the tests in `Tests/TOTPTests` compare the codes with the test
vectors of RFC 6238 Appendix B for SHA-1, SHA-256 and SHA-512 and with codes printed by
`otp.py` of linux-cloud-router, and check the reading of secrets and otpauth URIs. The tests in
`Tests/VaultTests` run the Vault client against a dev server they start: the sign-in with a
token, a password and an AppRole, renewing, listing and reading keys, the policy that denies
listing, a revoked token, and codes that agree with the ones `TOTP` computes for the same
secret; and the listener that receives the OIDC redirect.

The app is signed ad hoc. `SIGN_IDENTITY` names another code signing identity from the
keychain, for example a self-signed certificate made in Keychain Access:

```sh
make SIGN_IDENTITY="Mac Authenticator Local"
```

## Installing and running

```sh
cp -R "dist/Mac Authenticator.app" ~/Applications/
open "$HOME/Applications/Mac Authenticator.app"
```

## The menu

- one submenu for each account, named after it, with:
  - **Copy Code** puts the current code in the clipboard;
  - **Show** opens the account's window: the code in two groups of digits, a bar and the
    seconds until it changes, and a **Copy** button. The window floats over the windows of
    other apps, on every Space, until it is closed; choosing Show again brings it forward;
  - **Show in Menu Bar** shows the account's code beside the menu bar icon, ticked for the
    account shown; ticking another account moves the code to it, unticking hides it. The
    choice is kept across launches;
  - **Remove** asks before the account and its secret are deleted, and closes its window;
- **Add Account...** asks for a name and a secret or an otpauth URI;
- **Add Account from QR Code in Clipboard** reads the QR code in the image in the clipboard and
  opens the same dialog with its URI filled in;
- **Vault** holds the HashiCorp Vault connection:
  - the state of the sign-in;
  - **Sign In to Vault** and **Sign Out of Vault**;
  - **Add Vault Key...** adds an account whose codes Vault makes;
  - **Generate Vault Key...** has Vault make a key, shows its QR code, and adds the account;
  - **Import Vault Key...** stores an existing secret in Vault, and adds the account;
  - **Vault Settings...**;
- **Launch at Login** registers the app as a login item, which macOS may ask to approve in
  System Settings > General > Login Items;
- **About Mac Authenticator** shows the app's version;
- **Quit Mac Authenticator** (Command-Q).

## Adding an account

The secret field takes either of:

- a base32 secret, such as `JBSWY3DPEHPK3PXP`, in upper or lower case, with or without spaces,
  dashes and `=` padding; the account gets SHA-1, 6 digits and a 30-second period, and needs a
  name;
- an `otpauth://totp/<label>?secret=<secret>&issuer=<issuer>&algorithm=<SHA1|SHA256|SHA512>&digits=<6..10>&period=<seconds>`
  URI, as `otp.py new` prints and sites show as a QR code. Only `secret` is required. The label
  is `<issuer>:<account name>` or `<account name>`; the `issuer` parameter, when given, stands
  above the label's issuer.

An empty name is taken from the URI: `<issuer>: <account name>`, else whichever of the two the
URI holds. Names are unique, regardless of case. Copied codes have no space between the groups.

A QR code in the clipboard is read from a screenshot or a copied image; Control-Shift-Command-4
copies a selected part of the screen. Only `otpauth://totp/` codes are added: `hotp` accounts
and export codes of other apps, such as `otpauth-migration://`, are refused.

## Where the secrets are kept

Each account is one generic password item of the login keychain, with the service
`pl.waw.koszewscy.MacAuthenticator`:

- the item's password is the account's secret, as base32 text;
- its account attribute is the account's id, a UUID;
- its name (label) is the account's name, as Keychain Access lists it;
- its comment is the issuer, when the account has one;
- its kind (description) is `Mac Authenticator TOTP secret`;
- its generic attribute holds the algorithm, digits and period, as
  `algorithm=SHA1&digits=6&period=30`.

The order of the accounts in the menu is kept in the app's user defaults, as a list of ids.

The menu is built from the items' attributes alone. A secret is read from the keychain only
when its code is needed: when the account's Show window opens or it is chosen with Show in Menu
Bar, it is read and kept in memory while the code is shown, and dropped when the window closes
or the menu bar shows another account; Copy Code reads it, copies the code and keeps nothing.

The keychain lets the app that made an item read its secret without asking. An ad-hoc
signature changes with each build, so after a rebuild macOS may ask, once per account, whether
Mac Authenticator may use the item, when that account's code is first needed; **Always Allow**
keeps the answer until the next build. A stable `SIGN_IDENTITY` avoids the question. A secret
that cannot be read is reported in the code window instead of the code.

When the items cannot be listed, the menu shows why and a **Retry** item, and refuses changes
until they have been listed.

## HashiCorp Vault

An account can take its codes from the TOTP secrets engine of a Vault server, which then holds
the secret and the app never sees it. The app has one Vault connection, with any number of
keys. A Vault account looks and works like any other: it has a window, can be shown beside the
menu bar icon and can be copied; its code is fetched from Vault once for each period.

### The settings

**Vault Settings...** asks for:

- the Vault address, such as `https://vault.example.com:8200`; plain `http` is allowed for
  local addresses alone;
- the namespace, for Vault Enterprise;
- the mount of the TOTP engine, `totp` by default;
- the sign-in method and its mount, which is named after the method by default:
  - **Token**: the token is kept in the keychain;
  - **Username and password**: the user name is a setting and the password is kept in the
    keychain;
  - **AppRole**: the RoleID is a setting and the SecretID is kept in the keychain;
  - **OIDC**: the role, and the port of the redirect listener, 8250 by default. Nothing is kept
    in the keychain: Sign In to Vault opens the browser and the identity provider signs the
    user in. The token lives in memory, so the sign-in is repeated after each launch and when
    the token ends.

An empty credential field keeps the credential stored before. The keychain holds one credential
at most, as one generic password item of the service `pl.waw.koszewscy.MacAuthenticator.vault`.
The other settings, and the accounts taken from Vault, are in the app's user defaults.

With a token, password or AppRole the app signs in when a code is needed, and again when Vault
refuses the token; a renewable token is renewed when half of its lease has passed. A code that
cannot be fetched is reported in the code window in place of the code.

### Adding keys

**Add Vault Key...** lists the keys of the engine, to pick from, and reads the key's algorithm,
digits, period and issuer once, so the window can count the seconds. A key can be typed when
the policy does not allow listing. The name is the one typed, or `<issuer>: <account name>`
from the key. Removing the account does not touch the key in Vault.

**Generate Vault Key...** asks for a key name, an issuer and an account name, and has Vault make
the secret. Vault shows the secret once, as a QR code and an `otpauth://` URL; scan the code
into another authenticator, or copy the URL, before choosing Done. **Import Vault Key...** asks
for a key name and a base32 secret or an `otpauth://totp/` URI; Vault keeps SHA1, SHA256 and
SHA512 keys of 6 or 8 digits, and other keys are refused. Neither replaces a key that exists:
the name must be new. Both add the account to the app, as **Add Vault Key...** does.

### What the Vault administrator prepares

- the TOTP engine, with the keys;
- a policy for the user, role or token the app signs in with:

  ```hcl
  path "totp/keys"   { capabilities = ["list"] }
  path "totp/keys/*" { capabilities = ["read"] }
  path "totp/code/*" { capabilities = ["read"] }
  ```

  The `list` rule is optional, and the `read` rule of `totp/keys/*` is needed to add a key.
  Generating or importing a key needs `create` and `update` on `totp/keys/*` as well;
- for OIDC, a role of the JWT/OIDC method whose `allowed_redirect_uris` holds
  `http://localhost:8250/oidc/callback`, with the port of the settings, and the same URI
  registered with the identity provider.

## Sibling project

Windows Authenticator, the Windows version of this app:
<https://github.com/skoszewski/windows-authenticator>.
