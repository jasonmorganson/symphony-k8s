#!/usr/bin/env sh
set -eu

install_codex_cli() {
  npm install -g @openai/codex

  codex_js="/usr/local/lib/node_modules/@openai/codex/bin/codex.js"
  test -f "$codex_js"

  rm -f /usr/local/bin/codex
  printf '%s\n' '#!/bin/sh' "exec node \"$codex_js\" \"\$@\"" > /usr/local/bin/codex
  chmod 0755 /usr/local/bin/codex
  chown root:root /usr/local/bin/codex
}

setup_symphony_user() {
  useradd --create-home --shell /bin/bash --uid 10001 symphony
  passwd -d symphony
  mkdir -p /home/symphony/.ssh
  chown -R symphony:symphony /home/symphony
}

ensure_symphony_dirs() {
  mkdir -p /home/symphony/.ssh /srv/symphony/workspaces
  chown -R symphony:symphony /home/symphony /srv/symphony
}
