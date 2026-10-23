#!/bin/bash
# Saves a PNG of the VM's screen on the host.
# Usage: scripts/vm/vm-screenshot.sh <out.png>
#
# It reads the VM's framebuffer through the VNC server tart started (see vm-up.sh).
# `screencapture` inside the VM can't work here: it needs the Screen Recording
# permission, and granting that without clicking needs System Integrity Protection off.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
require_tools

(( $# == 1 )) || die "usage: $0 <out.png>"
dir="$(dirname "$1")"
[[ -d "$dir" ]] || die "directory doesn't exist: ${dir}"
dir="$(abs_path "$dir")"
out="${dir}/$(basename "$1")"

say "Capturing the screen of VM ${VM_NAME}"
# Capture to a temporary file so a failed capture leaves any earlier screenshot in place.
tmp="$(mktemp "${dir}/.vm-screenshot.XXXXXX")" || die "can't create a temporary file in ${dir}"
trap 'rm -f "$tmp"' EXIT
vm_vnc screenshot "$tmp" || die "screen capture failed"
[[ -s "$tmp" ]] || die "screenshot is empty"
mv -f "$tmp" "$out" || die "can't write ${out}"
size="$(sips -g pixelWidth -g pixelHeight "$out" | awk '/pixel/ {printf "%s ", $2}')"
say "Saved ${out} (${size% }px)"
