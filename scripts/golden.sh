# shellcheck shell=bash
# Golden image mode for devbox: build a configured macOS image once (`devbox build`), then clone it for
# day-to-day use (`devbox up`). Updating means rebuilding the image; nothing is managed inside the VM.
#
#   vanilla image ─► build (one-off provisioning, reboot, verify) ─► golden image ─► clone ─► working VM
#
# Sourced by bin/devbox; relies on its helpers (log, warn, die, is_truthy, vm_exists, run_vm_gui, ...)
# and on the loaded configuration (TART_*, DEVBOX_*). Guest-side scripts live in scripts/golden/.

GOLDEN_GUEST_USER="admin"
GOLDEN_GUEST_PASSWORD="admin"   # fixed by the upstream Cirrus Labs images
GOLDEN_BUILD_VM=""
GOLDEN_STAGE=""
GOLDEN_VM_PID=""
GOLDEN_VM_LOG=""
GOLDEN_GUEST_IP=""
GOLDEN_BUILDING=0
GOLDEN_BUILD_OK=0
GOLDEN_GROW=0
GOLDEN_BASE_DISK_GB=50          # disk size of the upstream images
GOLDEN_TART_BINDIR=""

golden_mode()       { [[ "${DEVBOX_MODE:-ephemeral}" == "golden" ]]; }
golden_tart_home()  { printf '%s' "${TART_HOME:-${HOME}/.tart}"; }
golden_vm_exists()  { tart list --source local --quiet 2>/dev/null | grep -Fxq -- "$1"; }
golden_vm_running() { [[ "$(tart get "$1" --format json 2>/dev/null | plutil -extract Running raw -o - - 2>/dev/null)" == "true" ]]; }
golden_vm_disk_gb() { tart get "$1" --format json 2>/dev/null | plutil -extract Disk raw -o - - 2>/dev/null || echo 0; }
golden_free_gb()    { df -k "$(golden_tart_home)" | awk 'NR == 2 { printf "%d", $4 / 1048576 }'; }
golden_shq()        { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
golden_flag()       { if is_truthy "${1:-}"; then printf 1; else printf 0; fi; }
golden_need()       { local tool; for tool in "$@"; do command -v "$tool" >/dev/null 2>&1 || die "missing required tool: ${tool}"; done; }

golden_image_major() {
  case "$1" in
    *golden-gate*) echo 27 ;; *tahoe*) echo 26 ;; *sequoia*) echo 15 ;;
    *sonoma*) echo 14 ;; *ventura*) echo 13 ;; *monterey*) echo 12 ;; *) echo 0 ;;
  esac
}

# Digest the local OCI cache resolved <host>/<path>:<tag> to.
golden_oci_digest() {
  local ref="$1" host path tag target
  host="${ref%%/*}"; path="${ref#*/}"; tag="latest"
  if [[ "$path" == *:* ]]; then tag="${path##*:}"; path="${path%:*}"; fi
  target="$(readlink "$(golden_tart_home)/cache/OCIs/${host}/${path}/${tag}" 2>/dev/null || true)"
  if [[ -n "$target" ]]; then basename "$target"; else echo unknown; fi
}

# ---------------------------------------------------------------------------------------------
# install — Tart from the official release archive, checksum verified. (The Homebrew tap formula is
# stale and rejected by recent Homebrew versions, so `brew install cirruslabs/cli/tart` does not work.)
# ---------------------------------------------------------------------------------------------

# golden_fetch_release_asset <owner/repo> <asset> <dest> — verifies the published sha256, prints the tag
golden_fetch_release_asset() {
  local repo="$1" asset="$2" dest="$3" json tag url="" digest="" actual i=0 name
  json="$(mktemp "${TMPDIR:-/tmp}/devbox-release.XXXXXX")"
  if ! curl -fsSL -o "$json" "https://api.github.com/repos/${repo}/releases/latest"; then
    rm -f "$json"; die "cannot query the GitHub releases of ${repo}"
  fi
  tag="$(plutil -extract tag_name raw -o - "$json")"
  while name="$(plutil -extract "assets.${i}.name" raw -o - "$json" 2>/dev/null)"; do
    if [[ "$name" == "$asset" ]]; then
      url="$(plutil -extract "assets.${i}.browser_download_url" raw -o - "$json")"
      digest="$(plutil -extract "assets.${i}.digest" raw -o - "$json" 2>/dev/null || true)"
      break
    fi
    i=$((i + 1))
  done
  rm -f "$json"
  [[ -n "$url" ]] || die "${repo} ${tag} has no asset ${asset}"
  [[ "$digest" == sha256:* ]] || die "${repo} ${tag} publishes no sha256 digest for ${asset}; refusing to install it unverified"
  curl -fsSL -o "$dest" "$url" || die "download failed: ${url}"
  actual="$(shasum -a 256 "$dest" | awk '{ print $1 }')"
  [[ "$actual" == "${digest#sha256:}" ]] || die "checksum mismatch for ${asset} (${repo} ${tag})"
  printf '%s' "$tag"
}

cmd_install() {
  local force=0 json latest current="" tag app="${HOME}/Applications/tart.app"
  case "${1:-}" in
    --force) force=1 ;;
    "") ;;
    *) die "unknown option: $1" ;;
  esac
  golden_need curl shasum tar spctl plutil

  json="$(mktemp "${TMPDIR:-/tmp}/devbox-release.XXXXXX")"
  curl -fsSL -o "$json" "https://api.github.com/repos/cirruslabs/tart/releases/latest" || { rm -f "$json"; die "cannot reach GitHub"; }
  latest="$(plutil -extract tag_name raw -o - "$json")"
  rm -f "$json"
  if command -v tart >/dev/null 2>&1; then current="$(tart --version 2>/dev/null | head -1 || true)"; fi
  if [[ "$current" == "$latest" && "$force" -eq 0 ]]; then
    log "Tart ${latest} is already installed ($(command -v tart))"
    return
  fi

  GOLDEN_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/devbox-install.XXXXXX")"
  log "Downloading Tart ${latest}"
  tag="$(golden_fetch_release_asset cirruslabs/tart tart.tar.gz "${GOLDEN_STAGE}/tart.tar.gz")"
  tar -xzf "${GOLDEN_STAGE}/tart.tar.gz" -C "${GOLDEN_STAGE}"
  spctl --assess --type execute "${GOLDEN_STAGE}/tart.app" 2>/dev/null || die "Gatekeeper rejects the downloaded tart.app"

  mkdir -p "${HOME}/Applications"
  rm -rf "$app"
  mv "${GOLDEN_STAGE}/tart.app" "$app"

  if [[ -d /opt/homebrew/bin && -w /opt/homebrew/bin ]]; then GOLDEN_TART_BINDIR="/opt/homebrew/bin"; else GOLDEN_TART_BINDIR="${HOME}/.local/bin"; fi
  mkdir -p "$GOLDEN_TART_BINDIR"
  # A wrapper (like Homebrew's): Tart has to be started from inside its app bundle.
  printf '#!/bin/bash\nexec "$HOME/Applications/tart.app/Contents/MacOS/tart" "$@"\n' >"${GOLDEN_TART_BINDIR}/tart"
  chmod 755 "${GOLDEN_TART_BINDIR}/tart"
  log "Installed Tart ${tag} -> ${app} (launcher: ${GOLDEN_TART_BINDIR}/tart)"
  case ":${PATH}:" in
    *":${GOLDEN_TART_BINDIR}:"*) ;;
    *) warn "${GOLDEN_TART_BINDIR} is not on your PATH"; export PATH="${GOLDEN_TART_BINDIR}:${PATH}" ;;
  esac
}

# ---------------------------------------------------------------------------------------------
# capture — snapshot this Mac's settings into .devbox/host-settings.sh
# ---------------------------------------------------------------------------------------------

# group scope domain key — scope: user (defaults), host (defaults -currentHost), sys (sudo defaults).
# A group is skipped when its DEVBOX_INHERIT_HOST_* switch is off (see golden_group_enabled).
golden_capture_keys() {
  cat <<'EOF'
region     user NSGlobalDomain AppleLanguages
region     user NSGlobalDomain AppleLocale
region     user NSGlobalDomain AppleMeasurementUnits
region     user NSGlobalDomain AppleMetricUnits
region     user NSGlobalDomain AppleTemperatureUnit
region     user NSGlobalDomain AppleFirstWeekday
region     user NSGlobalDomain AppleICUForce24HourTime
region     user NSGlobalDomain AppleICUDateFormatStrings
region     user NSGlobalDomain AppleICUTimeFormatStrings
region     user NSGlobalDomain AppleICUNumberSymbols
region     sys  /Library/Preferences/.GlobalPreferences AppleLanguages
region     sys  /Library/Preferences/.GlobalPreferences AppleLocale
keyboard   user com.apple.HIToolbox AppleCurrentKeyboardLayoutInputSourceID
keyboard   user com.apple.HIToolbox AppleEnabledInputSources
keyboard   user com.apple.HIToolbox AppleSelectedInputSources
keyboard   user com.apple.HIToolbox AppleFnUsageType
keyboard   sys  /Library/Preferences/com.apple.HIToolbox AppleCurrentKeyboardLayoutInputSourceID
keyboard   sys  /Library/Preferences/com.apple.HIToolbox AppleEnabledInputSources
keyboard   sys  /Library/Preferences/com.apple.HIToolbox AppleSelectedInputSources
keyboard   sys  /Library/Preferences/com.apple.HIToolbox AppleInputSourceHistory
keyboard   user NSGlobalDomain ApplePressAndHoldEnabled
keyboard   user NSGlobalDomain AppleKeyboardUIMode
keyboard   user NSGlobalDomain com.apple.keyboard.fnState
keyboard   user NSGlobalDomain NSAutomaticCapitalizationEnabled
keyboard   user NSGlobalDomain NSAutomaticDashSubstitutionEnabled
keyboard   user NSGlobalDomain NSAutomaticPeriodSubstitutionEnabled
keyboard   user NSGlobalDomain NSAutomaticQuoteSubstitutionEnabled
keyboard   user NSGlobalDomain NSAutomaticSpellingCorrectionEnabled
keyboard   user NSGlobalDomain NSAutomaticTextCompletionEnabled
keyboard   user NSGlobalDomain WebAutomaticSpellingCorrectionEnabled
key_repeat user NSGlobalDomain KeyRepeat
key_repeat user NSGlobalDomain InitialKeyRepeat
appearance user NSGlobalDomain AppleInterfaceStyle
appearance user NSGlobalDomain AppleInterfaceStyleSwitchesAutomatically
appearance user NSGlobalDomain AppleAccentColor
appearance user NSGlobalDomain AppleHighlightColor
appearance user NSGlobalDomain AppleReduceDesktopTinting
appearance user NSGlobalDomain AppleShowScrollBars
appearance user NSGlobalDomain AppleShowAllExtensions
appearance user NSGlobalDomain AppleActionOnDoubleClick
appearance user NSGlobalDomain AppleSpacesSwitchOnActivate
appearance user NSGlobalDomain AppleWindowTabbingMode
appearance user NSGlobalDomain NSTableViewDefaultSizeMode
appearance user NSGlobalDomain NSDocumentSaveNewDocumentsToCloud
appearance user NSGlobalDomain NSNavPanelExpandedStateForSaveMode
appearance user NSGlobalDomain NSNavPanelExpandedStateForSaveMode2
appearance user NSGlobalDomain PMPrintingExpandedStateForPrint
appearance user NSGlobalDomain PMPrintingExpandedStateForPrint2
appearance user com.apple.WindowManager GloballyEnabled
appearance user com.apple.WindowManager EnableStandardClickToShowDesktop
appearance user com.apple.WindowManager StandardHideDesktopIcons
appearance user com.apple.WindowManager StandardHideWidgets
appearance user com.apple.WindowManager EnableTiledWindowMargins
appearance user com.apple.WindowManager EnableTilingByEdgeDrag
appearance user com.apple.WindowManager EnableTopTilingByEdgeDrag
appearance user com.apple.WindowManager EnableTilingOptionAccelerator
scroll     user NSGlobalDomain com.apple.swipescrolldirection
trackpad   user NSGlobalDomain com.apple.trackpad.scaling
trackpad   user NSGlobalDomain com.apple.trackpad.forceClick
trackpad   user NSGlobalDomain com.apple.mouse.scaling
trackpad   host NSGlobalDomain com.apple.mouse.tapBehavior
trackpad   host NSGlobalDomain com.apple.trackpad.enableSecondaryClick
trackpad   user com.apple.AppleMultitouchTrackpad Clicking
trackpad   user com.apple.AppleMultitouchTrackpad Dragging
trackpad   user com.apple.AppleMultitouchTrackpad DragLock
trackpad   user com.apple.AppleMultitouchTrackpad TrackpadRightClick
trackpad   user com.apple.AppleMultitouchTrackpad TrackpadCornerSecondaryClick
trackpad   user com.apple.AppleMultitouchTrackpad TrackpadThreeFingerDrag
trackpad   user com.apple.AppleMultitouchTrackpad TrackpadThreeFingerTapGesture
trackpad   user com.apple.AppleMultitouchTrackpad TrackpadThreeFingerHorizSwipeGesture
trackpad   user com.apple.AppleMultitouchTrackpad TrackpadThreeFingerVertSwipeGesture
trackpad   user com.apple.AppleMultitouchTrackpad TrackpadFourFingerHorizSwipeGesture
trackpad   user com.apple.AppleMultitouchTrackpad TrackpadFourFingerVertSwipeGesture
trackpad   user com.apple.AppleMultitouchTrackpad TrackpadFourFingerPinchGesture
trackpad   user com.apple.AppleMultitouchTrackpad TrackpadFiveFingerPinchGesture
trackpad   user com.apple.AppleMultitouchTrackpad TrackpadTwoFingerDoubleTapGesture
trackpad   user com.apple.AppleMultitouchTrackpad TrackpadTwoFingerFromRightEdgeSwipeGesture
trackpad   user com.apple.AppleMultitouchTrackpad TrackpadPinch
trackpad   user com.apple.AppleMultitouchTrackpad TrackpadRotate
trackpad   user com.apple.AppleMultitouchTrackpad TrackpadScroll
trackpad   user com.apple.AppleMultitouchTrackpad TrackpadHorizScroll
trackpad   user com.apple.AppleMultitouchTrackpad TrackpadMomentumScroll
trackpad   user com.apple.AppleMultitouchTrackpad TrackpadHandResting
trackpad   user com.apple.driver.AppleBluetoothMultitouch.trackpad Clicking
trackpad   user com.apple.driver.AppleBluetoothMultitouch.trackpad Dragging
trackpad   user com.apple.driver.AppleBluetoothMultitouch.trackpad DragLock
trackpad   user com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadRightClick
trackpad   user com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadCornerSecondaryClick
trackpad   user com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadThreeFingerDrag
dock       user com.apple.dock orientation
dock       user com.apple.dock tilesize
dock       user com.apple.dock largesize
dock       user com.apple.dock magnification
dock       user com.apple.dock autohide
dock       user com.apple.dock autohide-delay
dock       user com.apple.dock autohide-time-modifier
dock       user com.apple.dock show-recents
dock       user com.apple.dock minimize-to-application
dock       user com.apple.dock mru-spaces
dock       user com.apple.dock launchanim
dock       user com.apple.dock mineffect
dock       user com.apple.dock show-process-indicators
dock       user com.apple.dock scroll-to-open
dock       user com.apple.dock expose-group-apps
dock       user com.apple.dock wvous-tl-corner
dock       user com.apple.dock wvous-tl-modifier
dock       user com.apple.dock wvous-tr-corner
dock       user com.apple.dock wvous-tr-modifier
dock       user com.apple.dock wvous-bl-corner
dock       user com.apple.dock wvous-bl-modifier
dock       user com.apple.dock wvous-br-corner
dock       user com.apple.dock wvous-br-modifier
ui         user com.apple.finder ShowPathbar
ui         user com.apple.finder ShowStatusBar
ui         user com.apple.finder FXPreferredViewStyle
ui         user com.apple.finder FXDefaultSearchScope
ui         user com.apple.finder FXEnableExtensionChangeWarning
ui         user com.apple.finder _FXSortFoldersFirst
ui         user com.apple.finder AppleShowAllFiles
ui         user com.apple.finder ShowHardDrivesOnDesktop
ui         user com.apple.finder ShowExternalHardDrivesOnDesktop
ui         user com.apple.finder ShowRemovableMediaOnDesktop
ui         user com.apple.finder ShowMountedServersOnDesktop
ui         user com.apple.finder FXRemoveOldTrashItems
ui         user com.apple.desktopservices DSDontWriteNetworkStores
ui         user com.apple.desktopservices DSDontWriteUSBStores
ui         user com.apple.menuextra.clock ShowDate
ui         user com.apple.menuextra.clock ShowDayOfWeek
ui         user com.apple.menuextra.clock ShowAMPM
ui         user com.apple.menuextra.clock Show24Hour
ui         user com.apple.menuextra.clock ShowSeconds
ui         user com.apple.menuextra.clock IsAnalog
ui         user com.apple.menuextra.clock FlashDateSeparators
ui         user com.apple.screencapture type
ui         user com.apple.screencapture disable-shadow
ui         user com.apple.screencapture show-thumbnail
EOF
}

golden_group_enabled() {
  case "$1" in
    region)     is_truthy "${DEVBOX_INHERIT_HOST_REGION:-1}" ;;
    keyboard)   is_truthy "${DEVBOX_INHERIT_HOST_KEYBOARD:-1}" ;;
    key_repeat) is_truthy "${DEVBOX_INHERIT_HOST_KEY_REPEAT:-1}" ;;
    appearance) is_truthy "${DEVBOX_INHERIT_HOST_APPEARANCE:-1}" ;;
    scroll)     is_truthy "${DEVBOX_INHERIT_HOST_SCROLL_DIRECTION:-1}" ;;
    trackpad)   is_truthy "${DEVBOX_INHERIT_HOST_TRACKPAD:-1}" ;;
    dock)       is_truthy "${DEVBOX_INHERIT_HOST_DOCK:-1}" ;;
    ui)         is_truthy "${DEVBOX_INHERIT_HOST_UI:-1}" ;;
    *)          return 1 ;;
  esac
}

# Inner XML of a plist document, on one line.
golden_xml_fragment() { sed -e '1,/<plist/d' -e '/<\/plist>/d' | tr -d '\n\t'; }

# golden_emit_default <scope> <domain> <key> — prints one `defaults write` line if the key is set on this Mac
golden_emit_default() {
  local scope="$1" domain="$2" key="$3" sudo_prefix="" type val
  local -a d=(defaults)
  case "$scope" in
    host) d=(defaults -currentHost) ;;
    sys)  sudo_prefix="sudo " ;;
  esac
  "${d[@]}" read "$domain" "$key" >/dev/null 2>&1 || return 0
  type="$("${d[@]}" read-type "$domain" "$key" 2>/dev/null | sed 's/^Type is //')"
  case "$type" in
    boolean)
      if [[ "$("${d[@]}" read "$domain" "$key")" == 1 ]]; then val="-bool true"; else val="-bool false"; fi ;;
    integer) val="-int $("${d[@]}" read "$domain" "$key")" ;;
    float)   val="-float $("${d[@]}" read "$domain" "$key")" ;;
    string)  val="-string $(golden_shq "$("${d[@]}" read "$domain" "$key")")" ;;
    array | dictionary)
      val="$("${d[@]}" export "$domain" - | plutil -extract "$key" xml1 -o - - | golden_xml_fragment)" \
        || { printf '  # skipped %s %s: cannot export\n' "$domain" "$key"; return 0; }
      val="$(golden_shq "$val")" ;;
    *) printf '  # skipped %s %s: unsupported type "%s"\n' "$domain" "$key" "$type"; return 0 ;;
  esac
  printf '  %s%s write %s %s %s\n' "$sudo_prefix" "${d[*]}" "$domain" "$key" "$val"
}

cmd_capture() {
  local out="${STATE_DIR}/host-settings.sh" tmp group scope domain key k v
  local gitcfg="${STATE_DIR}/home/.gitconfig"
  golden_need defaults plutil git sw_vers
  mkdir -p "${STATE_DIR}"
  tmp="$(mktemp "${TMPDIR:-/tmp}/host-settings.XXXXXX")"

  {
    printf '# Generated by `devbox capture` on %s from macOS %s (%s).\n' "$(date '+%Y-%m-%d %H:%M')" "$(sw_vers -productVersion)" "$(uname -m)"
    printf '# Sourced by the golden image provisioning inside the VM. Edit freely, or run `devbox capture` again to refresh.\n\n'
    printf 'TIMEZONE=%s\n' "$(golden_shq "${DEVBOX_TIMEZONE:-}")"
    printf '# Expected values, checked after the reboot of the build\n'
    if golden_group_enabled keyboard; then
      printf 'EXPECT_INPUT_SOURCE=%s\n' "$(golden_shq "$(defaults read com.apple.HIToolbox AppleCurrentKeyboardLayoutInputSourceID 2>/dev/null || true)")"
    else
      printf "EXPECT_INPUT_SOURCE=''\n"
    fi
    if golden_group_enabled region; then
      printf 'EXPECT_LOCALE=%s\n' "$(golden_shq "$(defaults read NSGlobalDomain AppleLocale 2>/dev/null || true)")"
      printf 'EXPECT_LANGUAGES=%s\n\n' "$(golden_shq "$(defaults export NSGlobalDomain - | plutil -extract AppleLanguages json -o - - 2>/dev/null || true)")"
    else
      printf "EXPECT_LOCALE=''\nEXPECT_LANGUAGES=''\n\n"
    fi
    printf 'apply_host_settings() {\n'
    while read -r group scope domain key; do
      case "$group" in "" | \#*) continue ;; esac
      golden_group_enabled "$group" || continue
      golden_emit_default "$scope" "$domain" "$key"
    done < <(golden_capture_keys)
    printf '  :\n}\n'
  } >"$tmp"
  bash -n "$tmp" || { rm -f "$tmp"; die "the generated settings file is not valid bash"; }
  mv "$tmp" "$out"
  chmod 644 "$out"

  # git identity: only portable, non-secret settings (no credential helpers)
  rm -f "${gitcfg}" "${gitcfg}.new"
  if is_truthy "${DEVBOX_INHERIT_HOST_GITCONFIG:-1}"; then
    mkdir -p "${STATE_DIR}/home"
    for k in user.name user.email init.defaultBranch pull.rebase push.autoSetupRemote fetch.prune rebase.autoStash; do
      if v="$(git config --global --get "$k" 2>/dev/null)"; then git config --file "${gitcfg}.new" "$k" "$v"; fi
    done
    if [[ -s "${gitcfg}.new" ]]; then mv "${gitcfg}.new" "$gitcfg"; else rm -f "${gitcfg}.new"; fi
  fi

  log "Captured $(grep -cE '^  (sudo )?defaults ' "$out" || true) settings -> ${out#"${PROJECT_DIR}"/}"
  log "Keyboard layout $(defaults read com.apple.HIToolbox AppleCurrentKeyboardLayoutInputSourceID 2>/dev/null || echo '?'), time zone ${DEVBOX_TIMEZONE:-?}"
  if [[ -f "$gitcfg" ]]; then log "Git identity -> ${gitcfg#"${PROJECT_DIR}"/}"; fi
  return 0
}

# ---------------------------------------------------------------------------------------------
# build — the golden image
# ---------------------------------------------------------------------------------------------

# SSH into the guest with the well-known password; the askpass helper avoids needing sshpass.
golden_ssh_in() {
  SSH_ASKPASS="${GOLDEN_STAGE}/askpass" SSH_ASKPASS_REQUIRE=force DEVBOX_GUEST_PASSWORD="$GOLDEN_GUEST_PASSWORD" \
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o PubkeyAuthentication=no -o ConnectTimeout=8 -o ServerAliveInterval=15 -o ServerAliveCountMax=20 \
        "${GOLDEN_GUEST_USER}@${GOLDEN_GUEST_IP}" "$@"
}
golden_ssh() { golden_ssh_in "$@" </dev/null; }   # never swallows the caller's stdin

golden_start_vm() {
  tart run --no-graphics "$GOLDEN_BUILD_VM" >"$GOLDEN_VM_LOG" 2>&1 &
  GOLDEN_VM_PID=$!
}

golden_vm_alive() { [[ -n "$GOLDEN_VM_PID" ]] && kill -0 "$GOLDEN_VM_PID" 2>/dev/null; }

# golden_wait_for_ssh <seconds>
golden_wait_for_ssh() {
  local deadline=$((SECONDS + $1))
  while (( SECONDS < deadline )); do
    if ! golden_vm_alive; then
      tail -5 "$GOLDEN_VM_LOG" >&2
      die "the VM process exited unexpectedly (is the limit of two macOS VMs reached?)"
    fi
    GOLDEN_GUEST_IP="$(tart ip --wait 5 "$GOLDEN_BUILD_VM" 2>/dev/null || true)"
    if [[ -n "$GOLDEN_GUEST_IP" ]] && golden_ssh true 2>/dev/null; then return 0; fi
    sleep 3
  done
  die "the VM did not become reachable over SSH within $1 s"
}

golden_reboot_guest() {
  local before now deadline
  before="$(golden_ssh 'sysctl -n kern.boottime')"
  golden_ssh 'sudo shutdown -r now' >/dev/null 2>&1 || true
  sleep 15
  deadline=$((SECONDS + 420))
  while (( SECONDS < deadline )); do
    golden_vm_alive || golden_start_vm
    GOLDEN_GUEST_IP="$(tart ip --wait 5 "$GOLDEN_BUILD_VM" 2>/dev/null || true)"
    now="$(golden_ssh 'sysctl -n kern.boottime' 2>/dev/null || true)"
    if [[ -n "$now" && "$now" != "$before" ]]; then return 0; fi
    sleep 5
  done
  die "the VM did not come back after the reboot"
}

golden_poweroff_guest() {
  local deadline=$((SECONDS + 120))
  golden_ssh 'sudo shutdown -h now' >/dev/null 2>&1 || true
  while golden_vm_alive && (( SECONDS < deadline )); do sleep 2; done
  if golden_vm_alive; then tart stop "$GOLDEN_BUILD_VM" >/dev/null 2>&1 || true; fi
  deadline=$((SECONDS + 60))
  while golden_vm_running "$GOLDEN_BUILD_VM" && (( SECONDS < deadline )); do sleep 2; done
}

# Called from devbox's EXIT trap with the exit code: stops the build VM and removes the staging directory.
golden_cleanup() {
  local rc="$1"
  if golden_vm_alive; then
    tart stop "$GOLDEN_BUILD_VM" >/dev/null 2>&1 || true
    kill "$GOLDEN_VM_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$GOLDEN_STAGE" && -d "$GOLDEN_STAGE" ]]; then rm -rf "$GOLDEN_STAGE"; fi
  if (( GOLDEN_BUILDING == 1 && GOLDEN_BUILD_OK == 0 && rc != 0 )); then
    printf '\nBuild failed (exit %s). The build VM "%s" was kept; fix the cause and run: devbox build --resume\n' \
      "$rc" "$GOLDEN_BUILD_VM" >&2
  fi
}

# The configuration the guest-side scripts read (scripts/golden/provision.sh and verify.sh).
golden_write_guest_config() {
  local file="$1" app
  local -a apps=()
  if [[ -n "${DEVBOX_DOCK_APPS:-}" ]]; then IFS='|' read -r -a apps <<<"${DEVBOX_DOCK_APPS}"; fi
  {
    printf 'INSTALL_BREWFILE=1\n'
    printf 'TRUST_BREWFILE_APPS=%s\n' "$(golden_flag "${DEVBOX_TRUST_BREWFILE_APPS:-1}")"
    printf 'INSTALL_ROSETTA=%s\n' "$(golden_flag "${DEVBOX_INSTALL_ROSETTA:-1}")"
    printf 'INSTALL_GUEST_AGENT=1\n'
    printf 'ENABLE_GATEKEEPER=%s\n' "$(golden_flag "${DEVBOX_ENABLE_GATEKEEPER:-1}")"
    printf 'GROW_DISK=%s\n' "$GOLDEN_GROW"
    printf 'DISK_GB=%s\n' "${TART_DISK_GB:-0}"
    printf 'DOCK_APPS=(\n'
    for app in ${apps[@]+"${apps[@]}"}; do
      [[ -n "$app" ]] && printf '  %s\n' "$(golden_shq "$app")"
    done
    printf ')\n'
  } >"$file"
}

golden_build() {
  local resume=0 host_major img_major free digest agent_tag="" guest_os tries=0 current_disk
  case "${1:-}" in
    --resume) resume=1 ;;
    "") ;;
    *) die "unknown option: $1" ;;
  esac
  golden_need ssh curl shasum tar plutil perl
  [[ -n "${DEVBOX_GOLDEN_IMAGE:-}" ]] || die "DEVBOX_GOLDEN_IMAGE is not set"
  export TART_NO_AUTO_PRUNE=1   # never let Tart delete cached images or VMs behind our back to make room

  host_major="$(sw_vers -productVersion | cut -d. -f1)"
  img_major="$(golden_image_major "$DEVBOX_GOLDEN_IMAGE")"
  (( img_major <= host_major )) || die "${DEVBOX_GOLDEN_IMAGE} is macOS ${img_major}, but this Mac runs macOS ${host_major}"
  free="$(golden_free_gb)"
  (( free >= ${DEVBOX_MIN_FREE_GB:-25} )) \
    || die "only ${free} GB free in $(golden_tart_home) (need ${DEVBOX_MIN_FREE_GB:-25}); free space ('tart delete <vm>', 'tart prune') or set DEVBOX_MIN_FREE_GB"

  mkdir -p "${STATE_DIR}"
  exec > >(tee "${STATE_DIR}/build.log") 2>&1   # everything below is also written to .devbox/build.log
  GOLDEN_BUILDING=1
  GOLDEN_BUILD_VM="${DEVBOX_GOLDEN_NAME}-build"
  GOLDEN_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/devbox-golden.XXXXXX")"
  GOLDEN_VM_LOG="${GOLDEN_STAGE}/vm.log"
  printf '#!/bin/sh\nprintf "%%s\\n" "$DEVBOX_GUEST_PASSWORD"\n' >"${GOLDEN_STAGE}/askpass"
  chmod 700 "${GOLDEN_STAGE}/askpass"

  [[ -f "${STATE_DIR}/host-settings.sh" ]] || { log "No captured host settings yet"; cmd_capture; }

  log "Pulling ${DEVBOX_GOLDEN_IMAGE}"
  tart pull "$DEVBOX_GOLDEN_IMAGE"
  digest="$(golden_oci_digest "$DEVBOX_GOLDEN_IMAGE")"

  if (( resume )) && golden_vm_exists "$GOLDEN_BUILD_VM"; then
    log "Resuming build VM '${GOLDEN_BUILD_VM}'"
    if golden_vm_running "$GOLDEN_BUILD_VM"; then tart stop "$GOLDEN_BUILD_VM" >/dev/null 2>&1 || true; sleep 3; fi
  else
    if golden_vm_exists "$GOLDEN_BUILD_VM"; then log "Removing stale build VM '${GOLDEN_BUILD_VM}'"; tart delete "$GOLDEN_BUILD_VM"; fi
    log "Cloning ${DEVBOX_GOLDEN_IMAGE} -> ${GOLDEN_BUILD_VM}"
    tart clone "$DEVBOX_GOLDEN_IMAGE" "$GOLDEN_BUILD_VM"
    tart set "$GOLDEN_BUILD_VM" --cpu "$TART_CPU" --memory "$TART_MEMORY_MB" --display "$TART_DISPLAY"
    if is_truthy "${DEVBOX_DISPLAY_REFIT:-1}"; then tart set "$GOLDEN_BUILD_VM" --display-refit; else tart set "$GOLDEN_BUILD_VM" --no-display-refit; fi
  fi

  # Growing the disk: the recovery partition has to go (it sits right behind the system container),
  # and the guest daemon then grows the container at boot. Done offline once the build is finished.
  GOLDEN_GROW=0
  if [[ "${TART_DISK_GB:-}" =~ ^[0-9]+$ ]] && (( TART_DISK_GB > GOLDEN_BASE_DISK_GB )); then GOLDEN_GROW=1; fi

  log "Staging provisioning files"
  mkdir -p "${GOLDEN_STAGE}/provision/downloads" "${GOLDEN_STAGE}/provision/home"
  cp "${INSTALL_DIR}/scripts/golden/provision.sh" "${INSTALL_DIR}/scripts/golden/verify.sh" "${GOLDEN_STAGE}/provision/"
  chmod +x "${GOLDEN_STAGE}/provision/"*.sh
  golden_write_guest_config "${GOLDEN_STAGE}/provision/config.env"
  cp "${DEVBOX_BREWFILE_ABS}" "${GOLDEN_STAGE}/provision/Brewfile"
  cp "${STATE_DIR}/host-settings.sh" "${GOLDEN_STAGE}/provision/host-settings.sh"
  if [[ -d "${STATE_DIR}/home" ]]; then cp -R "${STATE_DIR}/home/." "${GOLDEN_STAGE}/provision/home/"; fi
  agent_tag="$(golden_fetch_release_asset openai/tart-guest-agent tart-guest-agent-darwin-all.tar.gz "${GOLDEN_STAGE}/agent.tgz")"
  tar -xzf "${GOLDEN_STAGE}/agent.tgz" -C "${GOLDEN_STAGE}/provision/downloads" tart-guest-agent
  rm -f "${GOLDEN_STAGE}/agent.tgz"
  log "Guest agent ${agent_tag} (checksum verified)"

  log "Booting the build VM (headless)"
  golden_start_vm
  golden_wait_for_ssh 300
  log "Guest reachable at ${GOLDEN_GUEST_IP}"

  log "Uploading provisioning files"
  COPYFILE_DISABLE=1 tar --no-xattrs -C "$GOLDEN_STAGE" -cf - provision | golden_ssh_in 'rm -rf ~/provision && tar -C ~ -xf -'

  log "Provisioning inside the VM (the long part: Homebrew + programs)"
  golden_ssh "cd ~/provision && TART_MACOS_BASE_IMAGE=$(golden_shq "$DEVBOX_GOLDEN_IMAGE") TART_MACOS_BASE_DIGEST=$(golden_shq "$digest") TART_MACOS_TART_VERSION=$(golden_shq "$(tart --version)") TART_MACOS_AGENT_VERSION=$(golden_shq "$agent_tag") ./provision.sh"

  log "Rebooting so keyboard, language and Dock settings take effect"
  golden_reboot_guest

  log "Verifying the result"
  golden_ssh 'cd ~/provision && ./verify.sh'
  until tart exec "$GOLDEN_BUILD_VM" /usr/bin/true 2>/dev/null; do
    (( ++tries < 20 )) || die "the guest agent does not answer 'tart exec'"
    sleep 3
  done
  echo "  ok   tart exec works (guest agent reachable)"
  guest_os="$(golden_ssh 'sw_vers -productVersion; sw_vers -buildVersion' | paste -sd' ' -)"

  if (( GOLDEN_GROW )); then
    log "Shutting the build VM down to enlarge its disk to ${TART_DISK_GB} GB"
    golden_poweroff_guest
    current_disk="$(golden_vm_disk_gb "$GOLDEN_BUILD_VM")"
    if (( TART_DISK_GB > current_disk )); then tart set "$GOLDEN_BUILD_VM" --disk-size "$TART_DISK_GB"; fi
    perl "${INSTALL_DIR}/scripts/golden/gpt-delete-recovery.pl" "$(golden_tart_home)/vms/${GOLDEN_BUILD_VM}/disk.img"
    log "Booting once more so the guest daemon can grow the system container"
    golden_start_vm
    golden_wait_for_ssh 300
    golden_ssh 'cd ~/provision && ./verify.sh disk'
  fi
  golden_ssh 'rm -rf ~/provision'

  log "Shutting the build VM down"
  golden_poweroff_guest

  if golden_vm_exists "$DEVBOX_GOLDEN_NAME"; then log "Replacing previous golden image '${DEVBOX_GOLDEN_NAME}'"; tart delete "$DEVBOX_GOLDEN_NAME"; fi
  tart rename "$GOLDEN_BUILD_VM" "$DEVBOX_GOLDEN_NAME"
  {
    echo "built_at=$(date '+%Y-%m-%dT%H:%M:%S%z')"
    echo "base_image=${DEVBOX_GOLDEN_IMAGE}"
    echo "base_digest=${digest}"
    echo "guest_macos=${guest_os}"
    echo "disk_gb=$(golden_vm_disk_gb "$DEVBOX_GOLDEN_NAME")"
    echo "devbox=${DEVBOX_VERSION}"
    echo "tart=$(tart --version)"
    echo "guest_agent=${agent_tag}"
  } >"${STATE_DIR}/last-build"
  GOLDEN_BUILD_OK=1
  log "Golden image '${DEVBOX_GOLDEN_NAME}' is ready (macOS ${guest_os}, $(golden_free_gb) GB free on this Mac)."
  log "Next: devbox up"
}

# ---------------------------------------------------------------------------------------------
# up — clone the golden image on first use, then open the working VM
# ---------------------------------------------------------------------------------------------

golden_clone_working_vm() {
  local current
  export TART_NO_AUTO_PRUNE=1
  log "Cloning '${DEVBOX_GOLDEN_NAME}' -> '${TART_VM_NAME}'"
  tart clone "$DEVBOX_GOLDEN_NAME" "$TART_VM_NAME"
  tart set "$TART_VM_NAME" --cpu "$TART_CPU" --memory "$TART_MEMORY_MB"
  if is_truthy "${DEVBOX_DISPLAY_REFIT:-1}"; then tart set "$TART_VM_NAME" --display-refit; else tart set "$TART_VM_NAME" --no-display-refit; fi
  current="$(golden_vm_disk_gb "$TART_VM_NAME")"
  if [[ "${TART_DISK_GB:-}" =~ ^[0-9]+$ ]] && (( TART_DISK_GB > current )); then
    log "Enlarging the disk to ${TART_DISK_GB} GB (the guest grows it at boot)"
    tart set "$TART_VM_NAME" --disk-size "$TART_DISK_GB"
  fi
}

golden_up() {
  local fresh=0 rebuild=0 assume_yes=0 arg answer
  for arg in "$@"; do
    case "$arg" in
      --fresh) fresh=1 ;;
      --rebuild) rebuild=1 ;;
      -y | --yes) assume_yes=1 ;;
      *) die "unknown option: ${arg}" ;;
    esac
  done

  if (( rebuild )) || ! golden_vm_exists "$DEVBOX_GOLDEN_NAME"; then
    if (( ! rebuild )); then log "There is no golden image '${DEVBOX_GOLDEN_NAME}' yet. Building it first (several minutes, once)."; fi
    golden_build
  fi

  if (( fresh )) && vm_exists; then
    if golden_vm_running "$TART_VM_NAME"; then die "'${TART_VM_NAME}' is running; stop it first"; fi
    if (( ! assume_yes )); then
      read -r -p "Delete '${TART_VM_NAME}' (everything inside it is lost) and re-clone it from '${DEVBOX_GOLDEN_NAME}'? [y/N] " answer
      [[ "$answer" == [yY] ]] || die "aborted"
    fi
    tart delete "$TART_VM_NAME"
  fi
  vm_exists || golden_clone_working_vm
  run_vm_gui
}

golden_require_ephemeral() {
  if golden_mode; then
    die "'devbox $1' applies to ephemeral mode. In golden mode the configuration is baked into the image: 'devbox build' updates it, 'devbox up --fresh' adopts it."
  fi
}

golden_status() {
  echo
  if [[ -f "${STATE_DIR}/last-build" ]]; then
    echo "Golden image '${DEVBOX_GOLDEN_NAME}', last build:"
    sed 's/^/  /' "${STATE_DIR}/last-build"
  elif golden_vm_exists "$DEVBOX_GOLDEN_NAME"; then
    echo "Golden image '${DEVBOX_GOLDEN_NAME}' exists (built outside this project directory, no build record here)"
  else
    echo "No golden image '${DEVBOX_GOLDEN_NAME}' yet: run 'devbox build' (or 'devbox up', which builds it first)"
  fi
}
