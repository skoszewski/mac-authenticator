# Changelog

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
