#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
verification_root="/Users/junkawasaki/github/workspaces/codex/murakumo-kekkai-verification"
mkdir -p "$verification_root"
e2e_dir="$(mktemp -d "$verification_root/bootstrap-ssh-e2e.XXXXXX")"
sshd_dir="$(mktemp -d "$verification_root/bootstrap-sshd.XXXXXX")"
chmod 700 "$e2e_dir" "$sshd_dir"
sshd_pid=""

cleanup() {
  if [[ -n "$sshd_pid" ]]; then
    kill "$sshd_pid" 2>/dev/null || true
    wait "$sshd_pid" 2>/dev/null || true
  fi
  rm -rf "$e2e_dir" "$sshd_dir"
}
trap cleanup EXIT INT TERM

ssh_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
ssh_user="$(id -un)"
ssh_key="$sshd_dir/client_ed25519"
host_key="$sshd_dir/host_ed25519"

ssh-keygen -q -t ed25519 -N '' -f "$ssh_key"
ssh-keygen -q -t ed25519 -N '' -f "$host_key"
cat "$ssh_key.pub" > "$sshd_dir/authorized_keys"
chmod 600 "$sshd_dir/authorized_keys" "$ssh_key" "$host_key"

cat > "$sshd_dir/sshd_config" <<EOF
AddressFamily inet
ListenAddress 127.0.0.1
Port $ssh_port
HostKey $host_key
PidFile $sshd_dir/sshd.pid
AuthorizedKeysFile $sshd_dir/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
PermitRootLogin no
AllowUsers $ssh_user
StrictModes no
UsePAM no
AllowTcpForwarding no
X11Forwarding no
LogLevel ERROR
EOF

/usr/sbin/sshd -t -f "$sshd_dir/sshd_config"
/usr/sbin/sshd -D -e -f "$sshd_dir/sshd_config" > "$sshd_dir/sshd.log" 2>&1 &
sshd_pid=$!

sshd_ready=""
for _ in {1..50}; do
  if nc -z -w 1 127.0.0.1 "$ssh_port" >/dev/null 2>&1; then
    sshd_ready=1
    break
  fi
  if ! kill -0 "$sshd_pid" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
if [[ -z "$sshd_ready" ]]; then
  cat "$sshd_dir/sshd.log"
  echo "temporary localhost sshd did not start" >&2
  exit 1
fi

ssh -p "$ssh_port" -i "$ssh_key" \
  -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o LogLevel=ERROR \
  "$ssh_user@127.0.0.1" 'printf KEKKAI_LOCAL_SSHD_OK' | rg -q KEKKAI_LOCAL_SSHD_OK

cd "$repo_root"
if ! KEKKAI_BOOTSTRAP_E2E=1 \
KEKKAI_BOOTSTRAP_E2E_DIR="$e2e_dir" \
KEKKAI_BOOTSTRAP_SSH_PORT="$ssh_port" \
KEKKAI_BOOTSTRAP_SSH_KEY="$ssh_key" \
USER="$ssh_user" \
kbb --backend sci --classpath "src:test:/Users/junkawasaki/github/kotoba-lang/bytes/src:/Users/junkawasaki/github/kotoba-lang/noise/src:/Users/junkawasaki/github/kotoba-lang/org-ietf-dns/src:/Users/junkawasaki/github/kotoba-lang/org-ietf-turn/src" \
  test/bootstrap_e2e.cljk; then
  cat "$sshd_dir/sshd.log"
  exit 1
fi
