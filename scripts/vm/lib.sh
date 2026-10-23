# Shared settings and helpers for the scripts in scripts/vm. Source this file; don't run it.
# See docs/vm.md.

VM_SCRIPTS_DIR="${${(%):-%x}:A:h}"
VM_NAME="${VOICEINK_VM:-voiceink}"
VM_USER="${VOICEINK_VM_USER:-admin}"
VM_PASSWORD="${VOICEINK_VM_PASSWORD:-admin}"
VM_APP_NAME="${VOICEINK_VM_APP:-VoiceInk Dev}"
VM_BUNDLE_ID="${VOICEINK_VM_BUNDLE_ID:-com.prakashjoshipax.VoiceInk.dev}"
VM_LOG="${HOME}/.tart/${VM_NAME}-run.log"
VM_PIDFILE="${HOME}/.tart/${VM_NAME}-run.pid"

die() {
  print -u2 -- "error: $*"
  exit 1
}

say() {
  print -- "$*"
}

require_tools() {
  command -v tart >/dev/null 2>&1 || die "tart is not installed; see docs/vm.md"
  command -v sshpass >/dev/null 2>&1 || die "sshpass is not installed; run: brew install sshpass"
}

vm_exists() {
  tart list --quiet 2>/dev/null | grep -qx -- "$VM_NAME"
}

vm_running() {
  # The last column of `tart list` is the state.
  tart list --source local 2>/dev/null | awk -v n="$VM_NAME" '$2 == n && $NF == "running" { found = 1 } END { exit !found }'
}

vm_ip() {
  tart ip "$VM_NAME" 2>/dev/null
}

# A key used only for this VM. vm-up.sh creates it and installs it in the VM.
VM_KEY="${HOME}/.tart/${VM_NAME}_ed25519"

SSH_BASE_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)
# Offer only the VM key. Keys from the host's SSH agent use up the server's login attempts.
SSH_OPTS=("${SSH_BASE_OPTS[@]}" -i "$VM_KEY" -o IdentitiesOnly=yes -o IdentityAgent=none
  -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o BatchMode=yes)

# Runs a command in the VM over SSH as the admin user, with the VM key.
vm_ssh() {
  local ip
  ip="$(vm_ip)" || die "can't get the IP of VM ${VM_NAME}; is it running? Run scripts/vm/vm-up.sh"
  ssh "${SSH_OPTS[@]}" "${VM_USER}@${ip}" "$@"
}

# Runs a command in the VM over SSH with the password. Used only to install the VM key.
vm_ssh_password() {
  local ip
  ip="$(vm_ip)" || die "can't get the IP of VM ${VM_NAME}"
  SSHPASS="$VM_PASSWORD" sshpass -e ssh "${SSH_BASE_OPTS[@]}" -o IdentityAgent=none -o PubkeyAuthentication=no \
    -o PreferredAuthentications=password,keyboard-interactive "${VM_USER}@${ip}" "$@"
}

# Copies a file from the VM to the host: vm_scp_from <remote path> <local path>
vm_scp_from() {
  local ip
  ip="$(vm_ip)" || die "can't get the IP of VM ${VM_NAME}"
  scp -q "${SSH_OPTS[@]}" "${VM_USER}@${ip}:$1" "$2"
}

# Prints the PID of the `tart run` process that vm-up.sh started, if it is still running.
# Fails when the PID file is missing, the process has exited, or the PID now belongs to
# another program, so a log left over from an earlier run is never trusted.
vm_tart_pid() {
  local pid args
  [[ -r "$VM_PIDFILE" ]] || return 1
  pid="$(<"$VM_PIDFILE")"
  [[ "$pid" == <-> ]] || return 1
  args="$(ps -p "$pid" -o args= 2>/dev/null)" || return 1
  [[ "$args" == *tart*" run ${VM_NAME} "* ]] || return 1
  print -- "$pid"
}

# Prints the VNC URL of the running VM. The URL comes from the run log of the `tart run`
# process that vm-up.sh started, and only while that process is alive and listening on
# the URL's port.
vm_vnc_url() {
  local url port
  vm_tart_pid >/dev/null || return 1
  url="$(grep -o 'vnc://[^ ]*' "$VM_LOG" 2>/dev/null | tail -1)"
  [[ -n "$url" ]] || return 1
  url="${url%...}"
  port="${url##*:}"
  [[ "$port" == <-> ]] || return 1
  lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 || return 1
  print -- "$url"
}

# Runs the VNC client (scripts/vm/vm-vnc.swift), compiling it first if needed.
vm_vnc() {
  local src="${VM_SCRIPTS_DIR}/vm-vnc.swift" bin="${HOME}/.tart/vm-vnc" url
  if [[ ! -x "$bin" || "$src" -nt "$bin" ]]; then
    say "Compiling ${src:t}"
    swiftc -O "$src" -o "$bin" || die "couldn't compile ${src}"
  fi
  url="$(vm_vnc_url)" || die "no live VNC server for VM ${VM_NAME}; restart the VM with scripts/vm/vm-down.sh and scripts/vm/vm-up.sh"
  "$bin" "$url" "$@"
}

# Runs a command in the VM's logged-in GUI session (Aqua), as the admin user.
# Plain SSH commands run outside that session, so apps they open and screenshots
# they take don't see the desktop.
vm_gui() {
  local cmd="$1"
  vm_ssh "uid=\$(id -u ${VM_USER}); echo '${VM_PASSWORD}' | sudo -S -p '' launchctl asuser \$uid sudo -u ${VM_USER} ${cmd}"
}
