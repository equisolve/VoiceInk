#!/bin/bash
# Copies a host-built app bundle into the VM's /Applications, replacing any old copy.
# Usage: scripts/vm/vm-install-app.sh <path-to-.app>
set -euo pipefail
# shellcheck source=scripts/vm/lib.sh
source "$(dirname "$0")/lib.sh"
require_tools

(( $# == 1 )) || die "usage: $0 <path-to-.app>"
[[ -d "$1" ]] || die "not an app bundle: $1"
app="$(abs_path "$1")"
[[ "$app" == *.app ]] || die "not an app bundle: $1"
name="$(basename "$app")"
exe="${name%.app}"

# Quote the names for the VM's shell.
printf -v q_name '%q' "$name"
printf -v q_exe '%q' "$exe"

# Quit a running copy first so the bundle can be replaced.
vm_ssh "pkill -x ${q_exe} >/dev/null 2>&1; true"

say "Copying ${name} into /Applications in VM ${VM_NAME}"
tar -C "$(dirname "$app")" -cf - "$name" | vm_ssh "rm -rf /Applications/${q_name} && tar -C /Applications -xf -" \
  || die "copy failed"

vm_ssh "test -x /Applications/${q_name}/Contents/MacOS/${q_exe}" \
  || die "/Applications/${name} in the VM has no executable at Contents/MacOS/${exe}"
say "Installed /Applications/${name} in VM ${VM_NAME}"
