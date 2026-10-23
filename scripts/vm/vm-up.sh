#!/bin/bash
# Starts the VM with no window on the host, if it isn't already running, and waits for SSH.
# Usage: scripts/vm/vm-up.sh
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
require_tools

vm_exists || die "VM ${VM_NAME} doesn't exist; see One-time setup in docs/vm.md"

started=0
if vm_running; then
  # Use the running VM only if it is the `tart run` that this script started and its VNC
  # server still answers. Otherwise the URL in the log is from an earlier run.
  vm_vnc_url >/dev/null ||
    die "VM ${VM_NAME} is running, but not from a live run of this script, so its VNC address is unknown; stop it with scripts/vm/vm-down.sh, then run this script again"
  tart_pid="$(vm_tart_pid)"
  say "VM ${VM_NAME} is already running (tart pid ${tart_pid})"
else
  say "Starting VM ${VM_NAME} with --no-graphics (log: ${VM_LOG})"
  # --no-graphics keeps tart from opening a VM window on the host. Never drop it.
  # With --no-graphics, --vnc-experimental only prints the VNC URL; tart opens no viewer.
  # vm-screenshot.sh and vm-input.sh read the screen and send input through that server.
  : >"$VM_LOG"
  chmod 600 "$VM_LOG"
  # A non-interactive bash doesn't stop background jobs when it exits, so tart keeps running.
  tart run "$VM_NAME" --no-graphics --vnc-experimental >>"$VM_LOG" 2>&1 </dev/null &
  tart_pid=$!
  started=1
  printf '%s\n' "$tart_pid" >"$VM_PIDFILE"
fi

# If `tart run` has exited, stops with its exit status and the end of its log.
check_tart() {
  kill -0 "$tart_pid" 2>/dev/null && return 0
  local how="exited" code=0
  if (( started )); then
    wait "$tart_pid" || code=$?
    how="exited with status ${code}"
  fi
  rm -f "$VM_PIDFILE"
  printf 'error: tart run %s before VM %s was ready. Last lines of %s:\n' "$how" "$VM_NAME" "$VM_LOG" >&2
  tail -n 20 "$VM_LOG" >&2
  exit 1
}

say "Waiting for the VNC URL"
for _ in {1..60}; do
  check_tart
  vm_vnc_url >/dev/null 2>&1 && break
  sleep 1
done
check_tart
vm_vnc_url >/dev/null || die "tart printed no working VNC URL within 60 seconds; see ${VM_LOG}"

say "Waiting for an IP address"
ip=""
for _ in {1..90}; do
  check_tart
  ip="$(vm_ip)" && [[ -n "$ip" ]] && break
  ip=""
  sleep 2
done
[[ -n "$ip" ]] || die "VM ${VM_NAME} got no IP address within 180 seconds; see ${VM_LOG}"
say "VM IP: ${ip}"

if [[ ! -f "$VM_KEY" ]]; then
  say "Creating SSH key ${VM_KEY}"
  ssh-keygen -q -t ed25519 -N '' -C "${VM_NAME}-vm" -f "$VM_KEY" || die "ssh-keygen failed"
fi

# Reads a public key on stdin and adds it to authorized_keys once. It runs in the VM, so
# its variables expand there.
# shellcheck disable=SC2016
install_key='k=$(cat); mkdir -p ~/.ssh && chmod 700 ~/.ssh &&
  { grep -qxF "$k" ~/.ssh/authorized_keys 2>/dev/null || echo "$k" >> ~/.ssh/authorized_keys; } &&
  chmod 600 ~/.ssh/authorized_keys'

say "Waiting for SSH"
for _ in {1..60}; do
  check_tart
  if vm_ssh true 2>/dev/null; then
    say "SSH is up: ${VM_USER}@${ip}"
    exit 0
  fi
  # Key login fails until the key is in the VM. Install it with the password once SSH answers.
  if vm_ssh_password "$install_key" <"${VM_KEY}.pub" 2>/dev/null; then
    say "Checked that $(basename "$VM_KEY").pub is in the VM's authorized_keys"
  fi
  sleep 2
done
die "SSH to ${VM_USER}@${ip} didn't come up within 120 seconds"
