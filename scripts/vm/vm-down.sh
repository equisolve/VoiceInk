#!/bin/bash
# Stops the VM.
# Usage: scripts/vm/vm-down.sh
set -euo pipefail
# shellcheck source=scripts/vm/lib.sh
source "$(dirname "$0")/lib.sh"
require_tools

if ! vm_running; then
  say "VM ${VM_NAME} is not running"
  exit 0
fi

say "Stopping VM ${VM_NAME}"
tart stop "$VM_NAME" --timeout 60 || die "tart stop failed for ${VM_NAME}"
vm_running && die "VM ${VM_NAME} is still running after tart stop"
rm -f "$VM_PIDFILE"
say "VM ${VM_NAME} stopped"
