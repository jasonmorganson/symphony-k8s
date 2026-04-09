#!/usr/bin/env bash
set -euo pipefail

mkdir -p /srv/symphony/workspaces /home/symphony/.ssh /run/sshd
chown -R symphony:symphony /srv/symphony
chmod 2775 /srv/symphony/workspaces
chown symphony:symphony /home/symphony /home/symphony/.ssh

if [[ -f /etc/ssh/authorized-keys/authorized_keys ]]; then
  cp /etc/ssh/authorized-keys/authorized_keys /home/symphony/.ssh/authorized_keys
  chown symphony:symphony /home/symphony/.ssh/authorized_keys
  chmod 600 /home/symphony/.ssh/authorized_keys
fi

chmod 700 /home/symphony/.ssh

exec /usr/sbin/sshd -D -e
