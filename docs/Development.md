# Development

Building, testing, signing and releasing Mac Authenticator.

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

## Testing

`make tests` runs `swift test`: the tests in `Tests/TOTPTests` compare the codes with the test
vectors of RFC 6238 Appendix B for SHA-1, SHA-256 and SHA-512 and with codes printed by
`otp.py` of linux-cloud-router, and check the reading of secrets and otpauth URIs. The tests in
`Tests/VaultTests` run the Vault client against a dev server they start: the sign-in with a
token, a password and an AppRole, renewing, listing and reading keys, the policy that denies
listing, a revoked token, and codes that agree with the ones `TOTP` computes for the same
secret; and the rules that decide which pages of the OIDC sign-in window load and which address
ends the sign-in.

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
`tools/version.py`, without a `-n` revision, and the build number from the id of the HEAD
commit, as `git log --oneline` shows it, so the About panel shows, for example, 0.6.3 (6eca9d0).

