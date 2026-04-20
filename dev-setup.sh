#!/usr/bin/env bash
#
# Dev tools installer for a hardened Hetzner VPS (Ubuntu 24.04).
# Run as your non-root user (e.g. alex) AFTER harden-vps.sh.
#
# Installs:
#   - Node.js LTS (for Claude Code)
#   - Claude Code
#   - Go (latest stable)
#   - Docker CE + compose plugin
#   - kubectl, helm, stern
#   - Neovim (latest stable via PPA)
#   - Fish shell (latest stable via PPA)
#   - Starship prompt (configured for bash AND fish)
#   - GitHub CLI (gh)
#   - chezmoi (dotfiles manager) — optionally inits from your dotfiles repo
#   - Playwright system deps (via npx when you install it per-project)
#   - 4 GB swap file
#
# To auto-init your dotfiles on first run, set DOTFILES_REPO below.
#
# Usage:
#   scp dev-setup.sh alex@<server>:~
#   ssh alex@<server> "bash ~/dev-setup.sh"
#
# Idempotent — safe to re-run.

set -euo pipefail

log()  { printf '\n\033[1;34m[+]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "Run as your non-root user, not root."
command -v sudo >/dev/null || die "sudo required."

export DEBIAN_FRONTEND=noninteractive

# ─── CONFIG ────────────────────────────────────────────────────────────────────
# Set this to your dotfiles repo to auto-apply on first run.
# Examples:
#   DOTFILES_REPO="https://github.com/lefteris/dotfiles.git"
#   DOTFILES_REPO="git@github.com:lefteris/dotfiles.git"   # requires SSH key on this box
#   DOTFILES_REPO=""                                        # skip auto-apply
DOTFILES_REPO="${DOTFILES_REPO:-}"
# ───────────────────────────────────────────────────────────────────────────────

# ─── 1. Baseline build deps ────────────────────────────────────────────────────
log "Installing baseline build tools..."
sudo apt-get update -qq
sudo apt-get -qq -y install \
    build-essential pkg-config libssl-dev \
    zsh fzf ripgrep fd-find bat jq yq \
    apt-transport-https ca-certificates gnupg lsb-release \
    software-properties-common python3-pip python3-venv \
    unzip tree ncdu

# ─── 2. Swap file (4 GB) ───────────────────────────────────────────────────────
if ! swapon --show | grep -q /swapfile; then
    log "Creating 4 GB swap file..."
    sudo fallocate -l 4G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
    # Prefer not to swap unless necessary
    echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swappiness.conf >/dev/null
    sudo sysctl -p /etc/sysctl.d/99-swappiness.conf >/dev/null
else
    log "Swap already configured."
fi

# ─── 3. Node.js LTS (via NodeSource) ───────────────────────────────────────────
if ! command -v node >/dev/null || [[ "$(node -v | cut -d. -f1)" < "v20" ]]; then
    log "Installing Node.js LTS..."
    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
    sudo apt-get -qq -y install nodejs
else
    log "Node.js $(node -v) already installed."
fi

# ─── 4. Claude Code ────────────────────────────────────────────────────────────
if ! command -v claude >/dev/null; then
    log "Installing Claude Code..."
    # Configure npm to use a user-owned global prefix (avoids sudo for global installs)
    mkdir -p "$HOME/.npm-global"
    npm config set prefix "$HOME/.npm-global"
    if ! grep -q '.npm-global/bin' "$HOME/.bashrc"; then
        echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> "$HOME/.bashrc"
    fi
    export PATH="$HOME/.npm-global/bin:$PATH"
    npm install -g @anthropic-ai/claude-code
else
    log "Claude Code already installed."
fi

# ─── 5. Go (latest stable, via official tarball) ───────────────────────────────
GO_VERSION="1.23.4"
if ! command -v go >/dev/null || [[ "$(go version | awk '{print $3}')" != "go${GO_VERSION}" ]]; then
    log "Installing Go ${GO_VERSION}..."
    ARCH="$(dpkg --print-architecture)"
    case "$ARCH" in
        amd64) GO_ARCH=amd64 ;;
        arm64) GO_ARCH=arm64 ;;
        *) die "Unsupported arch: $ARCH" ;;
    esac
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz" -o /tmp/go.tar.gz
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf /tmp/go.tar.gz
    rm /tmp/go.tar.gz
    if ! grep -q '/usr/local/go/bin' "$HOME/.bashrc"; then
        cat >> "$HOME/.bashrc" <<'EOF'
export PATH="/usr/local/go/bin:$PATH"
export PATH="$HOME/go/bin:$PATH"
EOF
    fi
    export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"
else
    log "Go $(go version | awk '{print $3}') already installed."
fi

# ─── 6. Docker CE + compose plugin ─────────────────────────────────────────────
if ! command -v docker >/dev/null; then
    log "Installing Docker CE..."
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get -qq -y install docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
    sudo usermod -aG docker "$USER"
    warn "Added $USER to docker group — log out and back in for this to take effect."
else
    log "Docker already installed."
fi

# ─── 7. kubectl ────────────────────────────────────────────────────────────────
if ! command -v kubectl >/dev/null; then
    log "Installing kubectl..."
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | \
        sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | \
        sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get -qq -y install kubectl
else
    log "kubectl already installed."
fi

# ─── 8. Helm ───────────────────────────────────────────────────────────────────
if ! command -v helm >/dev/null; then
    log "Installing Helm..."
    curl -fsSL https://baltocdn.com/helm/signing.asc | \
        sudo gpg --dearmor -o /etc/apt/keyrings/helm.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" | \
        sudo tee /etc/apt/sources.list.d/helm-stable-debian.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get -qq -y install helm
else
    log "Helm already installed."
fi

# ─── 9. stern (multi-pod log tailing) ──────────────────────────────────────────
if ! command -v stern >/dev/null; then
    log "Installing stern..."
    STERN_VERSION="1.30.0"
    ARCH="$(dpkg --print-architecture)"
    curl -fsSL "https://github.com/stern/stern/releases/download/v${STERN_VERSION}/stern_${STERN_VERSION}_linux_${ARCH}.tar.gz" | \
        sudo tar -xz -C /usr/local/bin stern
    sudo chmod +x /usr/local/bin/stern
else
    log "stern already installed."
fi

# ─── 10. Neovim (latest stable via official PPA) ───────────────────────────────
if ! command -v nvim >/dev/null || ! nvim --version | head -1 | grep -qE 'v0\.(1[0-9]|[2-9][0-9])'; then
    log "Installing Neovim (stable PPA)..."
    sudo add-apt-repository -y ppa:neovim-ppa/stable
    sudo apt-get update -qq
    sudo apt-get -qq -y install neovim
else
    log "Neovim already installed."
fi

# ─── 10b. GitHub CLI ───────────────────────────────────────────────────────────
if ! command -v gh >/dev/null; then
    log "Installing GitHub CLI..."
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | \
        sudo dd of=/etc/apt/keyrings/githubcli-archive-keyring.gpg
    sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | \
        sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get -qq -y install gh
else
    log "gh already installed."
fi

# ─── 10c. Fish shell ───────────────────────────────────────────────────────────
if ! command -v fish >/dev/null; then
    log "Installing Fish shell..."
    sudo add-apt-repository -y ppa:fish-shell/release-3
    sudo apt-get update -qq
    sudo apt-get -qq -y install fish
    # Fish config dir + PATH for installed tools
    mkdir -p "$HOME/.config/fish/conf.d"
    cat > "$HOME/.config/fish/conf.d/00-paths.fish" <<'EOF'
# Managed by dev-setup.sh — PATH entries for installed tools
fish_add_path -g $HOME/.local/bin
fish_add_path -g $HOME/.npm-global/bin
fish_add_path -g $HOME/go/bin
fish_add_path -g /usr/local/go/bin
EOF
else
    log "Fish already installed."
fi

# ─── 11. Starship prompt ───────────────────────────────────────────────────────
if ! command -v starship >/dev/null; then
    log "Installing Starship..."
    curl -fsSL https://starship.rs/install.sh | sh -s -- --yes
else
    log "Starship already installed."
fi

# Add starship init to bashrc if not already there
if ! grep -q 'starship init bash' "$HOME/.bashrc"; then
    echo 'eval "$(starship init bash)"' >> "$HOME/.bashrc"
fi

# Add starship init for fish if fish is installed
if command -v fish >/dev/null; then
    mkdir -p "$HOME/.config/fish/conf.d"
    if [[ ! -f "$HOME/.config/fish/conf.d/starship.fish" ]]; then
        echo 'starship init fish | source' > "$HOME/.config/fish/conf.d/starship.fish"
    fi
fi

# Minimal starship config — edit to taste
mkdir -p "$HOME/.config"
if [[ ! -f "$HOME/.config/starship.toml" ]]; then
    cat > "$HOME/.config/starship.toml" <<'EOF'
# Starship config — https://starship.rs/config/
add_newline = true
command_timeout = 1000

format = """
$username\
$hostname\
$directory\
$git_branch\
$git_status\
$kubernetes\
$golang\
$nodejs\
$docker_context\
$line_break\
$character"""

[character]
success_symbol = "[╰─λ](bold green)"
error_symbol   = "[╰─λ](bold red)"

[hostname]
ssh_only = true
format = "[@$hostname](bold yellow) "

[directory]
truncation_length = 3
style = "bold cyan"

[git_branch]
symbol = " "
style = "bold purple"

[git_status]
style = "bold red"

[kubernetes]
disabled = false
format = '[⎈ $context](bold blue) '

[golang]
symbol = " "

[nodejs]
symbol = " "
EOF
fi

# ─── 12. chezmoi (dotfiles manager) ────────────────────────────────────────────
if ! command -v chezmoi >/dev/null; then
    log "Installing chezmoi..."
    # Official installer — drops binary in ~/.local/bin
    sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin"
    if ! grep -q '.local/bin' "$HOME/.bashrc"; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
    fi
    export PATH="$HOME/.local/bin:$PATH"
else
    log "chezmoi already installed."
fi

# Optionally init dotfiles if a repo is configured
if [[ -n "$DOTFILES_REPO" ]] && [[ ! -d "$HOME/.local/share/chezmoi" ]]; then
    log "Initializing dotfiles from $DOTFILES_REPO..."
    if chezmoi init --apply "$DOTFILES_REPO"; then
        log "Dotfiles applied."
    else
        warn "chezmoi init failed. Run manually later: chezmoi init --apply $DOTFILES_REPO"
    fi
elif [[ -n "$DOTFILES_REPO" ]]; then
    log "chezmoi source dir already exists — skipping init. Run 'chezmoi update' to pull latest."
else
    log "DOTFILES_REPO not set — skipping dotfiles init. To apply later:"
    log "    chezmoi init --apply <your-repo-url>"
fi

# ─── 13. Playwright system deps (optional but nice to pre-install) ─────────────
log "Installing Playwright Chromium system deps..."
# This pulls the OS-level libs Playwright needs (libnss, libatk, fonts, etc.)
# so that `npx playwright install` in your projects is fast. Doesn't install
# the browsers themselves — do that per-project.
sudo apt-get -qq -y install \
    libnss3 libatk1.0-0t64 libatk-bridge2.0-0t64 libcups2t64 libxkbcommon0 \
    libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 libasound2t64 \
    libpango-1.0-0 libcairo2 fonts-liberation fonts-noto-color-emoji \
    libdrm2 libxshmfence1 libgtk-3-0t64 || \
    warn "Some Playwright deps may have different names on this Ubuntu version. Run 'npx playwright install-deps' from your project for the authoritative set."

# ─── Summary ───────────────────────────────────────────────────────────────────
cat <<EOF

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Dev tools installed. Versions:

    Node.js:   $(node -v 2>/dev/null || echo "not found")
    Go:        $(go version 2>/dev/null | awk '{print $3}' || echo "not found")
    Docker:    $(docker --version 2>/dev/null | awk '{print $3}' | tr -d , || echo "not found — relog for group")
    kubectl:   $(kubectl version --client 2>/dev/null | grep -oP 'v\d+\.\d+\.\d+' | head -1 || echo "not found")
    helm:      $(helm version --short 2>/dev/null || echo "not found")
    stern:     $(stern --version 2>/dev/null | head -1 | awk '{print \$2}' || echo "not found")
    nvim:      $(nvim --version 2>/dev/null | head -1 | awk '{print \$2}' || echo "not found")
    fish:      $(fish --version 2>/dev/null | awk '{print \$3}' || echo "not found")
    gh:        $(gh --version 2>/dev/null | head -1 | awk '{print \$3}' || echo "not found")
    starship:  $(starship --version 2>/dev/null | head -1 | awk '{print \$2}' || echo "not found")
    chezmoi:   $(chezmoi --version 2>/dev/null | grep -oP 'v\d+\.\d+\.\d+' | head -1 || echo "not found")
    claude:    $(claude --version 2>/dev/null || echo "not found")

  Next:
    1. Log out and log back in (picks up docker group + PATH changes)
    2. Run 'claude' to authenticate Claude Code
    3. Run 'gh auth login' to authenticate GitHub CLI
    4. To make fish your default shell: chsh -s \$(which fish)
       (then log out and back in)
    5. For Playwright projects: 'npx playwright install --with-deps'

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
