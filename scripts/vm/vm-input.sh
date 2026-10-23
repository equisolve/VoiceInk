#!/bin/bash
# Sends a mouse click, text, or a key combination to the VM's screen.
# Usage:
#   scripts/vm/vm-input.sh click <x> <y>     Coordinates are pixels in a vm-screenshot.sh PNG.
#   scripts/vm/vm-input.sh type <text>
#   scripts/vm/vm-input.sh key <combo>       For example: return, escape, tab, cmd+q, cmd+comma
#
# Input goes in through the VM's virtual keyboard and mouse, so the guest needs no
# Accessibility permission.
set -euo pipefail
# shellcheck source=scripts/vm/lib.sh
source "$(dirname "$0")/lib.sh"
require_tools

(( $# >= 2 )) || die "usage: $0 click <x> <y> | type <text> | key <combo>"
vm_vnc "$@" || die "couldn't send input: $*"
say "Sent $*"
