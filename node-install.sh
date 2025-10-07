#!/usr/bin/env bash
set -euo pipefail

# Load nvm into this non-interactive shell
export NVM_DIR="$HOME/.nvm"
# shellcheck source=/dev/null
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

# Remove the bad install
nvm uninstall 23.3.0 || true
nvm cache clear || true

# Install LTS and set it as default for new shells
nvm install --lts
nvm alias default lts/*
nvm use default

# Sanity check
which node
node -v
