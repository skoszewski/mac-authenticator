# HashiCorp Vault

An account can take its codes from the TOTP secrets engine of a Vault server, which then holds
the secret and the app never sees it. The app has any number of Vault profiles, each a
connection to one server with its own authentication, and any number of keys of each. A Vault account
looks and works like any other: it has a window, can be shown beside the menu bar icon and can
be copied; its code is fetched from Vault once for each period. While the code of a period is
being fetched, the code window shows an empty code and a small dot in its bottom right corner.

## The Vaults tab

**Vaults** lists the HashiCorp Vault servers the app is set up for, with a dot showing the state
of each vault's authentication. **+** adds a vault and **-** removes the selected one. For the
selected vault the page holds its settings and authentication, with its state, a start button and a
stop button, then **Save** and **Revert**, and below them a Connection group with **Test
Connection** and **Vault Setup...**. The words follow the method:

| Method | State | Start | Stop |
|---|---|---|---|
| Token | Token not checked, Checking the token..., Token accepted | **Check Token** | **Forget Token** |
| Username and password, AppRole | Not logged in, Logging in..., Logged in | **Log In** | **Log Out** |
| OIDC | Signed out, Signing in..., Signed in | **Sign In** | **Sign Out** |

A token, password or AppRole vault also authenticates by itself when a code is needed; an OIDC
vault is signed in with its button when it has no token, or its token has ended.

## The profiles

The Vaults tab of the Settings window asks for:

- the name of the vault, which must be unique;
- the Vault address, such as `https://vault.example.com:8200`; plain `http` is allowed for any
  address, and then the credential and the codes cross the network unencrypted, which a yellow
  warning triangle beside the field says when the mouse rests on it; an address that resolves to
  this Mac has no warning;
- the namespace, for Vault Enterprise; changing the address or the namespace of a saved OIDC vault
  that holds a token warns, and asks whether to keep the token, delete it or cancel the change;
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
    has ended. The token is deleted by **Sign Out** alone, which the user chooses, and by removing
    the vault; an error, a refusal by Vault, the end of the token and a change of the vault's
    settings delete nothing. A token that has ended is not used, and Sign In replaces it.

An empty credential field keeps the credential stored before. A profile is one generic password
item of the service `pl.waw.koszewscy.MacAuthenticator.vault`, labelled with the profile name:
its attributes hold the settings and its data holds the credential, empty for OIDC. The
accounts taken from Vault are in the app's user defaults, each with its profile and key.
Removing a profile deletes its item and its accounts; the keys stay in Vault.

Profiles authenticate independently, so accounts of several servers show codes at once.

With a token, password or AppRole the app authenticates when a code is needed, and again when
Vault refuses the token; a renewable token is renewed when half of its lease has passed. A code that
cannot be fetched is reported in the code window in place of the code.

## Adding accounts from a vault

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

## Secrets in a KV engine

A secret account can read its secret from a KV engine of a vault, version 1 or 2. The reference is
one field of one secret: the KV version, the mount, the secret's name and the field's name. A
secret is a single level of fields, so a field such as `password` or `encryption_key` of the secret
`app` of the mount `secret`; the app keeps only this reference, and reads the field when the secret
is revealed or copied.

**Secret from Vault...** in the **+** menu of the Accounts tab asks for the vault, the KV version,
the mount, the secret and the field, and reads the field once to check the reference; the secrets of
the mount are listed to pick from when the policy allows listing, and a name can be typed.
**Secret in Vault...** asks for the same, and for a value, which is set in the field; the secret is
created when it does not exist, and its other fields are kept (a KV v2 secret is patched, and a KV
v1 secret is read, changed and written back, so its fields of other types are kept too). The account
is named as typed, or `<secret>: <field>`. **Secret in Vault...** first refuses an account name
that is taken, and asks before it replaces a field that holds a value, or that the token cannot
read, so that cannot be told. The mount and the secret's name are names separated by single
slashes, with no empty name and no name of dots; the characters of a name are escaped in the
request. A KV v1 engine has no compare-and-set, so a written field is read back, and written again
when another writer's write dropped it, which does not catch every race. A KV v2 secret whose latest
version is deleted is reported as deleted, not as absent, and a failure to list the secrets is said
in the secret name box. Removing the account does not touch the secret in
the vault.

## Waiting for a vault

A call to a vault that takes more than a moment is shown, and can be cancelled:

- the menu bar icon gets a circular-arrows symbol beside the lock while a call runs, and a
  checkmark for about 2 seconds after a code or a secret was copied;
- the bar at the bottom of the Settings window says what is waited for, for example `Acme: Listing
  the secrets...`, adds `Still waiting` and the seconds after 5 seconds, and has a **Cancel** button
  that cancels the call; after a copy it shows what was copied, with a checkmark;
- the accounts of a vault that is being called show a spinner in the list, and their Copy and Reveal
  buttons are disabled until it ends;
- the alerts that call a vault (Add from Vault, Generate in Vault, Import to Vault, Secret from Vault
  and Secret in Vault) stay open while it runs: the first button is disabled, the second becomes
  **Cancel Request**, and a spinner says what is done; an error is shown in the alert, which keeps
  what was typed; the keys or secrets offered are listed after the alert opens, and the box says when
  they are listed, or why they could not be;
- Test Connection and Vault Setup have a **Cancel** button while they run.

Nothing shows for a call that ends within 300 milliseconds, nor for the fetch of a code in the
background, which a code window shows with its dot. A call that is not cancelled ends after the
network's own timeout, 60 seconds.

## When a vault does not work

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
  issued a token. An OIDC vault that is signed in has its token checked as **Token** and used for
  the engine step; a signed out one has **Authentication** skipped, since it signs in
  interactively, and so the engine step is skipped too. Each step shows passed, warning, failed
  or skipped, and the first failure says what to do.
- When a vault that worked fails, a macOS notification names it; clicking it opens Settings on
  the vault. A vault that keeps failing notifies once, until it works again. The permission is
  asked when the first vault is saved, and the app bundle from `make` posts the notifications;
  a run from Xcode does not.
- Each new problem is also logged to the unified log, subsystem
  `pl.waw.koszewscy.MacAuthenticator`, category `vault`, without secrets.

## Vault Setup

**Vault Setup...**, beside Test Connection on the vault's page, prepares a vault for the app. It
runs as the identity the page describes, with the address, method and credential as typed, so an
administrator's token can be used without saving it; an OIDC vault uses its current sign-in. The
identity is taken to hold the rights for the calls, and the setup stops at the first call that
fails. The dialog has three parts, each switched on or off: the TOTP engine, a KV v2 engine for
secrets and a KV v1 engine for secrets. For each it asks for:

- the mount, taken from the page for the TOTP engine, `secret` for the KV v2 engine and `kv` for the
  KV v1 engine, and a description;
- the names of the two policies: `totp_creator` and `totp_user`, `kv_creator` and `kv_user`, and
  `kv1_creator` and `kv1_user`;
- **The engine is already enabled**, which skips enabling it and writes the policies alone;

and, for both, **Replace policies that exist**, without which a policy of the same name stops the
setup. The engines need different mounts, and the policies different names.

**Run** enables the engines at their mounts, in the order above, and writes the policies, and the
result lists each step. The dialog shows the text of the policies as they will be written:

- `totp_creator` lists keys and creates, updates and reads them, which adds and imports a key;
- `totp_user` lists and reads keys, whose answer holds no secret, and reads codes;
- `kv_creator` lists the mount's secrets and creates, updates, patches and reads them, which writes
  a field of a secret that exists or not;
- `kv_user` lists and reads the secrets;
- `kv1_creator` lists the mount's secrets and creates, updates and reads them, and `kv1_user` lists
  and reads them; a KV v1 engine has no `data` or `metadata` paths and no patch.

The setup assigns no policy: a Vault administrator assigns them to the users, roles or tokens
that need them, both to a user who adds accounts and shows codes.

## What the Vault administrator prepares

- the TOTP engine, with the keys;
- a policy for the user, role or token the app authenticates with:

  ```hcl
  path "totp/keys"   { capabilities = ["list"] }
  path "totp/keys/*" { capabilities = ["read"] }
  path "totp/code/*" { capabilities = ["read"] }
  ```

  The `list` rule is optional, and the `read` rule of `totp/keys/*` is needed to add a key.
  Generating or importing a key needs `create` and `update` on `totp/keys/*` as well;
- for secret accounts, a KV engine and a policy on its paths, which Vault Setup writes as
  `kv_creator` and `kv_user` for a KV v2 engine and `kv1_creator` and `kv1_user` for a KV v1 one.
  For the KV v2 mount `secret`, reading needs `read` on `secret/data/<name>`, writing a field needs `patch` and `create`
  (for a secret that does not exist yet) on it, and listing the secrets needs `list` on
  `secret/metadata`; for a KV v1 mount, the paths are `secret/<name>` and `secret`, and writing
  needs `read`, `create` and `update`;
- for OIDC, a role of the JWT/OIDC method whose `allowed_redirect_uris` holds
  `http://localhost:8250/oidc/callback`, with the port of the settings, and the same URI
  registered with the identity provider.
