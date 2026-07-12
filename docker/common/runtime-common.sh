#!/usr/bin/env sh
set -eu

install_codex_cli() {
  npm install -g @openai/codex@0.144.1

  codex_js="/usr/local/lib/node_modules/@openai/codex/bin/codex.js"
  test -f "$codex_js"

  rm -f /usr/local/bin/codex
  printf '%s\n' '#!/bin/sh' "exec node \"$codex_js\" \"\$@\"" > /usr/local/bin/codex
  chmod 0755 /usr/local/bin/codex
  chown root:root /usr/local/bin/codex
}

install_mise() {
  mise_version="${MISE_VERSION:-2026.7.5}"

  case "$(dpkg --print-architecture)" in
    amd64)
      mise_arch="x64"
      mise_sha="5f7ab76afdf0780d12edeaa67e908094e9ccf7924cfe203e415c1cfb87bbf778"
      ;;
    arm64)
      mise_arch="arm64"
      mise_sha="41fcf744050bfa27f9871e2151ac6f44b5ce2741424b3d5282b92becc71e6bc4"
      ;;
    *) echo "Unsupported mise architecture" >&2; return 1 ;;
  esac

  curl -fsSL \
    "https://github.com/jdx/mise/releases/download/v${mise_version}/mise-v${mise_version}-linux-${mise_arch}" \
    -o /usr/local/bin/mise
  echo "${mise_sha}  /usr/local/bin/mise" | sha256sum --check --strict
  chmod 0755 /usr/local/bin/mise
  chown root:root /usr/local/bin/mise
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
