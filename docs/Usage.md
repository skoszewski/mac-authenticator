# Using Mac Authenticator

The menu bar app, its Settings window, the accounts it holds and where their secrets are kept. The
HashiCorp Vault side is in [Vault.md](Vault.md).

The app has two kinds of accounts: OTP accounts, which show a current TOTP code (RFC 6238) in a
small window floating over the others or beside the menu bar icon, and secret accounts, which hold
a plain string, such as a password or an encryption key, and copy it on demand. The app shows an
icon in the menu bar, and no Dock icon, except while the Settings window is open: then the app has
a Dock icon and a place in Cmd-Tab.

## The menu

- one submenu for each account, named after it; a secret account's submenu has **Copy Secret**,
  which puts the secret in the clipboard, concealed and cleared after 30 seconds. The submenu of
  a TOTP account has:
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

**Vaults** lists the HashiCorp Vault servers the app is set up for; see [Vault.md](Vault.md).

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

## Secret accounts

An account is one of two kinds: a TOTP account, which shows codes, and a secret account, which
holds a plain string, such as a password or an encryption key, and shows no code. A secret is kept
in the login keychain, or in a field of a secret of a Vault KV engine. A secret account is listed
with the other accounts, with a key symbol, and keeps its place in their order.

**Secret...** in the **+** menu of the Accounts tab asks for a name and the secret, and keeps the
secret in the login keychain. For a secret account the details pane shows, in place of a code:

- **Reveal**, which shows the secret until **Hide** is chosen, another account is selected, or the
  Settings window loses the keyboard or closes;
- **Copy Secret**, which puts the secret in the clipboard marked as concealed
  (`org.nspasteboard.ConcealedType`), so clipboard managers that honour it skip it, and empties the
  clipboard after 30 seconds, or when the app quits, if it still holds that copy.

Each secret account has a setting, **Ask to authenticate before it is shown or copied**, which is
on when the account is added unless it is unticked in the dialog, and can be changed in the details
pane. When it is on, Reveal and Copy Secret, and Copy Secret in the menu, ask the user to
authenticate first, with Touch ID, an Apple Watch or the password, as for macOS's own password
items; cancelling the prompt does nothing. When it is off they act at once. An account without
the setting, such as one kept by an earlier build, asks.

Next to it is **Reauthenticate after**, a number of seconds, 0 by default. After the user
authenticates, a secret whose number is above 0 is shown or copied without asking again until that
many seconds have passed since the authentication; with 0 it asks every time. An authentication
counts for every secret that allows the time since it, and it is forgotten, so that every secret asks
again, when the computer wakes, when the screens wake, and when the user session switches out or in.
Locking the screen while the display stays on does not forget it, since macOS has no documented
signal for that.

**Hide after** is the number of seconds a shown secret stays shown, 30 by default; 0 never hides it,
for development and lab use. It applies to Reveal in the details pane, which shows a bar and the
seconds left like a code window, and to the secret window.

**Show**, in the secret's submenu, and **Show Window**, in its details pane, open the secret window,
a small panel that floats over the other windows on every Space, like a code window. The secret is
masked as `********`, and a click on it reads the secret, after the authentication its settings ask
for, and shows it with a bar and the seconds left, in the font size of a code; when the time ends,
or the window is closed, the secret is masked again. The secret is kept on one line: the window
opens as wide as the secret needs, up to a maximum width, and a secret that does not fit is shown in
a smaller font; the window can be resized, and it refuses to become narrower than the secret needs in
the smallest font. After the user resizes it, it keeps that size until it is closed. Hiding the secret again does not
change the size of the window. A secret longer
than 64 characters is not shown at all: the window says so and only offers **Copy**. With a hide time
of 0 the bar is replaced by a **Hide** button. **Copy**
copies the secret as Copy Secret does. A secret account cannot be shown beside the menu bar icon, so
a secret is never drawn on the screen unasked.

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

A secret account kept in the keychain is an item of the service
`pl.waw.koszewscy.MacAuthenticator.secret`, of its own so that a build that knows no secret accounts
does not read a password as a TOTP secret: the item's password is the secret, its account attribute
the account's id, its name (label) the account's name and its kind (description)
`Mac Authenticator secret`. A secret is read when it is revealed or copied, and kept nowhere.

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
