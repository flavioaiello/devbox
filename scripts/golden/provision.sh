#!/bin/bash
# Runs INSIDE the VM, once, while the golden image is built (devbox build).
# Idempotent, so `build --resume` can run it again. Optional arguments select steps:
#   ./provision.sh settings timezone dock
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=/dev/null
source ./config.env
# shellcheck source=/dev/null
source ./host-settings.sh

export NONINTERACTIVE=1 HOMEBREW_NO_ENV_HINTS=1
BREW=/opt/homebrew/bin/brew

step() { printf '\n── %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

step_settings() {
  step "Settings captured from the host"
  # the upstream image forces full keyboard navigation for its own UI automation
  defaults delete NSGlobalDomain AppleKeyboardUIMode 2>/dev/null || true
  apply_host_settings
}

step_timezone() {
  [[ -n ${TIMEZONE:-} ]] || return 0
  step "Time zone $TIMEZONE"
  [[ -e /var/db/timezone/zoneinfo/$TIMEZONE ]] || die "unknown time zone '$TIMEZONE'"
  # `systemsetup -settimezone` fails over SSH (error -99) and deletes /etc/localtime, so link it directly
  sudo ln -sf "/var/db/timezone/zoneinfo/$TIMEZONE" /etc/localtime
  date
}

step_rosetta() {
  [[ ${INSTALL_ROSETTA:-0} == 1 ]] || return 0
  step "Rosetta 2"
  if [[ -f /Library/Apple/usr/libexec/oah/libRosettaRuntime ]]; then echo "  already installed"; return 0; fi
  sudo softwareupdate --install-rosetta --agree-to-license
}

step_homebrew() {
  [[ ${INSTALL_BREWFILE:-1} == 1 ]] || return 0
  step "Homebrew (installs the Command Line Tools first, takes a few minutes)"
  if [[ ! -x $BREW ]]; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  eval "$($BREW shellenv)"
  brew --version | head -1
}

step_bundle() {
  [[ ${INSTALL_BREWFILE:-1} == 1 ]] || return 0
  step "Default programs (Brewfile)"
  eval "$($BREW shellenv)"
  if ! brew bundle --file ./Brewfile; then
    warn "brew bundle failed — retrying once"
    brew bundle --file ./Brewfile
  fi
}

# Runs before and after `bundle`: the first pass makes a resumed build safe (apps from an earlier run).
step_trust() {
  [[ ${INSTALL_BREWFILE:-1} == 1 && ${TRUST_BREWFILE_APPS:-1} == 1 ]] || return 0
  step "First-launch confirmation for Brewfile apps"
  eval "$($BREW shellenv)"
  # Homebrew verified the cask downloads (pinned sha256). Without this, Gatekeeper asks "downloaded from
  # the Internet — open?" on the first launch of every app, and `code` from a script blocks on that dialog.
  local cask app
  command -v jq >/dev/null 2>&1 || brew install jq
  for cask in $(brew list --cask 2>/dev/null); do
    for app in $(brew info --cask --json=v2 "$cask" | jq -r '.casks[0].artifacts[] | select(type == "object") | .app? // empty | .[] | select(type == "string") | gsub(" "; "@")'); do
      app=${app//@/ }
      if [[ -d "/Applications/$app" ]]; then
        xattr -dr com.apple.quarantine "/Applications/$app" 2>/dev/null || true
        echo "  trusted: $app"
      fi
    done
  done
}

step_agent() {
  [[ ${INSTALL_GUEST_AGENT:-0} == 1 ]] || return 0
  step "Tart guest agent (clipboard sharing, tart exec)"
  [[ -x downloads/tart-guest-agent ]] || die "downloads/tart-guest-agent is missing"
  sudo mkdir -p /usr/local/bin
  sudo install -m 755 -o root -g wheel downloads/tart-guest-agent /usr/local/bin/tart-guest-agent
  # Runs as a LaunchAgent in the user's GUI session; that is what clipboard sharing needs.
  sudo tee /Library/LaunchAgents/org.cirruslabs.tart-guest-agent.plist >/dev/null <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>org.cirruslabs.tart-guest-agent</string>
  <key>ProgramArguments</key>
  <array><string>/usr/local/bin/tart-guest-agent</string><string>--run-agent</string></array>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>/bin:/usr/bin:/usr/sbin:/usr/local/bin:/opt/homebrew/bin</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/tart-guest-agent.log</string>
  <key>StandardErrorPath</key><string>/tmp/tart-guest-agent.log</string>
</dict>
</plist>
PLIST
  sudo chown root:wheel /Library/LaunchAgents/org.cirruslabs.tart-guest-agent.plist
  sudo chmod 644 /Library/LaunchAgents/org.cirruslabs.tart-guest-agent.plist
  plutil -lint /Library/LaunchAgents/org.cirruslabs.tart-guest-agent.plist
  /usr/local/bin/tart-guest-agent --version
}

step_daemon() {
  [[ ${GROW_DISK:-0} == 1 ]] || return 0
  step "Tart guest daemon (grows the system container after the disk was enlarged)"
  [[ -x /usr/local/bin/tart-guest-agent ]] || die "the guest agent must be installed first"
  sudo tee /Library/LaunchDaemons/org.cirruslabs.tart-guest-daemon.plist >/dev/null <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>org.cirruslabs.tart-guest-daemon</string>
  <key>ProgramArguments</key>
  <array><string>/usr/local/bin/tart-guest-agent</string><string>--run-daemon</string></array>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>/bin:/usr/bin:/usr/sbin:/usr/local/bin:/opt/homebrew/bin</string></dict>
  <key>WorkingDirectory</key><string>/var/empty</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/tart-guest-daemon.log</string>
  <key>StandardErrorPath</key><string>/tmp/tart-guest-daemon.log</string>
</dict>
</plist>
PLIST
  sudo chown root:wheel /Library/LaunchDaemons/org.cirruslabs.tart-guest-daemon.plist
  sudo chmod 644 /Library/LaunchDaemons/org.cirruslabs.tart-guest-daemon.plist
  plutil -lint /Library/LaunchDaemons/org.cirruslabs.tart-guest-daemon.plist
}

step_home() {
  step "Home directory files"
  if [[ -d home ]]; then
    cp -R home/. "$HOME/"
    ls -A home | sed 's/^/  /'
  fi
  if [[ -x $BREW ]] && ! grep -qs 'brew shellenv' "$HOME/.zprofile"; then
    echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >>"$HOME/.zprofile"
  fi
}

step_dock() {
  step "Dock"
  local app xml=""
  for app in ${DOCK_APPS[@]+"${DOCK_APPS[@]}"}; do
    if [[ -d $app ]]; then
      xml+="<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>file://${app// /%20}/</string><key>_CFURLStringType</key><integer>15</integer></dict></dict><key>tile-type</key><string>file-tile</string></dict>"
      echo "  + $app"
    else
      echo "  - skipped, not installed: $app"
    fi
  done
  defaults write com.apple.dock persistent-apps "<array>$xml</array>"
}

step_security() {
  [[ ${ENABLE_GATEKEEPER:-1} == 1 ]] || return 0
  step "Gatekeeper (the upstream image ships with it off)"
  sudo spctl --global-enable
  spctl --status
}

step_finalize() {
  step "Cleanup and image stamp"
  if [[ -x $BREW ]]; then
    eval "$($BREW shellenv)"
    brew cleanup --prune=all -s >/dev/null 2>&1 || true
    echo "  Homebrew download cache cleaned"
  fi
  {
    echo "built_at=$(date '+%Y-%m-%dT%H:%M:%S%z')"
    echo "base_image=${TART_MACOS_BASE_IMAGE:-unknown}"
    echo "base_digest=${TART_MACOS_BASE_DIGEST:-unknown}"
    echo "tart=${TART_MACOS_TART_VERSION:-unknown}"
    echo "guest_agent=${TART_MACOS_AGENT_VERSION:-none}"
  } | sudo tee /etc/devbox-image >/dev/null
  sed 's/^/  /' /etc/devbox-image
  sleep 3   # let cfprefsd write the preferences to disk
  killall Dock Finder SystemUIServer 2>/dev/null || true
  sync
}

main() {
  local steps s
  if (($# == 0)); then
    steps="settings timezone rosetta homebrew trust bundle trust agent daemon home dock security finalize"
  else
    steps="$*"
  fi
  for s in $steps; do "step_$s"; done
  printf '\nProvisioning finished.\n'
}

main "$@"
