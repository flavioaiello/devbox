#!/usr/bin/env bash

set -euo pipefail

log() {
  printf '[guest-bootstrap] %s\n' "$*"
}

die() {
  printf '[guest-bootstrap] error: %s\n' "$*" >&2
  exit 1
}

TARGET_USER="${DEVBOX_TARGET_USER:-admin}"
CURRENT_USER="$(id -un)"

if ! id "$TARGET_USER" >/dev/null 2>&1; then
  die "target user '$TARGET_USER' does not exist"
fi

TARGET_HOME="${DEVBOX_TARGET_HOME:-}"
if [[ -z "$TARGET_HOME" ]]; then
  TARGET_HOME="$(dscl . -read "/Users/${TARGET_USER}" NFSHomeDirectory | awk '{print $2}')"
fi

BREWFILE_PATH="${DEVBOX_BREWFILE:-${TARGET_HOME}/.devbox/Brewfile}"
BREW_BIN="/opt/homebrew/bin/brew"

run_as_target() {
  if [[ "$CURRENT_USER" == "$TARGET_USER" ]]; then
    "$@"
  else
    sudo -H -u "$TARGET_USER" "$@"
  fi
}

write_keyboard_defaults() {
  local domain
  domain="${TARGET_HOME}/Library/Preferences/com.apple.HIToolbox.plist"

  log "Applying keyboard layout '${DEVBOX_KEYBOARD_LAYOUT_NAME}'"

  run_as_target defaults write "$domain" AppleCurrentKeyboardLayoutInputSourceID -string "$DEVBOX_KEYBOARD_LAYOUT_SOURCE_ID"
  run_as_target defaults write "$domain" AppleEnabledInputSources -array \
    "{ InputSourceKind = \"Keyboard Layout\"; \"KeyboardLayout ID\" = ${DEVBOX_KEYBOARD_LAYOUT_ID}; \"KeyboardLayout Name\" = \"${DEVBOX_KEYBOARD_LAYOUT_NAME}\"; }" \
    '{ "Bundle ID" = "com.apple.CharacterPaletteIM"; InputSourceKind = "Non Keyboard Input Method"; }' \
    '{ "Bundle ID" = "com.apple.PressAndHold"; InputSourceKind = "Non Keyboard Input Method"; }'
  run_as_target defaults write "$domain" AppleSelectedInputSources -array \
    "{ InputSourceKind = \"Keyboard Layout\"; \"KeyboardLayout ID\" = ${DEVBOX_KEYBOARD_LAYOUT_ID}; \"KeyboardLayout Name\" = \"${DEVBOX_KEYBOARD_LAYOUT_NAME}\"; }" \
    '{ "Bundle ID" = "com.apple.PressAndHold"; InputSourceKind = "Non Keyboard Input Method"; }'

  # Also write to the global domain so the login session picks it up.
  run_as_target defaults write -g AppleCurrentKeyboardLayoutInputSourceID -string "$DEVBOX_KEYBOARD_LAYOUT_SOURCE_ID"

  # Write to the system-level plist so the loginwindow session uses this layout.
  local sys_domain
  sys_domain="/Library/Preferences/com.apple.HIToolbox.plist"
  sudo defaults write "$sys_domain" AppleCurrentKeyboardLayoutInputSourceID -string "$DEVBOX_KEYBOARD_LAYOUT_SOURCE_ID"
  sudo defaults write "$sys_domain" AppleDefaultAsciiInputSource -dict \
    InputSourceKind "Keyboard Layout" \
    "KeyboardLayout ID" -int "${DEVBOX_KEYBOARD_LAYOUT_ID}" \
    "KeyboardLayout Name" "${DEVBOX_KEYBOARD_LAYOUT_NAME}"
  sudo defaults write "$sys_domain" AppleEnabledInputSources -array \
    "{ InputSourceKind = \"Keyboard Layout\"; \"KeyboardLayout ID\" = ${DEVBOX_KEYBOARD_LAYOUT_ID}; \"KeyboardLayout Name\" = \"${DEVBOX_KEYBOARD_LAYOUT_NAME}\"; }"
  sudo defaults write "$sys_domain" AppleSelectedInputSources -array \
    "{ InputSourceKind = \"Keyboard Layout\"; \"KeyboardLayout ID\" = ${DEVBOX_KEYBOARD_LAYOUT_ID}; \"KeyboardLayout Name\" = \"${DEVBOX_KEYBOARD_LAYOUT_NAME}\"; }"
}

set_timezone() {
  if [[ -z "${DEVBOX_TIMEZONE:-}" ]]; then
    return
  fi

  log "Setting timezone to ${DEVBOX_TIMEZONE}"
  sudo systemsetup -settimezone "$DEVBOX_TIMEZONE" >/dev/null
}

apply_dock_layout() {
  local dock_plist

  dock_plist="${DEVBOX_DOCK_PLIST:-}"
  if [[ -z "$dock_plist" || ! -f "$dock_plist" ]]; then
    return
  fi

  log "Applying host Dock style"

  # Only inherit Dock appearance settings, not pinned apps (which reference
  # host-installed apps that may not exist in the guest).
  local key value
  for key in tilesize magnification largesize orientation autohide mineffect launchanim show-recents minimize-to-application; do
    value="$(plutil -extract "$key" raw -o - "$dock_plist" 2>/dev/null || true)"
    if [[ -n "$value" ]]; then
      # Detect type: integer vs bool vs string
      case "$key" in
        magnification|autohide|launchanim|show-recents|minimize-to-application)
          if [[ "$value" == "1" ]]; then
            run_as_target defaults write com.apple.dock "$key" -bool true
          else
            run_as_target defaults write com.apple.dock "$key" -bool false
          fi
          ;;
        tilesize|largesize)
          run_as_target defaults write com.apple.dock "$key" -int "$value"
          ;;
        *)
          run_as_target defaults write com.apple.dock "$key" -string "$value"
          ;;
      esac
    fi
  done
  run_as_target killall Dock 2>/dev/null || true
}

apply_appearance() {
  local mode

  mode="${DEVBOX_APPEARANCE:-}"
  if [[ -z "$mode" ]]; then
    return
  fi

  if [[ "$mode" == "dark" ]]; then
    log "Enabling dark mode"
    run_as_target defaults write -g AppleInterfaceStyle -string Dark
  else
    log "Enabling light mode"
    run_as_target defaults delete -g AppleInterfaceStyle 2>/dev/null || true
  fi
}

apply_scroll_direction() {
  local value

  value="${DEVBOX_SCROLL_NATURAL:-}"
  if [[ -z "$value" ]]; then
    return
  fi

  log "Setting scroll direction: natural=$value"
  run_as_target defaults write -g com.apple.swipescrolldirection -bool "$value"
}

apply_key_repeat() {
  local key_repeat
  local initial_key_repeat

  key_repeat="${DEVBOX_KEY_REPEAT:-}"
  initial_key_repeat="${DEVBOX_INITIAL_KEY_REPEAT:-}"

  if [[ -z "$key_repeat" || -z "$initial_key_repeat" ]]; then
    return
  fi

  log "Setting key repeat: rate=$key_repeat initial=$initial_key_repeat"
  run_as_target defaults write -g KeyRepeat -int "$key_repeat"
  run_as_target defaults write -g InitialKeyRepeat -int "$initial_key_repeat"
}

apply_trackpad() {
  local clicking

  clicking="${DEVBOX_TRACKPAD_TAP_TO_CLICK:-}"
  if [[ -z "$clicking" ]]; then
    return
  fi

  log "Setting trackpad tap-to-click: $clicking"

  local bool_value
  if [[ "$clicking" == "1" ]]; then
    bool_value="true"
  else
    bool_value="false"
  fi

  run_as_target defaults write com.apple.AppleMultitouchTrackpad Clicking -bool "$bool_value"
  run_as_target defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad Clicking -bool "$bool_value"
}

apply_gitconfig() {
  local gitconfig

  gitconfig="${DEVBOX_GITCONFIG:-}"
  if [[ -z "$gitconfig" || ! -f "$gitconfig" ]]; then
    return
  fi

  log "Installing host .gitconfig"
  run_as_target cp "$gitconfig" "${TARGET_HOME}/.gitconfig"
  run_as_target chown "${TARGET_USER}" "${TARGET_HOME}/.gitconfig"
}

install_brewfile() {
  if [[ ! -f "$BREWFILE_PATH" ]]; then
    log "No Brewfile found at $BREWFILE_PATH, skipping package install"
    return
  fi

  if [[ ! -x "$BREW_BIN" ]]; then
    die "Homebrew was not found at ${BREW_BIN}"
  fi

  log "Installing Brewfile packages"
  run_as_target "$BREW_BIN" bundle --file "$BREWFILE_PATH"
}

main() {
  set_timezone
  write_keyboard_defaults
  apply_dock_layout
  apply_appearance
  apply_scroll_direction
  apply_key_repeat
  apply_trackpad
  apply_gitconfig

  # Flush preferences cache so the next GUI login picks up all changes.
  run_as_target killall cfprefsd >/dev/null 2>&1 || true

  install_brewfile
  log "Guest bootstrap finished"
}

main "$@"