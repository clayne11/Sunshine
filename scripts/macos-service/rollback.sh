#!/bin/zsh
# Restore a backup created by install.sh --activate and reload launchd.

set -euo pipefail

user_home="${HOME:?HOME must be set}"
launcher_path="$user_home/Applications/Lumen Login Launcher.app/Contents/MacOS/LumenLoginLauncher"
plist_path="$user_home/Library/LaunchAgents/com.clayne.lumen.plist"

if (( $# != 1 )); then
  /bin/echo "Usage: rollback.sh /path/to/recovery/service-YYYYMMDD-HHMMSS" >&2
  exit 64
fi

backup_dir="$1"
backup_launcher="$backup_dir/LumenLoginLauncher"
backup_plist="$backup_dir/com.clayne.lumen.plist"
if [[ ! -f "$backup_launcher" && ! -f "$backup_launcher.absent" ]] || \
   [[ ! -f "$backup_plist" && ! -f "$backup_plist.absent" ]]; then
  /bin/echo "backup must contain each live-file copy or .absent marker: $backup_dir" >&2
  exit 66
fi

/bin/mkdir -p "${launcher_path:h}" "${plist_path:h}"
if [[ -f "$backup_plist" ]]; then
  /usr/bin/plutil -lint "$backup_plist"
fi

timestamp=$(/bin/date '+%Y%m%d-%H%M%S')
launcher_tmp="$launcher_path.rollback-$timestamp-$$"
plist_tmp="$plist_path.rollback-$timestamp-$$"
cleanup_temps() {
  /bin/rm -f "$launcher_tmp" "$plist_tmp"
}
trap cleanup_temps EXIT

if [[ -f "$backup_launcher" ]]; then
  /bin/cp -p "$backup_launcher" "$launcher_tmp"
  /bin/chmod 0755 "$launcher_tmp"
fi
if [[ -f "$backup_plist" ]]; then
  /bin/cp -p "$backup_plist" "$plist_tmp"
  /bin/chmod 0644 "$plist_tmp"
  /usr/bin/plutil -lint "$plist_tmp"
fi

uid=$(/usr/bin/id -u)
domain="gui/$uid"
/bin/launchctl bootout "$domain/com.clayne.lumen" 2>/dev/null || true
if [[ -f "$launcher_tmp" ]]; then
  /bin/mv -f "$launcher_tmp" "$launcher_path"
else
  /bin/rm -f "$launcher_path"
fi
if [[ -f "$plist_tmp" ]]; then
  /bin/mv -f "$plist_tmp" "$plist_path"
else
  /bin/rm -f "$plist_path"
fi
if [[ -f "$plist_path" ]]; then
  /bin/launchctl bootstrap "$domain" "$plist_path"
  /bin/launchctl enable "$domain/com.clayne.lumen"
fi
/bin/echo "Restored Sunshine launchd files from: $backup_dir"
