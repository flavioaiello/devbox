# devbox

A clean, reproducible macOS dev environment in one command. Powered by [Tart](https://tart.run).

```bash
devbox up
```

devbox runs a macOS VM that comes up with your tools and your host settings: keyboard layout, language and region, time zone, Dock, trackpad, git identity. It has two modes, set by `DEVBOX_MODE` in `devbox.env`:

- **golden** — the configuration is applied **once**, while an image is built (`devbox build`, about 10 minutes). Your VM is a copy-on-write clone of that image and starts in seconds. To update, rebuild the image.
- **ephemeral** — `devbox up` pulls the latest base image, provisions a fresh VM and opens it. Every run starts clean: no drift, no leftover state.

## Install

```bash
brew tap flavioaiello/devbox https://github.com/flavioaiello/devbox
brew install flavioaiello/devbox/devbox
```

Homebrew 7 asks you to trust third-party formulae first: `brew trust --formula flavioaiello/devbox/devbox`.

Or clone and run directly:

```bash
git clone https://github.com/flavioaiello/devbox.git
cd devbox
./bin/devbox up
```

Requires Apple Silicon and macOS 14+. A guest cannot be newer than the host, so the default Tahoe image needs a macOS 26 host. Tart itself is installed on demand from its official release (`devbox install`).

## Quick Start

```bash
devbox init          # scaffold config in the current directory
devbox up            # golden mode: build the image on first use, clone it, open the VM
```

The first `devbox up` builds the golden image (about 10 minutes, once). After that the VM opens with your tools, keyboard layout, region, time zone, Dock and git config, all taken from your host. Login: `admin` / `admin`.

Update the image with `devbox build`, then switch to it with `devbox up --fresh`. Keep data you care about in the shared workspace folder (see below), because `--fresh` replaces the VM.

## Commands

| Command | What it does |
|---------|-------------|
| `devbox up` | Golden: clone the golden image on first use and open it. `--fresh` re-clones, `--rebuild` rebuilds the image first, `-y` skips the confirmation. Ephemeral: recreate the VM from the latest image, provision it, open it |
| `devbox build` | Golden: build or refresh the golden image. `--resume` retries a failed build |
| `devbox capture` | Golden: snapshot this Mac's settings into `.devbox/host-settings.sh` (review or edit it, then `devbox build`) |
| `devbox refresh` | Ephemeral: pull the latest image and recreate the VM without booting it |
| `devbox provision` | Ephemeral: re-apply config to a stopped VM |
| `devbox run` | Open an existing VM |
| `devbox stop` | Stop the running VM |
| `devbox shell` | Interactive shell in the running VM |
| `devbox exec <cmd>` | Run a command in the VM |
| `devbox ip` | Resolve the VM IP through the guest agent |
| `devbox open-code` | Open VS Code in the mounted workspace |
| `devbox status` | Show VM configuration and the last golden build |
| `devbox delete` | Remove the VM |
| `devbox logs` | Show the last provision log |
| `devbox install` | Install or update Tart (official release, checksum verified) |
| `devbox init` | Scaffold config files in the current directory |

## What Gets Inherited

Your host settings are applied to the guest so it feels familiar from the start. All on by default; turn any off in `devbox.env`:

```bash
DEVBOX_INHERIT_HOST_DISPLAY="0"
DEVBOX_INHERIT_HOST_DOCK="0"
# ... etc.
```

| Setting | Ephemeral | Golden |
|---------|:---------:|:------:|
| Display resolution, time zone | ✓ | ✓ |
| Keyboard layout | selected layout | all input sources, also for the login window |
| Dock | style | style |
| Appearance (dark / light), scroll direction, key repeat | ✓ | ✓ |
| Trackpad | tap-to-click | tap-to-click, secondary click, gestures, tracking |
| Git config | whole `~/.gitconfig` | name, email, default branch, pull/push options (no credential helpers) |
| Language and region (formats, units) | | ✓ |
| Finder, menu bar clock, screenshots, window tiling | | ✓ |

`devbox capture` writes the golden snapshot to `.devbox/host-settings.sh`, a plain list of `defaults write` commands you can read and edit. Personal dotfiles can go into `home/`, they are copied into the VM user's home directory when the image is built.

## Customize

Edit `devbox.env` for tracked defaults. Create `devbox.local.env` for personal overrides (git-ignored).

**Add software** — edit `guest/Brewfile`:

```ruby
cask "visual-studio-code"
cask "iterm2"
brew "jq"
```

Golden mode installs the list once while building the image. Ephemeral mode installs it on every `devbox up`.

**Change VM resources:**

```bash
TART_CPU="8"
TART_MEMORY_MB="16384"
TART_DISK_GB="100"
```

A disk size above 50 GB works in both modes. In golden mode the build removes the macOS recovery partition and installs the Tart guest daemon, which grows the system container at boot; raising the value later and running `devbox up --fresh` is enough. The disk can only be increased.

**Mount host directories:**

```bash
DEVBOX_MOUNT_SSH="1"    # ~/.ssh (read-only)
DEVBOX_MOUNT_HOME="1"   # ~ (read-only)
```

**Pass extra flags to Tart:**

```bash
TART_RUN_EXTRA_ARGS="--net-bridged=en0"
```

**Golden image:**

```bash
DEVBOX_GOLDEN_IMAGE="ghcr.io/cirruslabs/macos-tahoe-vanilla:latest"
DEVBOX_DOCK_APPS="/Applications/Microsoft Edge.app|/Applications/Visual Studio Code.app"
DEVBOX_ENABLE_GATEKEEPER="1"      # the vanilla image ships with it off
DEVBOX_TRUST_BREWFILE_APPS="1"    # no first-launch dialog for Brewfile apps and tools
```

## How It Works

**Golden mode.** `devbox build` pulls the vanilla macOS image, clones it, boots it headless and provisions it over SSH once: your host settings, Homebrew and the Brewfile, Rosetta 2, the [Tart guest agent](https://github.com/openai/tart-guest-agent) (clipboard sharing, `tart exec`) and Gatekeeper switched on again. It then reboots and verifies the result, including the keyboard layout that is actually active in the GUI session. A failed check fails the build and keeps the build VM for `--resume`. Finally the disk is enlarged and the golden image replaces the previous one. `devbox up` clones it.

**Ephemeral mode.** `devbox up` runs this sequence:

1. Pull the latest `ghcr.io/cirruslabs/macos-tahoe-base:latest` image
2. Clone a fresh local VM
3. Boot it headless and provision (timezone, keyboard, Dock, packages, etc.)
4. Stop and reopen with the GUI so settings take effect

In both modes your code stays on the host and is shared into the VM via Tart's VirtIO mount. Provisioning an existing image uses `tart exec` (guest agent, no SSH required); only the golden build starts from a vanilla image without an agent and uses SSH.

## Troubleshooting

- **Keychain prompt on host:** `security unlock-keychain ~/Library/Keychains/login.keychain-db`
- **SSH keys rejected in guest:** Copy the key into guest `~/.ssh` and `chmod 600` it (mounted permissions may be too open)
- **Provision failed:** Run `devbox logs` to see what happened
- **Golden build failed:** See `.devbox/build.log`; fix the cause and run `devbox build --resume`
- **Host settings changed:** Golden: run `devbox capture`, `devbox build`, `devbox up --fresh`. Ephemeral: `devbox provision` or `devbox up`
- **Only two macOS VMs run at the same time** (Apple's limit); stop one before starting another
- **A new Homebrew formula or cask is not found:** golden mode only changes when you rebuild the image
