#!/bin/zsh
# Saves a PNG of the VM's screen on the host.
# Usage: scripts/vm/vm-screenshot.sh <out.png>
#
# It reads the VM's framebuffer through the VNC server tart started (see vm-up.sh).
# `screencapture` inside the VM can't work here: it needs the Screen Recording
# permission, and granting that without clicking needs System Integrity Protection off.
set -euo pipefail
source "${0:A:h}/lib.sh"
require_tools

(( $# == 1 )) || die "usage: $0 <out.png>"
out="${1:A}"
[[ -d "${out:h}" ]] || die "directory doesn't exist: ${out:h}"

say "Capturing the screen of VM ${VM_NAME}"
rm -f "$out"
vm_vnc screenshot "$out" || die "screen capture failed"
[[ -s "$out" ]] || die "screenshot is empty: ${out}"
say "Saved ${out} ($(sips -g pixelWidth -g pixelHeight "$out" | awk '/pixel/ {printf "%s ", $2}')px)"
