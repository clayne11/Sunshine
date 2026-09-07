# Sunshine macOS login service

These assets keep the selected Sunshine or Lumen runtime attached to the
logged-in Aqua session while making launchd restart it after either a crash or
a clean process exit.

The launcher remains at the existing app-bundle path so the current
`com.clayne.lumen` job and macOS privacy identity continue to refer to the same
bundle. It waits for an existing TCP 47990 listener to disappear before
starting the configured runtime (default
`~/.local/share/sunshine-personal/sunshine`); this avoids duplicate Sunshine
instances during launchd handoff. When the existing Lumen
wrapper is selected, the launcher refuses a first run without the existing
`.permissions_configured` marker because a login-session job has no terminal
for the permission guide. A direct Sunshine runtime does not use that marker.

Install the files from the repository root with:

```sh
scripts/macos-service/install.sh
```

The installer defaults to the staged fork at
`~/.local/share/sunshine-personal/sunshine`. To keep the existing Lumen runtime
or select another build while preserving the same app-bundle launch path, pass
its absolute command path. `--config` selects the isolated configuration file
passed as Sunshine's first argument:

```sh
scripts/macos-service/install.sh --runtime "$HOME/.local/bin/lumen"
```

The Sunshine defaults are `~/.config/sunshine-personal/sunshine.conf` and web
port `48990` (base port `48989`). Override them with `--config PATH` and
`--web-port PORT` when staging another runtime.

The default install stages the launcher and plist under a unique directory such
as `$HOME/Documents/default/tmp/lumen-recovery/service-20260907-120000-AbCd12/staged`;
it does not change the live launcher, plist, or launchd job. The unique suffix
keeps two staging or activation runs in the same second separate. During a
planned maintenance window, validate the runtime and activate it with:

```sh
scripts/macos-service/install.sh --activate
```

Combine `--runtime PATH` with `--activate` only after that runtime has been
tested in an isolated session. The old Lumen command remains the fallback until
the new runtime is explicitly selected.

Activation saves the previous launcher and plist under the same recovery
directory. If a live file did not exist, the backup contains a `.absent` marker
so a failed activation or rollback removes only that newly created file. To
restore one of those backups, run:

```sh
scripts/macos-service/rollback.sh "$HOME/Documents/default/tmp/lumen-recovery/service-YYYYMMDD-HHMMSS"
```

The plist keeps `RunAtLoad`, `LimitLoadToSessionType=Aqua`, and the existing
stdout/stderr log locations. `KeepAlive=true` is deliberate: launchd should
bring the selected runtime back after a nonzero or zero exit.
`ThrottleInterval=15` prevents a rapid crash loop from consuming the login
session.

Read-only checks after activation:

```sh
launchctl print "gui/$(id -u)/com.clayne.lumen"
lsof -nP -a -iTCP:47990 -sTCP:LISTEN
```
