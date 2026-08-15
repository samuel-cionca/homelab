#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "==> $*"
}

install_node_if_missing() {
  export NVM_DIR="$HOME/.nvm"

  if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
    log "Installing nvm"
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.3/install.sh | bash
  fi

  source "$NVM_DIR/nvm.sh"

  if command -v npm >/dev/null 2>&1; then
    log "npm already installed"
  else
    log "Installing Node.js 24.18.0"
    nvm install 24.18.0
    nvm use 24.18.0
  fi
}

install_node_if_missing
