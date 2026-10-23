#!/bin/zsh
# Starts the VM with no window on the host, if it isn't already running, and waits for SSH.
# Usage: scripts/vm/vm-up.sh
set -euo pipefail
source "${0:A:h}/lib.sh"
require_tools

vm_exists || die "VM ${VM_NAME} doesn't exist; see One-time setup in docs/vm.md"

if vm_running; then
  say "VM ${VM_NAME} is already running"
else
  say "Starting VM ${VM_NAME} with --no-graphics (log: ${VM_LOG})"
  # --no-graphics keeps tart from opening a VM window on the host. Never drop it.
  # With --no-graphics, --vnc-experimental only prints the VNC URL; tart opens no viewer.
  # vm-screenshot.sh and vm-input.sh read the screen and send input through that server.
  : >"$VM_LOG"
  chmod 600 "$VM_LOG"
  tart run "$VM_NAME" --no-graphics --vnc-experimental >>"$VM_LOG" 2>&1 </dev/null &!
fi

say "Waiting for the VNC URL"
for _ in {1..60}; do
  vm_vnc_url >/dev/null 2>&1 && break
  sleep 1
done
vm_vnc_url >/dev/null || die "tart printed no VNC URL; start the VM with this script, not plain tart run (log: ${VM_LOG})"

say "Waiting for an IP address"
ip="$(tart ip "$VM_NAME" --wait 180)" || die "VM ${VM_NAME} got no IP address within 180 seconds; see ${VM_LOG}"
say "VM IP: ${ip}"

if [[ ! -f "$VM_KEY" ]]; then
  say "Creating SSH key ${VM_KEY}"
  ssh-keygen -q -t ed25519 -N '' -C "${VM_NAME}-vm" -f "$VM_KEY" || die "ssh-keygen failed"
fi

say "Waiting for SSH"
for _ in {1..60}; do
  if vm_ssh true 2>/dev/null; then
    say "SSH is up: ${VM_USER}@${ip}"
    exit 0
  fi
  # Key login fails until the key is in the VM. Install it with the password once SSH answers.
  if vm_ssh_password 'k=$(cat); mkdir -p ~/.ssh && chmod 700 ~/.ssh &&
      { grep -qxF "$k" ~/.ssh/authorized_keys 2>/dev/null || echo "$k" >> ~/.ssh/authorized_keys; } &&
      chmod 600 ~/.ssh/authorized_keys' <"${VM_KEY}.pub" 2>/dev/null; then
    say "Checked that ${VM_KEY:t}.pub is in the VM's authorized_keys"
  fi
  sleep 2
done
die "SSH to ${VM_USER}@${ip} didn't come up within 120 seconds"
