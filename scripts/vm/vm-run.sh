#!/bin/zsh
# Launches the installed app inside the VM's logged-in GUI session and waits for its process.
# Usage: scripts/vm/vm-run.sh [app name, default "VoiceInk Dev"]
set -euo pipefail
source "${0:A:h}/lib.sh"
require_tools

app_name="${1:-$VM_APP_NAME}"
app_path="/Applications/${app_name}.app"

vm_ssh "test -d '${app_path}'" || die "${app_path} isn't installed in VM ${VM_NAME}; run scripts/vm/vm-install-app.sh first"

say "Opening ${app_path} in the VM's GUI session"
vm_gui "open '${app_path}'" || die "open failed for ${app_path}"

for _ in {1..30}; do
  if pid="$(vm_ssh "pgrep -x '${app_name}'" 2>/dev/null)"; then
    say "${app_name} is running in VM ${VM_NAME} (pid ${pid//$'\n'/ })"
    exit 0
  fi
  sleep 1
done
die "${app_name} didn't start within 30 seconds"
