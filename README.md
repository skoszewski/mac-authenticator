# Mac Authenticator

A macOS menu bar app holding TOTP accounts and showing their current codes, in a small window
floating over the others or beside the menu bar icon. The codes follow RFC 6238 and refresh as
their period passes. The app shows an icon in the menu bar, and no Dock icon, except while the Settings window is
open: then the app has a Dock icon and a place in Cmd-Tab.

## Requirements

- macOS 27 or later.
- Xcode 27, selected as the active developer directory, since `make` compiles the app icon
  with its `actool`:

  ```sh
  sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
  ```

- The `vault` binary on `PATH`, or named by `VAULT_BINARY`, for `make tests`: the Vault tests
  start an in-memory `vault server -dev` on 127.0.0.1, port 18200 or `VAULT_TEST_PORT`, and stop
  it afterwards.

## Building

```sh
make            # write "dist/Mac Authenticator.app"
make tests      # run the tests
make build      # build the executable alone
make clean      # remove the build products and dist/
```

## Signing

The bundle is signed ad hoc by default. `SIGN_IDENTITY` names another code signing identity, by
its name or its SHA-1 hash as `security find-identity -v -p codesigning` lists them:

```sh
make SIGN_IDENTITY=<identity>
```

An identity can be kept in the untracked `Makefile.local`, which `make` reads, as the line
`SIGN_IDENTITY = <identity>`. The command line wins over the file. A stable identity, such as an
Apple Development certificate of a free Personal Team or one issued by an own CA that the Mac
trusts for code signing, keeps the access granted to the app in the keychain across rebuilds. An
ad hoc signature changes with every build, and the keychain asks again. The first signing may ask
for access to the identity's private key.

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

`make tests` runs `swift test`: the tests in `Tests/TOTPTests` compare the codes with the test
vectors of RFC 6238 Appendix B for SHA-1, SHA-256 and SHA-512 and with codes printed by
`otp.py` of linux-cloud-router, and check the reading of secrets and otpauth URIs. The tests in
`Tests/VaultTests` run the Vault client against a dev server they start: the sign-in with a
token, a password and an AppRole, renewing, listing and reading keys, the policy that denies
listing, a revoked token, and codes that agree with the ones `TOTP` computes for the same
secret; and the rules that decide which pages of the OIDC sign-in window load and which address
ends the sign-in.

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
- **Settings...** (Command-comma) opens the Settings window;
- **Launch at Login** registers the app as a login item, which macOS may ask to approve in
  System Settings > General > Login Items;
- **About Mac Authenticator** shows the app's version;
- **Quit Mac Authenticator** (Command-Q).

## Settings

The Settings window has two tabs, each a list on the left with **+** and **-** buttons under
it, and the details of the selected item on the right.

**Accounts** lists all the accounts, whichever store keeps the secret, with its type under each
name: Keychain, or "Vault: " and the name of the vault. The details show the account's
name, issuer, store and parameters, and hold **Show in menu bar**, **Show Window** and
**Copy Code**.

- **+** opens a menu of the ways to add an account:
  - **Account...** asks for a name and a secret or an otpauth URI;
  - **From QR Code in Clipboard** reads the QR code in the image in the clipboard and opens the
    same dialog with its URI filled in;
  - **From Vault...** asks for a vault and one of the keys of its TOTP engine, and adds the
    account the key stores;
  - **Generate in Vault...** has a vault make the secret of a new account, keeps it in a key and
    adds the account;
  - **Import to Vault...** stores the secret of an existing account in a key of a vault and adds
    the account;
- **-** asks before the selected account and its secret are deleted, and closes its window.

**Vaults** lists the HashiCorp Vault servers the app is set up for, with a dot showing the state
of each vault's authentication. **+** adds a vault and **-** removes the selected one. For the selected vault the
page holds its settings and authentication, with its state, a start button and a stop button,
and **Save** and **Revert** at the bottom. The words follow the method:

| Method | State | Start | Stop |
|---|---|---|---|
| Token | Token not checked, Checking the token..., Token accepted | **Check Token** | **Forget Token** |
| Username and password, AppRole | Not logged in, Logging in..., Logged in | **Log In** | **Log Out** |
| OIDC | Signed out, Signing in..., Signed in | **Sign In** | **Sign Out** |

A token, password or AppRole vault also authenticates by itself when a code is needed; an OIDC
vault is signed in with its button when it has no token, or its token has ended.

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
the secret and the app never sees it. The app has any number of Vault profiles, each a
connection to one server with its own authentication, and any number of keys of each. A Vault account
looks and works like any other: it has a window, can be shown beside the menu bar icon and can
be copied; its code is fetched from Vault once for each period. While the code of a period is
being fetched, the code window shows an empty code and a small dot in its bottom right corner.

### The profiles

The Vaults tab of the Settings window asks for:

- the name of the vault, which must be unique;
- the Vault address, such as `https://vault.example.com:8200`; plain `http` is allowed for any
  address, and then the credential and the codes cross the network unencrypted;
- the namespace, for Vault Enterprise;
- the mount of the TOTP engine, `totp` by default;
- the authentication method and its mount, which is named after the method by default:
  - **Token**: the token is kept in the keychain;
  - **Username and password**: the user name is a setting and the password is kept in the
    keychain;
  - **AppRole**: the RoleID is a setting and the SecretID is kept in the keychain;
  - **OIDC**: the role, and the port of the redirect URI, 8250 by default. No credential is
    kept: Sign In opens a window of the app with the identity provider's pages, and the provider
    signs the user in there. The window shows the host of the page, loads pages over HTTPS alone,
    and ends the sign-in itself when the provider redirects to the redirect URI, so nothing
    listens on the port and no page is loaded from it. The provider's cookies are kept in the
    app's own store, apart from Safari's, so a later sign-in is often one click. The Vault token
    is kept in the keychain, in an item of its own, so the sign-in is repeated only when the token
    ends or is refused. Sign Out deletes the token item.

An empty credential field keeps the credential stored before. A profile is one generic password
item of the service `pl.waw.koszewscy.MacAuthenticator.vault`, labelled with the profile name:
its attributes hold the settings and its data holds the credential, empty for OIDC. The
accounts taken from Vault are in the app's user defaults, each with its profile and key.
Removing a profile deletes its item and its accounts; the keys stay in Vault.

Profiles authenticate independently, so accounts of several servers show codes at once.

With a token, password or AppRole the app authenticates when a code is needed, and again when
Vault refuses the token; a renewable token is renewed when half of its lease has passed. A code that
cannot be fetched is reported in the code window in place of the code.

### Adding accounts from a vault

A vault stores an account in a key of its TOTP engine. **From Vault...** in the **+** menu of the Accounts
tab asks for the vault and lists its keys, to pick from; the key's algorithm, digits, period and
issuer are read once, so the window can count the seconds. A key can be typed when the policy
does not allow listing. The account is named as typed, or `<issuer>: <account name>` from the
key. Removing the account does not touch the key in the vault.

**Generate in Vault...** in the **+** menu of the Accounts tab asks for a vault, a key name, an issuer and an account
name, and has the vault make the secret. The vault shows the secret once, as a QR code and an `otpauth://`
URL; scan the code into another authenticator, or copy the URL, before choosing Done.
**Import to Vault...** asks for a vault, a key name and a base32 secret or an `otpauth://totp/` URI; Vault
keeps SHA1, SHA256 and SHA512 keys of 6 or 8 digits, and other keys are refused. Neither
replaces a key that exists: the name must be new. Both add the account to the app.

### When a vault does not work

A failure is said in words: what is wrong, what happened, and what to do about it.

- While a vault's last call failed, the menu bar icon shows a warning triangle beside the lock,
  and the menu starts with a line `Vault <name>: <what is wrong>`; choosing it opens Settings on
  that vault.
- The vault's page in Settings shows the problem under its status, with the time of the last
  attempt and **Copy Details**, which puts the text of the problem in the clipboard without any
  secret. A call that works clears it.
- A Vault account whose vault has a problem shows a warning in the Accounts list and a Problem
  section in its details, and its code window says what is wrong in place of the code.
- **Test Connection** on the vault's page checks the settings as typed, without saving them:
  the address, whether the server answers and is unsealed, the authentication, and the TOTP
  engine. The authentication step is named after what it does: **Token** checks that the token is
  valid and says when it ends, **Login** logs in with a password or an AppRole and says that Vault
  issued a token. An OIDC vault that is signed in, at the address of the page, has its token
  checked as **Token** and used for the engine step; a signed out one has **Authentication**
  skipped, since it signs in interactively, and so the engine step is skipped too. Each step shows passed, warning, failed
  or skipped, and the first failure says what to do.
- When a vault that worked fails, a macOS notification names it; clicking it opens Settings on
  the vault. A vault that keeps failing notifies once, until it works again. The permission is
  asked when the first vault is saved, and the app bundle from `make` posts the notifications;
  a run from Xcode does not.
- Each new problem is also logged to the unified log, subsystem
  `pl.waw.koszewscy.MacAuthenticator`, category `vault`, without secrets.

### Vault Setup

**Vault Setup...**, beside Test Connection on the vault's page, prepares a vault for the app. It
runs as the identity the page describes, with the address, method and credential as typed, so an
administrator's token can be used without saving it; an OIDC vault uses its current sign-in. The
identity is taken to hold the rights for the calls, and the setup stops at the first call that
fails. The dialog asks for:

- the mount of the TOTP engine, taken from the page, and a description;
- the names of the two policies, `totp_creator` and `totp_user`;
- **The engine is already enabled**, which skips enabling it and writes the policies alone;
- **Replace policies that exist**, without which a policy of the same name stops the setup.

**Run** enables the engine at the mount and writes the policies, and the result lists each step.
The dialog shows the text of both policies as they will be written:

- `totp_creator` lists keys and creates, updates and reads them, which adds and imports a key;
- `totp_user` lists and reads keys, whose answer holds no secret, and reads codes.

The setup assigns no policy: a Vault administrator assigns them to the users, roles or tokens
that need them, both to a user who adds accounts and shows codes.

### What the Vault administrator prepares

- the TOTP engine, with the keys;
- a policy for the user, role or token the app authenticates with:

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

## Releasing

`release.py` releases the newest entry of `CHANGELOG.md`, which `bin/changelog.py` reads:

- `./release.py` writes the release time into the entry's heading, and commits everything with
  the summary of the entry as the message;
- `./release.py --push` also tags the entry's version and pushes `main` and the tag;
- `./release.py --no-tag` makes an internal release: with `--push`, `main` is pushed without a
  tag;
- `./release.py -n` prints the heading and the git commands instead of making them.

The commit and the date in the heading mark the entry as released, so the next change needs a new
entry with a new version; write new entries with a plain `## x.y.z` heading. The `Makefile` takes
the version the bundle reports from the newest entry of `CHANGELOG.md`, through
`tools/version.py`, without a `-n` revision, and the build number from the number of commits, so
the About panel shows, for example, 0.6.2 (14).

## Sibling project

Windows Authenticator, the Windows version of this app:
<https://github.com/skoszewski/windows-authenticator>.
