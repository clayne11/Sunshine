#!/bin/zsh
# Stage the Sunshine Aqua LaunchAgent assets without changing the live service.
# Pass --activate only during a coordinated maintenance window.

set -euo pipefail

script_dir="${0:A:h}"
user_home="${HOME:?HOME must be set}"
user_name="${USER:-$(/usr/bin/id -un)}"
launcher_path="$user_home/Applications/Lumen Login Launcher.app/Contents/MacOS/LumenLoginLauncher"
plist_path="$user_home/Library/LaunchAgents/com.clayne.lumen.plist"
recovery_root="${LUMEN_RECOVERY_DIR:-$user_home/Documents/default/tmp/lumen-recovery}"
runtime_cmd="${LUMEN_RUNTIME_CMD:-$user_home/.local/share/sunshine-personal/sunshine}"
config_path="${LUMEN_CONFIG_PATH:-$user_home/.config/sunshine-personal/sunshine.conf}"
web_port="${LUMEN_WEB_PORT:-48990}"
activate=false

usage() {
  /bin/cat <<'EOF'
Usage: install.sh [--activate] [--runtime PATH] [--config PATH] [--web-port PORT] [--backup-dir PATH]

Stages the app-bundle launcher and rendered LaunchAgent plist under the
recovery directory. The live launcher, plist, and launchd job remain untouched
unless --activate is supplied.
--runtime selects the command launched after the listener guard.
--config passes an explicit Sunshine configuration file to the runtime.
--web-port selects the HTTPS listener used for duplicate-start protection.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --activate)
      activate=true
      shift
      ;;
    --runtime)
      (( $# >= 2 )) || { usage >&2; exit 64; }
      runtime_cmd="$2"
      shift 2
      ;;
    --config)
      (( $# >= 2 )) || { usage >&2; exit 64; }
      config_path="$2"
      shift 2
      ;;
    --web-port)
      (( $# >= 2 )) || { usage >&2; exit 64; }
      web_port="$2"
      shift 2
      ;;
    --backup-dir)
      (( $# >= 2 )) || { usage >&2; exit 64; }
      recovery_root="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 64
      ;;
  esac
done

if [[ "$activate" == true ]]; then
  if [[ ! -x "$runtime_cmd" ]]; then
    /bin/echo "runtime is not executable: $runtime_cmd" >&2
    exit 78
  fi
  if [[ -n "$config_path" && ! -f "$config_path" ]]; then
    /bin/echo "configuration file is missing: $config_path" >&2
    exit 78
  fi
fi

if [[ "$web_port" != <-> ]] || (( web_port < 1024 || web_port > 65535 )); then
  /bin/echo "web port must be an integer between 1024 and 65535: $web_port" >&2
  exit 64
fi

timestamp=$(/bin/date '+%Y%m%d-%H%M%S')
/bin/mkdir -p "$recovery_root"
backup_dir=$(/usr/bin/mktemp -d "$recovery_root/service-$timestamp-XXXXXX")
stage_dir="$backup_dir/staged"
/bin/mkdir -p "$stage_dir"

backup_file() {
  local source="$1"
  local destination="$2"
  if [[ -e "$source" || -L "$source" ]]; then
    /bin/cp -p "$source" "$destination"
  else
    /usr/bin/touch "$destination.absent"
  fi
}

# Encode values for both XML and a sed replacement string. This keeps paths
# containing ampersands, angle brackets, quotes, or the replacement delimiter
# valid in the rendered plist.
xml_sed_value() {
  local xml_value
  xml_value=$(print -rn -- "$1" | /usr/bin/sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' \
    -e "s/'/\&apos;/g")
  print -rn -- "$xml_value" | /usr/bin/sed 's/[\\&|]/\\&/g'
}

home_escaped=$(xml_sed_value "$user_home")
user_escaped=$(xml_sed_value "$user_name")
launcher_escaped=$(xml_sed_value "$launcher_path")
runtime_escaped=$(xml_sed_value "$runtime_cmd")
config_escaped=$(xml_sed_value "$config_path")
web_port_escaped=$(xml_sed_value "$web_port")

stage_launcher="$stage_dir/LumenLoginLauncher"
stage_plist="$stage_dir/com.clayne.lumen.plist"
/bin/cp "$script_dir/LumenLoginLauncher" "$stage_launcher"
/bin/chmod 0755 "$stage_launcher"

plist_tmp=$(/usr/bin/mktemp "$stage_dir/.com.clayne.lumen.XXXXXX")
trap '/bin/rm -f "$plist_tmp"' EXIT
/usr/bin/sed \
  -e "s|@HOME@|$home_escaped|g" \
  -e "s|@USER@|$user_escaped|g" \
  -e "s|@LAUNCHER_PATH@|$launcher_escaped|g" \
  -e "s|@LUMEN_BIN@|$runtime_escaped|g" \
  -e "s|@LUMEN_CONFIG@|$config_escaped|g" \
  -e "s|@LUMEN_PORT@|$web_port_escaped|g" \
  "$script_dir/com.clayne.lumen.plist.in" > "$stage_plist"
/bin/chmod 0644 "$stage_plist"
/usr/bin/plutil -lint "$stage_plist"

if [[ "$activate" != true ]]; then
  /bin/echo "Staged launcher and plist under: $stage_dir"
  /bin/echo "Live launchd files were not changed. Re-run with --activate after testing."
  exit 0
fi

# Preserve the exact live files before the first activation. rollback.sh can
# restore these files and bootstrap the previous plist if the new runtime fails.
backup_file "$launcher_path" "$backup_dir/LumenLoginLauncher"
backup_file "$plist_path" "$backup_dir/com.clayne.lumen.plist"

/bin/mkdir -p "${launcher_path:h}" "${plist_path:h}"
live_plist_tmp="$plist_path.install-$timestamp-$$"
live_launcher_tmp="$launcher_path.install-$timestamp-$$"
cleanup_temps() {
  /bin/rm -f "$live_launcher_tmp" "$live_plist_tmp"
  /bin/rm -f "$plist_tmp"
}
trap cleanup_temps EXIT
/bin/cp "$stage_launcher" "$live_launcher_tmp"
/bin/chmod 0755 "$live_launcher_tmp"
/bin/cp "$stage_plist" "$live_plist_tmp"
/bin/chmod 0644 "$live_plist_tmp"
/usr/bin/plutil -lint "$live_plist_tmp"
/bin/mv -f "$live_launcher_tmp" "$launcher_path"
/bin/mv -f "$live_plist_tmp" "$plist_path"

uid=$(/usr/bin/id -u)
domain="gui/$uid"
restore_file() {
  local backup="$1"
  local target="$2"
  local mode="$3"
  if [[ -f "$backup" ]]; then
    /bin/cp -p "$backup" "$target"
    /bin/chmod "$mode" "$target"
  elif [[ -f "$backup.absent" ]]; then
    /bin/rm -f "$target"
  else
    return 1
  fi
}

restore_previous_service() {
  local restore_ok=true
  /bin/launchctl bootout "$domain/com.clayne.lumen" 2>/dev/null || true
  if ! restore_file "$backup_dir/LumenLoginLauncher" "$launcher_path" 0755; then
    restore_ok=false
  fi
  if ! restore_file "$backup_dir/com.clayne.lumen.plist" "$plist_path" 0644; then
    restore_ok=false
  fi
  if [[ "$restore_ok" == true && -f "$backup_dir/com.clayne.lumen.plist" ]]; then
    if ! /bin/launchctl bootstrap "$domain" "$plist_path"; then
      restore_ok=false
    elif ! /bin/launchctl enable "$domain/com.clayne.lumen"; then
      restore_ok=false
    fi
  fi
  if [[ "$restore_ok" != true ]]; then
    return 1
  fi
  return 0
}

/bin/launchctl bootout "$domain/com.clayne.lumen" 2>/dev/null || true
if ! /bin/launchctl bootstrap "$domain" "$plist_path" || ! /bin/launchctl enable "$domain/com.clayne.lumen"; then
  /bin/echo "launchd activation failed; restoring the previous service files" >&2
  if ! restore_previous_service; then
    /bin/echo "previous service files could not be restored automatically: $backup_dir" >&2
  fi
  exit 78
fi
/bin/echo "Activated Sunshine launchd job."
/bin/echo "Backup: $backup_dir"
if ! /bin/launchctl print "$domain/com.clayne.lumen" | /usr/bin/sed -n '1,48p'; then
  /bin/echo "launchd job activated; launchctl print was unavailable" >&2
fi
