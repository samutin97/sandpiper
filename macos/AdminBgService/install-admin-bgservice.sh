#!/bin/bash
set -euo pipefail

# Installs the VPN service of builds without a Developer ID: the app's own executable, run as
# `Sandpiper --tunnel run` by launchd with administrator rights, which runs the full core. The app
# runs this with an administrator password; by hand:
#   sudo "/Applications/Sandpiper.app/Contents/Resources/TunnelService/install-tunnel-service.sh" \
#     /Applications/Sandpiper.app "$USER"
# The service's label and folders (Application Support/Hiddify/AdminBgService) are the core's
# (adminbgservice, vpnservice.DarwinServiceName) and stay as they are; the executable is the app's:
# Sandpiper since the app was renamed, Hiddify in earlier builds (still removed below).

# task_exe prints the executable of the app bundle $1: Sandpiper, or Hiddify of an earlier build.
task_exe() {
  local name
  for name in Sandpiper Hiddify; do
    if [[ -x "$1/Contents/MacOS/$name" ]]; then
      echo "$1/Contents/MacOS/$name"
      return 0
    fi
  done
  return 1
}

task_source="${1:-}"
task_owner="${2:-${SUDO_USER:-}}"
# Copied app + data live under AdminBgService (matches Go controlDataDir / serviceDataDirectory).
task_destination="/Library/Application Support/Hiddify/AdminBgService/Hiddify.app"

if [[ "$(id -u)" != 0 ]]; then
  echo 'error: run this script with sudo.' >&2
  exit 1
fi
if [[ ! -x "$task_source/Contents/MacOS/Sandpiper" ]]; then
  echo 'error: pass the path of Sandpiper.app.' >&2
  exit 1
fi

# The root helper of earlier builds.
launchctl bootout system/com.hiddify.tunnel-helper 2>/dev/null || true
rm -f /Library/LaunchDaemons/com.hiddify.tunnel-helper.plist /Library/PrivilegedHelperTools/com.hiddify.tunnel-helper \
  /var/run/hiddify-tunnel-helper.sock
rm -rf "/Library/Application Support/Hiddify/TunnelHelper"

task_legacy="/Library/Application Support/Hiddify/TunnelService/Hiddify.app"
for task_existing in "$task_destination" "$task_legacy"; do
  if task_existing_exe="$(task_exe "$task_existing")"; then
    "$task_existing_exe" --tunnel uninstall || true
  fi
done
# A root daemon must not run files its user can change, so it runs a root-owned copy of the app.
rm -rf "$task_destination" "/Library/Application Support/Hiddify/TunnelService"
mkdir -p "$(dirname "$task_destination")"
ditto "$task_source" "$task_destination"
xattr -cr "$task_destination"
chown -R root:wheel "$task_destination"
chmod -R go-w "$task_destination"
# Create the control secret for the installing user before the daemon starts listening.
export HIDDIFY_TUNNEL_OWNER="$task_owner"
export HIDDIFY_ADMIN_BG_OWNER="$task_owner"
"$task_destination/Contents/MacOS/Sandpiper" --tunnel install
echo 'Sandpiper VPN service installed.'
