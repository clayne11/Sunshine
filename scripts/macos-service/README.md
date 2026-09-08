# Sunshine macOS login service

`sunshine_service.py` stages a direct Sunshine executable in an Aqua
LaunchAgent. The default operation only creates a reviewable plist and JSON
manifest under the recovery directory. It does not write the live
`~/Library/LaunchAgents` file or call `launchctl`.

Virtual-display sessions on macOS 12.3 and later use ScreenCaptureKit (SCK)
for virtual-display recreation and capture. Host audio uses the native upstream capture path. These notes describe the selected implementation; they do not
claim that a live session has been validated.

The selected defaults are:

* executable: `~/Applications/Sunshine.app/Contents/MacOS/Sunshine`
* configuration: `~/.config/sunshine-personal/config/sunshine.conf`
* web UI: `https://localhost:47990`
* service label: `com.clayne.sunshine`
* plist: `~/Library/LaunchAgents/com.clayne.sunshine.plist`
* recovery root: `~/Library/Application Support/Sunshine/service-recovery`

The generated plist passes the configuration path as Sunshine's first
argument. It uses `RunAtLoad`, `KeepAlive=true`, `LimitLoadToSessionType=Aqua`,
`ProcessType=Interactive`, `ExitTimeOut=20`, and `ThrottleInterval=15`. The
runtime is launched directly; no login launcher or listener handoff process is
inserted.

## Package the stable Sunshine.app

`package-app.py` turns an existing macOS build into `Sunshine.app` without
building it or changing launchd. It finds a runtime, `vd_helper`, and built
assets under the repository's `build` or `cmake-build-*` directories when they
are not supplied explicitly. The default destination is
`~/Applications/Sunshine.app`; use explicit paths when reviewing a different
build:

```sh
python3 scripts/macos-service/package-app.py \
  --signing-identity "Sunshine Local Signing"
```

When automatic discovery is not appropriate, pass paths from the selected
build explicitly:

```sh
python3 scripts/macos-service/package-app.py \
  --signing-identity "Sunshine Local Signing" \
  --runtime <build-dir>/sunshine \
  --helper <build-dir>/vd_helper \
  --assets <build-dir>/assets
```

`--config` is optional and is only validated as an input path. The config is
never copied into the app, so credentials and per-host state stay outside the
bundle. The `--assets` directory is copied to `Contents/Resources/assets`, but
packaging cannot rewrite the binary's compile-time `SUNSHINE_ASSETS_DIR` path.
Use a bundle-layout build that was compiled to load `../Resources/assets`, or
keep the assets at the path compiled into a Homebrew-style binary; verify the
selected build before removing its original assets. The script writes a
temporary bundle beside the destination, signs `vd_helper` and any nested code
before signing the app, verifies the signature and `Info.plist`, then
atomically replaces the destination. If an app already exists, it is atomically
moved to a timestamped `.previous-*` backup and is restored automatically if
installation or verification fails.

`--signing-identity` is required. For local use, pass the name or SHA-1
fingerprint of a persistent self-signed code-signing certificate available in
the user's Keychain. The script never exports, reads, or stores the private key;
`/usr/bin/codesign` obtains it from Keychain. This is local signing for the
user's Mac and does not claim Developer ID distribution, notarization, or
public release trust.

## Stage and review

From the repository root, stage the default paths with:

```sh
python3 scripts/macos-service/sunshine_service.py
```

Review the generated `staged/com.clayne.sunshine.plist` and
`manifest.json`. Override paths before staging another build:

```sh
python3 scripts/macos-service/sunshine_service.py \
  --runtime "$HOME/Applications/Sunshine.app/Contents/MacOS/Sunshine" \
  --config "$HOME/.config/sunshine-personal/config/sunshine.conf" \
  --recovery-dir "$HOME/Library/Application Support/Sunshine/service-recovery"
```

Staging does not require the executable or config file to exist, which allows
the artifact to be reviewed before a build is installed. Activation performs
those checks and refuses missing or non-executable inputs.

## Explicit activation and rollback

Run this only after reviewing the staged plist and testing the selected
runtime in an isolated session:

```sh
python3 scripts/macos-service/sunshine_service.py --activate
```

Activation saves the previous Sunshine plist and its mode, records the
launchd enabled state, then atomically installs the direct-app plist. It boots
out and disables `com.clayne.lumen` and `com.clayne.sunshine.staging` while
leaving their plist and app files untouched. The latter's plist is kept at
`~/.config/sunshine-personal/service/com.clayne.sunshine.staging.plist`. The
old enabled states are recorded in the activation manifest. It then bootstraps and enables
`com.clayne.sunshine`.

Use the manifest printed by activation to restore the previous state:

```sh
python3 scripts/macos-service/sunshine_service.py \
  --rollback "$HOME/Library/Application Support/Sunshine/service-recovery/service-YYYYMMDD-HHMMSS-XXXXXX/manifest.json"
```

Rollback boots out Sunshine, restores the prior plist (or removes the newly
created one), re-loads jobs that were loaded before activation, and restores
the recorded enabled states. If an installation uses a different legacy
label, repeat `--old-label LABEL --old-plist PATH` during both staging and
activation. Unknown labels otherwise default to
`$HOME/Library/LaunchAgents/LABEL.plist`.

## Verification and tests

After an approved activation, inspect the job and web listener:

```sh
launchctl print "gui/$(id -u)/com.clayne.sunshine"
lsof -nP -a -iTCP:47990 -sTCP:LISTEN
```

The fixture test uses a temporary home and fake `launchctl`, so it does not
change the current login session:

```sh
python3 scripts/macos-service/test_sunshine_service.py
```

The packager fixture test validates identity refusal, bundle-path discovery,
and restoration after a failed signature check without invoking `codesign`:

```sh
python3 scripts/macos-service/test_package_app.py
```

`install.sh`, `rollback.sh`, `LumenLoginLauncher`, and
`com.clayne.lumen.plist.in` remain in this directory as the legacy Lumen
workflow and are intentionally not modified by the Sunshine-only tool.
