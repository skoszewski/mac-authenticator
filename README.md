# Mac Authenticator

A macOS menu bar app for one-time codes and secrets. It keeps them in the login keychain or in
HashiCorp Vault, and hands them to the person at the Mac when they are needed.

## Documentation

- [docs/Usage.md](docs/Usage.md): the menu, the Settings window, adding accounts, secret accounts and
  where the secrets are kept in the keychain;
- [docs/Vault.md](docs/Vault.md): HashiCorp Vault: the profiles and their authentication, accounts and
  secrets kept in Vault, problems and waiting, Vault Setup and what the administrator prepares;
- [docs/Development.md](docs/Development.md): requirements, building, testing, signing, the app icon
  and releasing;
- [ADR.md](ADR.md): the decisions behind the code; [CHANGELOG.md](CHANGELOG.md): the history.

## Requirements

macOS 27 or later.

## Installing and running

Build the app, install it and start it:

```sh
make
cp -R "dist/Mac Authenticator.app" ~/Applications/
open "$HOME/Applications/Mac Authenticator.app"
```

Information for developers, such as the build requirements, running the tests, signing and
releasing, is in [docs/Development.md](docs/Development.md).

## Sibling project

Windows Authenticator, the Windows version of this app:
<https://github.com/skoszewski/windows-authenticator>.
