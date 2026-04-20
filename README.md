# Hetzner VPS Setup for Claude Code

End-to-end guide for a hardened Hetzner VPS running Claude Code, Playwright, Go tests, and related dev tooling. Documents the exact setup, including lessons learned from lockouts along the way.

## Architecture overview

- **Server**: Hetzner CPX32 (AMD Genoa, 4 vCPU, 8 GB, 160 GB NVMe) — Ubuntu 24.04
- **SSH**: port 2222, keys only, non-root user `alex` with sudo (password set)
- **Network access**: Tailscale for normal use, public SSH closed at Hetzner firewall
- **Fallbacks** (in order): Tailscale → Hetzner web console (password) → rescue mode
- **Dev tools**: Node.js LTS, Go, Docker, kubectl, helm, stern, Neovim, Fish, Starship, chezmoi, gh (GitHub CLI), Claude Code

## Sizing rationale

- **CPX22** (2 vCPU / 4 GB) — too small once Playwright spins up 3+ browsers alongside Go tests
- **CPX32** (4 vCPU / 8 GB) — sweet spot for this workload
- **CCX13** (dedicated vCPU) — consider if Playwright timing flakiness becomes an issue
- **CAX21** (ARM / 4 vCPU / 8 GB) — cheaper alternative, works fine for Go + Playwright (Playwright ships ARM64 browsers now)

## Step 1 — Create the server

```bash
hcloud server create \
  --name claude \
  --image ubuntu-24.04 \
  --type cpx32 \
  --location nbg1 \
  --ssh-key lefteris
```

If the type is unavailable in your chosen location, try `hel1` (Helsinki) or `fsn1` (Falkenstein). Check availability with `hcloud server-type list`.

Note the IPv4 address from the output.

## Step 2 — Copy and run the hardening script

From your laptop, in the directory containing the scripts:

```bash
SERVER_IP=<ip-from-step-1>

scp -o IdentitiesOnly=yes harden-vps.sh dev-setup.sh root@$SERVER_IP:/root/

ssh -o IdentitiesOnly=yes root@$SERVER_IP "bash /root/harden-vps.sh"
```

The hardening script:
- Updates all packages
- Creates `alex` user with sudo, installs your SSH key
- Moves SSH to port 2222, disables root login and password auth
- Enables ufw (only 2222/tcp open)
- Configures fail2ban with sshd jail
- Enables unattended security upgrades with auto-reboot at 03:00
- Applies sysctl hardening
- Enables auditd
- Reloads ssh.socket (Ubuntu 24.04 uses socket activation)

### Verify before closing root session

**In a new terminal:**

```bash
ssh -p 2222 -o IdentitiesOnly=yes alex@$SERVER_IP "sudo whoami"
```

Should print `root`. Only then close the root session.

## Step 3 — Set a password for alex

Critical for web console fallback. Do this before closing any firewall doors:

```bash
ssh -p 2222 alex@$SERVER_IP
sudo passwd alex
# Set a strong password, save it in your password manager
exit
```

This doesn't weaken SSH (which stays keys-only) — it only enables local/console login.

## Step 4 — Remove passwordless sudo

The hardening script sets up passwordless sudo by default. Now that alex has a password, tighten it up:

```bash
ssh -p 2222 alex@$SERVER_IP

# Test password-based sudo FIRST — don't remove the file until this works:
sudo -k                    # clear cached sudo
sudo whoami                # should prompt for password, print "root"

# Only if the above worked:
sudo rm /etc/sudoers.d/90-alex

# Verify sudo still works with password:
sudo -k
sudo whoami                # should prompt again
```

**Lesson learned**: if you remove `/etc/sudoers.d/90-alex` *before* setting a password, sudo becomes unusable (the user has no password and no passwordless rule). Recovery requires Hetzner rescue mode — see "Recovery" section below.

## Step 5 — Install dev tools

Copy and run the dev-setup script as alex:

```bash
# From laptop:
scp -P 2222 -o IdentitiesOnly=yes dev-setup.sh alex@$SERVER_IP:~

# Optionally set DOTFILES_REPO for chezmoi auto-apply:
ssh -p 2222 alex@$SERVER_IP "DOTFILES_REPO='https://github.com/you/dotfiles.git' bash ~/dev-setup.sh"

# Or without dotfiles:
ssh -p 2222 alex@$SERVER_IP "bash ~/dev-setup.sh"
```

The dev-setup script installs:
- 4 GB swap file (with `vm.swappiness=10`)
- Node.js LTS + Claude Code (via user-owned npm prefix `~/.npm-global`)
- Go 1.23.4
- Docker CE + compose plugin (adds alex to docker group)
- kubectl, Helm, stern
- Neovim (stable PPA)
- Fish shell (stable PPA) with starship configured
- Starship prompt with minimal config (bash + fish)
- GitHub CLI (`gh`)
- chezmoi (optionally applies dotfiles)
- Playwright system libs

**Log out and back in** after the script finishes — this picks up the docker group and PATH changes.

## Step 6 — Authenticate Claude Code and GitHub CLI

```bash
ssh -p 2222 alex@$SERVER_IP
claude                    # OAuth flow in browser
gh auth login             # OAuth flow in browser
```

Optionally make fish your default shell:

```bash
chsh -s $(which fish)
# Log out and back in
```

## Step 7 — Install Tailscale

On the VPS:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
# Follow the URL to authenticate against your tailnet
tailscale ip -4          # note the 100.x.y.z address
tailscale status
```

Enable MagicDNS in the Tailscale admin console so you can use hostnames instead of IPs.

## Step 8 — Update local `~/.ssh/config`

On your laptop:

```
Host claude
    HostName       claude.tail-xxxx.ts.net    # Tailscale MagicDNS hostname
    User           alex
    Port           2222
    IdentityFile   ~/.ssh/id_ed25519
    IdentitiesOnly yes
```

Test: `ssh claude` should work via Tailscale.

## Step 9 — Close public SSH at the Hetzner firewall

Replace `claude` with your actual server name (check with `hcloud server list`):

```bash
# Create firewall (no inbound rules = deny all inbound)
hcloud firewall create --name claude-fw

# Attach to server
hcloud firewall apply-to-resource claude-fw \
  --type server --server claude

# Verify
hcloud firewall describe claude-fw
```

**Test from laptop in a new terminal, before relying on this:**

```bash
ssh claude                          # via Tailscale — should work
nc -zv <public-ip> 2222             # should timeout — blocked
```

### Emergency: re-open 2222 publicly

If Tailscale breaks and you need public SSH back:

```bash
hcloud firewall add-rule claude-fw \
  --direction in --protocol tcp --port 2222 \
  --source-ips 0.0.0.0/0 --source-ips ::/0 \
  --description "Emergency SSH"
```

Close it again:

```bash
hcloud firewall delete-rule claude-fw \
  --direction in --protocol tcp --port 2222 \
  --source-ips 0.0.0.0/0 --source-ips ::/0
```

Alternative: restrict to your home IP only

```bash
MY_IP=$(curl -s https://ifconfig.me)
hcloud firewall add-rule claude-fw \
  --direction in --protocol tcp --port 2222 \
  --source-ips ${MY_IP}/32 \
  --description "SSH from home"
```

## Step 10 — Take a snapshot

Known-good baseline for rollback:

```bash
hcloud server create-image claude \
  --type snapshot \
  --description "Post-setup baseline $(date -u +%Y-%m-%d)"
```

## Access fallback paths

Three independent ways to reach the server:

| Path | When to use | How |
|------|-------------|-----|
| Tailscale SSH | Normal daily use | `ssh claude` |
| Hetzner web console | Tailscale broken | Hetzner panel → server → Console tab, log in as alex with password |
| Public SSH (temp) | Both above broken | `hcloud firewall add-rule` to open 2222, then SSH normally |

## Verification checks

After setup, confirm everything is in place:

```bash
# SSH hardening
sudo grep -E '^(PermitRootLogin|PasswordAuthentication|AllowUsers)' /etc/ssh/sshd_config.d/99-hardening.conf

# Firewall (host-level)
sudo ufw status verbose

# fail2ban
sudo fail2ban-client status sshd

# Unattended upgrades
systemctl list-timers apt-daily-upgrade.timer
sudo unattended-upgrade --dry-run --debug 2>&1 | tail -5

# SSH actually listening on 2222
sudo ss -tlnp | grep ssh

# Dev tool versions
node -v && go version && docker --version && kubectl version --client
helm version --short && stern --version && nvim --version | head -1
fish --version && gh --version | head -1
starship --version && chezmoi --version && claude --version
```

## Ubuntu 24.04 quirks we hit

- **SSH uses socket activation** (`ssh.socket` + transient `ssh.service`). You can't `systemctl reload ssh` — you must `systemctl restart ssh.socket`. Changing the port in `sshd_config` may not be enough; check with `ss -tlnp` and override `ssh.socket`'s `ListenStream` if needed.
- **`sshd -t` fails with "missing /run/sshd"** if the directory doesn't exist yet. The hardening script creates it before the test.
- **Libraries renamed with `t64` suffix** (time_t transition): `libatk1.0-0t64`, `libcups2t64`, etc. Playwright's deps list needs updating per Ubuntu version — when in doubt, use `npx playwright install-deps` from a project.

## Scanner traffic is normal

Even on port 2222, expect fail2ban to ban a handful of IPs per day. Key-only auth + `MaxAuthTries 3` means they hit a wall immediately. Once the Hetzner firewall closes 2222 publicly, this stops.

## Files

- `harden-vps.sh` — run once as root on a fresh VPS
- `dev-setup.sh` — run once as alex after hardening
