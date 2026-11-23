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
`otp.py` of linux-cloud-router, and check the reading of secrets and otpauth URIs.

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

## Sibling project

Windows Authenticator, the Windows version of this app:
<https://github.com/skoszewski/windows-authenticator>.
