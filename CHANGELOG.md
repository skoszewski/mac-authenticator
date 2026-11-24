# Changelog

## 0.4.1 - 2026-11-24 19:36:41 +0100

fix: Test Connection does not warn of plain HTTP to an address that resolves to this Mac.

- The address step of Test Connection warns that a plain http:// address sends the credential
  and the codes unencrypted, except when the host name resolves to loopback addresses alone, such
  as localhost, 127.0.0.1 or ::1.

## 0.4.0 - 2026-11-24 16:24:34 +0100

feat: the app says what is wrong with a vault, in the menu bar, in Settings and in a
notification, and reaches a Vault over plain HTTP at any address.

- While a vault's last call failed, the menu bar icon shows a warning triangle, and the menu
  starts with a line `Vault <name>: <what is wrong>` that opens Settings on that vault.
- A problem is said in words: what is wrong, what happened and what to do, for an address that
  does not resolve, nothing listening, a timeout, an untrusted certificate, a refused sign-in, a
  denied policy, a wrong mount, a sealed Vault and the like.
- The vault's page shows the problem under its status, with the time of the last attempt and a
  Copy Details button. A vault whose server goes down is marked failed also when it uses a token.
- A Vault account whose vault has a problem shows a warning in the Accounts list, a Problem
  section in its details, and the problem in its code window. The Add from Vault dialog names the
  vaults whose keys could not be listed.
- Test Connection on the vault's page checks the settings as typed, without saving them: the
  address, the server, the sign-in and the TOTP engine, and names the step that fails.
- A macOS notification names a vault that worked and fails; clicking it opens Settings on the
  vault. It needs the app made by make, and the permission is asked when the first vault is
  saved.
- App Transport Security is off for the app, so a Vault address with http:// works for any host
  or IP address. The credential and the codes cross the network unencrypted over HTTP; an
  https:// address is still checked against the system trust store.

## 0.3.1-2 - 2026-11-24 10:49:55 +0100

feat: make signs the app with the identity of SIGN_IDENTITY or of the untracked Makefile.local.

- The code signing identity comes from the command line or from Makefile.local, and the app is
  signed ad hoc without either. A stable identity, such as an Apple Development certificate,
  keeps the access of the app to the keychain across rebuilds.
- The README describes signing.

## 0.3.1 - 2026-11-24 08:02:16 +0100

fix: the app made by make opens in Finder, the Accounts list shows where each account is stored,
the dot of a vault shows its sign-in state, and every vault can sign in and out.

- The bundle is assembled aside and moved into dist whole, so Finder no longer shows the new app
  with a no-entry sign.
- Each account of the Accounts list has a subtitle with its store, Keychain or Vault: and the name
  of the vault. The details of the account show it as Store.
- The dot before a vault in the Vaults list is smaller and has the color of the sign-in state:
  green when signed in, yellow while signing in, red after a failure and gray when signed out.
- Sign In and Sign Out of a vault are enabled for every sign-in method again, not for OIDC alone.

## 0.3.0 - 2026-11-24 07:41:04 +0100

feat: several Vault servers, each a vault with its own sign-in, managed in a new Settings window
that also adds accounts from a vault.

- A Settings window, opened with Settings... in the menu or Command-comma, has the tabs Accounts
  and Vaults. Each is a list with + and - buttons and a pane with the details of the selected
  item.
- Accounts lists all accounts, whether the keychain or a vault keeps the secret, with the
  place of each. The + menu adds an account by Account..., From QR Code in Clipboard,
  From Vault..., Generate in Vault... or Import to Vault.... The details hold Show in menu bar,
  Show Window and Copy Code.
- Vaults lists any number of Vault servers, each with its own settings and sign-in, kept as a
  keychain item named after the vault. Accounts of several vaults show codes together.
- Sign In and Sign Out of a vault are enabled for OIDC alone; the other methods sign in when
  a code is needed.
- The menu keeps the accounts with Copy Code, Show and Show in Menu Bar, and Settings, Launch at
  Login, About and Quit. Add Account, Remove and the Vault menu are in the Settings window.
- The Vault settings and the Vault accounts of 0.2.0 are not carried over: add the vault and its
  accounts again.

## 0.2.0 - 2026-11-24 06:08:33 +0100

- feat: HashiCorp Vault support as OTP key backend.

## 0.1.0 - 2026-11-23 07:57:45 +0100

- Added a small utility that draws the icon for the Windows sibling app.
- fix: added missing LICENSE.
- Generated code with Claude Code.
