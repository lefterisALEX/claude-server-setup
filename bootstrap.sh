#!/usr/bin/env bash
# Bootstrap: installs Ansible on the server and runs ansible-pull.
#
# Phase 1 — run as root after creating the server:
#   REPO_URL=https://github.com/you/dev-server-setup bash bootstrap.sh harden
#
# Phase 2 — run as your non-root user after hardening:
#   REPO_URL=https://github.com/you/dev-server-setup bash bootstrap.sh devtools

set -euo pipefail

REPO_URL="${REPO_URL:-}"
PLAY="${1:-}"

[[ -n "$REPO_URL" ]] || { echo "Error: set REPO_URL before running."; exit 1; }
[[ -n "$PLAY" ]]     || { echo "Usage: REPO_URL=<url> $0 <harden|devtools>"; exit 1; }

if ! command -v ansible-pull >/dev/null; then
    sudo apt-get update -qq
    sudo apt-get install -y ansible git
fi

ansible-pull -U "$REPO_URL" "${PLAY}.yml"
