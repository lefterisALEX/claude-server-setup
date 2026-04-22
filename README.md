# Hetzner VPS Setup for Claude Code

End-to-end guide for a hardened Hetzner VPS running Claude Code, Playwright, Go tests, and related dev tooling.

## Architecture overview

- **Server**: Hetzner CPX32 (AMD Genoa, 4 vCPU, 8 GB, 160 GB NVMe) — Ubuntu 24.04
- **SSH**: port 2222, keys only, non-root user `alex` with sudo (password set)
- **Network access**: Tailscale for normal use, public SSH closed at Hetzner firewall
- **Fallbacks** (in order): Tailscale → Hetzner web console (password) → rescue mode
- **Config management**: Ansible via `ansible-pull` — no controller needed, server self-configures from this repo

## Sizing rationale

- **CPX22** (2 vCPU / 4 GB) — too small once Playwright spins up 3+ browsers alongside Go tests
- **CPX32** (4 vCPU / 8 GB) — sweet spot for this workload
- **CCX13** (dedicated vCPU) — consider if Playwright timing flakiness becomes an issue
- **CAX21** (ARM / 4 vCPU / 8 GB) — cheaper alternative, works fine for Go + Playwright

## Files

| File | Purpose |
|------|---------|
| `vars.yml` | All configuration — edit this before running |
| `harden.yml` | Ansible playbook: OS hardening (run as root) |
| `devtools.yml` | Ansible playbook: dev tool installation (run as non-root user) |
| `cloud-init.yml` | cloud-init config: installs ansible+git on first boot |
| `bootstrap.sh` | Tiny bootstrap: installs Ansible, then runs `ansible-pull` |
| `templates/` | Jinja2 templates for sshd and fail2ban config |

## Configuration

Edit `vars.yml` before pushing the repo:

```yaml
new_user: alex          # your non-root username
ssh_port: 2222          # SSH port
ssh_pubkey: ""          # paste your SSH public key, or leave empty to copy from root
timezone: Europe/Amsterdam
auto_reboot_time: "03:00"
go_version: "1.23.4"
stern_version: "1.30.0"
dotfiles_repo: ""       # optional: https://github.com/you/dotfiles.git
```

## Step 1 — Create the server

```bash
SERVER_IP=$(hcloud server create \
  --name claude \
  --image ubuntu-24.04 \
  --type cpx32 \
  --location nbg1 \
  --ssh-key lefteris \
  --user-data-from-file <(curl -fsSL https://raw.githubusercontent.com/lefterisALEX/claude-server-setup/main/cloud-init.yml) \
  --output json | jq -r '.server.public_net.ipv4.ip')

echo "Server IP: $SERVER_IP"
```

Ansible and git are installed automatically via cloud-init on first boot. Wait ~30 seconds before SSHing in.

## Step 2 — Run hardening (as root)

```bash
ssh root@$SERVER_IP \
  "ansible-pull -U https://github.com/lefterisALEX/claude-server-setup harden.yml"
```

This installs Ansible, pulls the repo, and applies `harden.yml`. It:
- Updates all packages
- Creates the non-root user with your SSH key
- Moves SSH to port 2222, disables root login and password auth
- Enables ufw (only 2222/tcp open), fail2ban, unattended upgrades, sysctl hardening, auditd

### Verify before closing the root session

```bash
ssh -p 2222 alex@$SERVER_IP "sudo whoami"
# Should print: root
```

## Step 3 — Set a password for alex

Critical for web console fallback:

```bash
ssh -p 2222 alex@$SERVER_IP
sudo passwd alex      # save it in your password manager
exit
```

## Step 4 — Remove passwordless sudo

```bash
ssh -p 2222 alex@$SERVER_IP

sudo -k && sudo whoami   # verify password-based sudo works first

sudo rm /etc/sudoers.d/90-alex

sudo -k && sudo whoami   # verify again
```

**Lesson learned**: removing the sudoers file before setting a password makes sudo unusable — recovery requires Hetzner rescue mode.

## Step 5 — Install dev tools (as alex)

```bash
ssh -p 2222 alex@$SERVER_IP \
  "ansible-pull -U https://github.com/lefterisALEX/claude-server-setup devtools.yml"
```

Installs: Node.js LTS, Claude Code, Go, Docker CE, kubectl, Helm, stern, Neovim, Fish, Starship, GitHub CLI, chezmoi, Playwright system libs, 4 GB swap.

**Log out and back in** after this — picks up docker group and PATH changes.

## Step 6 — Authenticate

```bash
ssh -p 2222 alex@$SERVER_IP
claude          # OAuth flow in browser
gh auth login   # OAuth flow in browser

# Make fish your default shell:
chsh -s $(which fish)
# Log out and back in
```

## Step 7 — Install Tailscale

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
tailscale ip -4     # note the 100.x.y.z address
```

Enable MagicDNS in the Tailscale admin console.

## Step 8 — Update local `~/.ssh/config`

```
Host claude
    HostName       claude.tail-xxxx.ts.net
    User           alex
    Port           2222
    IdentityFile   ~/.ssh/id_ed25519
    IdentitiesOnly yes
```

## Step 9 — Close public SSH at Hetzner firewall

```bash
hcloud firewall create --name claude-fw
hcloud firewall apply-to-resource claude-fw --type server --server claude
```

Test from laptop: `ssh claude` (Tailscale) works, `nc -zv <public-ip> 2222` times out.

### Emergency: re-open 2222 publicly

```bash
hcloud firewall add-rule claude-fw \
  --direction in --protocol tcp --port 2222 \
  --source-ips 0.0.0.0/0 --source-ips ::/0 \
  --description "Emergency SSH"
```

## Step 10 — Take a snapshot

```bash
hcloud server create-image claude \
  --type snapshot \
  --description "Post-setup baseline $(date -u +%Y-%m-%d)"
```

## Re-running playbooks

Both playbooks are idempotent. To re-apply after changing `vars.yml`:

```bash
# On the server as root:
ansible-pull -U https://github.com/lefterisALEX/claude-server-setup harden.yml

# On the server as alex:
ansible-pull -U https://github.com/lefterisALEX/claude-server-setup devtools.yml
```

## Access fallback paths

| Path | When to use | How |
|------|-------------|-----|
| Tailscale SSH | Normal daily use | `ssh claude` |
| Hetzner web console | Tailscale broken | Hetzner panel → server → Console tab, log in as alex with password |
| Public SSH (temp) | Both above broken | `hcloud firewall add-rule` to open 2222, then SSH normally |

## Verification checks

```bash
sudo grep -E '^(PermitRootLogin|PasswordAuthentication|AllowUsers)' /etc/ssh/sshd_config.d/99-hardening.conf
sudo ufw status verbose
sudo fail2ban-client status sshd
sudo ss -tlnp | grep ssh
node -v && go version && docker --version && kubectl version --client
helm version --short && nvim --version | head -1
fish --version && gh --version | head -1 && claude --version
```

## Ubuntu 24.04 quirks

- **SSH uses socket activation** (`ssh.socket`). You can't `systemctl reload ssh` — the playbook handles this via a handler that detects the active unit.
- **`sshd -t` fails with "missing /run/sshd"** if the directory doesn't exist yet. The hardening playbook creates it before the test.
- **Libraries renamed with `t64` suffix** (time_t transition): `libatk1.0-0t64`, `libcups2t64`, etc. Playwright deps use `ignore_errors: yes` — run `npx playwright install-deps` from a project for the authoritative set.
