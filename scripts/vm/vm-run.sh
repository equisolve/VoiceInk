#!/bin/bash
# Launches the installed app inside the VM's logged-in GUI session and waits for its process.
# Usage: scripts/vm/vm-run.sh [app name, default "VoiceInk Dev"]
set -euo pipefail
# shellcheck source=scripts/vm/lib.sh
source "$(dirname "$0")/lib.sh"
require_tools

app_name="${1:-${VOICEINK_VM_APP:-VoiceInk Dev}}"
app_path="/Applications/${app_name}.app"

# Quote the names for the VM's shell.
printf -v q_name '%q' "$app_name"
printf -v q_path '%q' "$app_path"

vm_ssh "test -d ${q_path}" || die "${app_path} isn't installed in VM ${VM_NAME}; run scripts/vm/vm-install-app.sh first"

say "Opening ${app_path} in the VM's GUI session"
vm_gui "open ${q_path}" || die "open failed for ${app_path}"

for _ in {1..30}; do
  if pid="$(vm_ssh "pgrep -x ${q_name}" 2>/dev/null)"; then
    say "${app_name} is running in VM ${VM_NAME} (pid ${pid//$'\n'/ })"
    exit 0
  fi
  sleep 1
done
die "${app_name} didn't start within 30 seconds"
