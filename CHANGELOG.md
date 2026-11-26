# Changelog

## 0.7.3 - 2026-11-26 07:36:09 +0100

fix: a call to a vault shows that it is running and can be cancelled, in the menu bar, in Settings
and in the alerts, and the README is split into docs.

- The menu bar icon shows circular arrows while a call to a vault runs, and a checkmark for about 2
  seconds after a code or a secret was copied.
- The Settings window has a bar at the bottom that says what is waited for and for how long, with a
  Cancel button, and shows what was copied; the accounts of a busy vault show a spinner, and their
  Copy and Reveal buttons are disabled until it ends.
- The alerts that call a vault stay open while the call runs, with a spinner and a Cancel Request
  button, and show an error in the alert with what was typed kept. Secret in Vault asks before it
  replaces a field in the same alert. The keys and secrets offered are listed after the alert opens.
- Test Connection and Vault Setup can be cancelled while they run.
- The README opens with what the app is for in two sentences, and links to three new guides:
  docs/Usage.md, with the menu, the Settings window, adding accounts, secret accounts and the
  keychain; docs/Vault.md, with everything about Vault; and docs/Development.md, with the
  requirements, building, testing, signing, the app icon and releasing. The README keeps the
  installation.

## 0.7.2 - 2026-11-26 07:10:53 +0100

fix: a secret can ask the user to authenticate before it is shown or copied, Vault accounts are not
lost to unreadable records, and the writes of a secret are checked first.

- Reveal and Copy Secret ask the user to authenticate with Touch ID, an Apple Watch or the
  password when the secret's setting asks for it; the setting is per secret, on by default, chosen
  when the secret is added and changed in its details; cancelling does nothing. A revealed secret
  is hidden when the Settings window loses the keyboard or closes, and a copied secret is also
  cleared from the clipboard when the app quits.
- Stored Vault account records that cannot be read are reported and left as they are, not replaced
  by an empty list by the next change; an account whose record has no KV reference says so.
- Secret in Vault refuses a taken account name before it writes, asks before it replaces a field
  that holds a value, and checks a KV v1 write by reading the field back. Generate in Vault and
  Import to Vault also refuse a taken name before they change the vault.
- A mount or secret name with an empty name between slashes, a name of dots or a control character
  is refused, and the characters of a name are escaped in the request.
- A KV v2 secret whose latest version is deleted is reported as deleted. A failure to list the
  secrets of a mount is said in the secret name box.
- A yellow warning triangle beside the address of a vault, with its description on hover, says that
  the address uses plain HTTP.

## 0.7.1 - 2026-11-26 06:26:57 +0100

fix: only Sign Out or removing the vault deletes the token of an OIDC sign-in, not an error or a
change of the settings, and changing a vault's address or namespace asks about its token.

- A call that Vault refuses with 403, which a policy can cause as well as a bad token, no longer
  signs the vault out and deletes its token: the vault shows the refusal as its problem, and the
  token stays for the next call.
- A token that has ended is kept, and not used, until Sign In replaces it or Sign Out deletes it;
  Sign Out can be chosen while a token is held, whatever the status says.
- Saving the vault's settings deletes no OIDC token.
- Test Connection of a signed in OIDC vault uses the token of the sign-in for the address and
  namespace in the form, as typed.
- Changing the address or the namespace of a saved OIDC vault that holds a token warns and asks
  whether to keep the token, delete it, or cancel the change.

## 0.7.0 - 2026-11-25 20:49:03 +0100

feat: secret accounts, plain strings kept in the keychain or in a field of a Vault KV secret, next
to the TOTP accounts, and KV v2 and v1 engines in Vault Setup.

- **Secret...** in the **+** menu of the Accounts tab adds a secret account whose secret is kept in
  the login keychain, in an item of its own service.
- **Secret from Vault...** adds a secret account that reads one field of a secret of a KV v1 or v2
  engine, named by the KV version, the mount, the secret and the field; **Secret in Vault...** also
  sets the field, creating the secret when it does not exist and keeping its other fields.
- A secret account has **Copy Secret** in the menu and in Settings, and **Reveal** and **Hide** in
  Settings. A copied secret is marked concealed and cleared from the clipboard after 30 seconds.
  A secret account has no window and is not shown beside the menu bar icon.
- Vault Setup can also enable a KV v2 engine and write the policies `kv_creator`, which lists,
  creates, updates, patches and reads secrets, and `kv_user`, which lists and reads them, and a KV
  v1 engine with `kv1_creator` and `kv1_user`; the TOTP, KV v2 and KV v1 parts are each switched
  on or off.

## 0.6.4 - 2026-11-25 18:34:40 +0100

fix: the build number the About panel shows is the id of the commit the app was built from.

- The bundle's build number is the abbreviated id of the HEAD commit, as `git log --oneline` shows
  it, not the number of commits; the About panel shows it after the version.

## 0.6.3 - 2026-11-25 18:32:42 +0100

fix: the About panel shows the build number of the app next to its version, not the version twice.

- The bundle's build number is the number of commits, so the About panel shows, for example, 0.6.3
  (15) and not 0.6.3 (0.6.3).

## 0.6.2 - 2026-11-25 18:29:28 +0100

feat: the token of an OIDC sign-in is kept in the keychain, the Settings window can be reached with
Cmd-Tab, and a code window does not flash while a Vault code is fetched.

- The code window of a Vault account keeps its layout when a period ends: the code is empty and a
  small dot in the bottom right corner shows that the code is being fetched, instead of the window
  switching to a message and back.
- The Vault token of an OIDC sign-in is kept in the keychain, so an OIDC vault is signed in after a
  launch until its token ends; Sign Out, a change of the vault, a token that ended or was refused,
  and the removal of the vault delete it.
- Test Connection of a signed in OIDC vault checks the token of the sign-in and lists the keys of
  the TOTP engine with it; the token goes to the vault's own address alone.
- `make` builds the app without running the tests; `make tests` runs them.
- While the Settings window is open the app is a regular app, with a Dock icon and a place in
  Cmd-Tab; closing the window returns it to the menu bar alone.

## 0.6.1 - 2026-11-25 13:18:59 +0100

fix: the authentication of a vault and its messages are named after what happens, and no message
points at a control or a place.

- Test Connection calls its authentication step Token, Login or Authentication, not Sign-in: a
  token is checked and its end is given, a password or an AppRole is logged in and Vault issues a
  token, and an OIDC vault is not tested.
- The Address step of Test Connection shows the address as typed, not the address of the health
  check, and the skipped steps state that they were not tested, and why.
- The state and the buttons of a vault follow its method: Token not checked, Token accepted, Check
  Token and Forget Token for a token; Not logged in, Logged in, Log In and Log Out for a password or
  an AppRole; Signed out, Signed in, Sign In and Sign Out for OIDC.
- The section of a vault's page that holds the method, the credential and the state is called
  Authentication, not Sign-in, and the messages that apply to every method say authentication. The
  advice after a refused token names the action of the vault's method: replace the token, log in
  again, or sign in again.
- The messages about a missing credential, an empty setting, a missing vault, a refused keychain
  and an existing policy no longer name a menu path or a control.

## 0.6.0 - 2026-11-25 11:29:39 +0100

feat: an OIDC vault signs in in a window of the app, which takes the identity provider's redirect
itself, instead of the browser.

- Sign In to an OIDC vault opens a window with the identity provider's pages. It shows the host of
  the page, loads pages over HTTPS only, and closes itself when the sign-in is done; closing it
  cancels the sign-in without a problem.
- The redirect to the redirect URI is taken inside the window, so nothing listens on a port, no
  page is loaded from localhost, and two OIDC vaults can use the same port.
- The identity provider's cookies are kept in the app's own store, apart from Safari's, so a later
  sign-in is often one click.
- A page that fails to load, such as one with an untrusted certificate, is explained in the
  window, with no system pop-up.
- The Callback port setting is called Redirect URI port; it only builds the redirect URI that the
  OIDC role allows, so no vault needs reconfiguring.

## 0.5.0 - 2026-11-25 11:08:25 +0100

feat: Vault Setup enables the TOTP engine of a vault and writes the policies totp_creator and
totp_user.

- A Vault Setup... button beside Test Connection opens a dialog that asks for the mount of the
  TOTP engine, a description, and the names of the two policies, and has the options The engine
  is already enabled and Replace policies that exist, with Run and Cancel buttons.
- Run enables the engine at the mount and writes the policies, and lists each step. It stops at
  the first call that fails, and does not replace a policy that exists unless told to.
- totp_creator lists keys and creates, updates and reads them; totp_user lists and reads keys and
  reads codes. The dialog shows both policies as they will be written.
- The setup runs as the identity the vault's page describes, so an administrator's token can be
  typed without being saved. It assigns no policy; a Vault administrator assigns them.

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
