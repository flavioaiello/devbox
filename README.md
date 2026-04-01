# devbox

A clean, reproducible macOS dev environment in one command. Powered by [Tart](https://tart.run).

```bash
devbox up
```

This pulls the latest macOS base image, provisions a fresh VM with your tools and host settings, and opens it. Every run starts clean — no drift, no leftover state.

## Install

```bash
brew install flavioaiello/tap/devbox
```

Or clone and run directly:

```bash
git clone https://github.com/flavioaiello/devbox.git
cd devbox
./bin/devbox up
```

Requires Apple Silicon, macOS 14+, and Homebrew.

## Quick Start

```bash
devbox init          # scaffold config in current directory
devbox up            # pull image, provision, and open the VM
```

That's it. The VM opens with VS Code installed, your keyboard layout, timezone, Dock, dark mode, and git config — all inherited from your host automatically.

## Commands

| Command | What it does |
|---------|-------------|
| `devbox up` | Full rebuild: pull, provision, open |
| `devbox run` | Open an existing VM |
| `devbox stop` | Stop the running VM |
| `devbox provision` | Re-apply config to a stopped VM |
| `devbox refresh` | Pull the latest image and recreate the VM |
| `devbox shell` | Interactive shell in the running VM |
| `devbox exec <cmd>` | Run a command in the VM |
| `devbox open-code` | Open VS Code in the mounted workspace |
| `devbox status` | Show VM configuration |
| `devbox delete` | Remove the VM |
| `devbox logs` | Show the last provision log |
| `devbox init` | Scaffold config files in the current directory |

## What Gets Inherited

Your host settings are automatically applied to the guest so it feels familiar from the start:

- Display resolution
- Timezone
- Keyboard layout
- Dock (pinned apps, size, position)
- Appearance (dark / light)
- Scroll direction
- Key repeat rate
- Trackpad tap-to-click
- Git config (`~/.gitconfig`)

All on by default. Turn any off in `devbox.env`:

```bash
DEVBOX_INHERIT_HOST_DISPLAY="0"
DEVBOX_INHERIT_HOST_DOCK="0"
# ... etc.
```

## Customize

Edit `devbox.env` for tracked defaults. Create `devbox.local.env` for personal overrides (git-ignored).

**Add software** — edit `guest/Brewfile`:

```ruby
cask "visual-studio-code"
cask "iterm2"
brew "jq"
```

**Change VM resources:**

```bash
TART_CPU="8"
TART_MEMORY_MB="16384"
TART_DISK_GB="100"
```

**Mount host directories:**

```bash
DEVBOX_MOUNT_SSH="1"    # ~/.ssh (read-only)
DEVBOX_MOUNT_HOME="1"   # ~ (read-only)
```

**Pass extra flags to Tart:**

```bash
TART_RUN_EXTRA_ARGS="--net-bridged=en0"
```

## How It Works

`devbox up` runs this sequence:

1. Pull the latest `ghcr.io/cirruslabs/macos-tahoe-base:latest` image
2. Clone a fresh local VM
3. Boot it headless and provision (timezone, keyboard, Dock, packages, etc.)
4. Stop and reopen with the GUI so settings take effect

Your code stays on the host and is shared into the VM via Tart's VirtIO mount. Changes inside the guest are ephemeral — the next `up` starts fresh.

Provisioning uses `tart exec` (guest agent, no SSH required).

## Troubleshooting

- **Keychain prompt on host:** `security unlock-keychain ~/Library/Keychains/login.keychain-db`
- **SSH keys rejected in guest:** Copy the key into guest `~/.ssh` and `chmod 600` it (mounted permissions may be too open)
- **Provision failed:** Run `devbox logs` to see what happened
- **Host settings changed:** Run `devbox provision` or `devbox up` to re-apply