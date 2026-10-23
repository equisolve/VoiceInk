#!/bin/zsh
# Copies a host-built app bundle into the VM's /Applications, replacing any old copy.
# Usage: scripts/vm/vm-install-app.sh <path-to-.app>
set -euo pipefail
source "${0:A:h}/lib.sh"
require_tools

(( $# == 1 )) || die "usage: $0 <path-to-.app>"
app="${1:A}"
[[ -d "$app" && "$app" == *.app ]] || die "not an app bundle: $1"
name="${app:t}"

# Quit a running copy first so the bundle can be replaced.
vm_ssh "pkill -x '${name%.app}' >/dev/null 2>&1; true"

say "Copying ${name} into /Applications in VM ${VM_NAME}"
tar -C "${app:h}" -cf - "$name" | vm_ssh "rm -rf '/Applications/${name}' && tar -C /Applications -xf -" \
  || die "copy failed"

vm_ssh "test -x '/Applications/${name}/Contents/MacOS/${name%.app}'" \
  || die "/Applications/${name} in the VM has no executable at Contents/MacOS/${name%.app}"
say "Installed /Applications/${name} in VM ${VM_NAME}"
