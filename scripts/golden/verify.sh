#!/bin/bash
# Checks inside the VM. Exits non-zero if one fails, which fails the build.
#   ./verify.sh        after the reboot that follows provisioning
#   ./verify.sh disk   after the disk was enlarged (the guest daemon grows the system container at boot)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=/dev/null
source ./config.env
# shellcheck source=/dev/null
source ./host-settings.sh
BREW=/opt/homebrew/bin/brew

fails=0
ok()   { printf '  ok   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; fails=$((fails + 1)); }
note() { printf '  note %s\n' "$*"; }
check() { # <what> <expected> <actual>
  if [[ $2 == "$3" ]]; then ok "$1: $3"; else bad "$1: expected '$2', got '$3'"; fi
}

finish() {
  if ((fails > 0)); then printf '\n%d check(s) failed.\n' "$fails"; exit 1; fi
  printf '\nAll checks passed.\n'
}

disk_checks() {
  [[ ${GROW_DISK:-0} == 1 ]] || { note "disk growth is off"; return; }
  local size=0 want i
  want=$((${DISK_GB:-0} * 1000 * 1000 * 1000 * 9 / 10))
  # the daemon needs a few seconds after boot
  for i in $(seq 1 40); do
    size=$(diskutil info -plist / | plutil -extract APFSContainerSize raw -o - - 2>/dev/null || echo 0)
    ((size >= want)) && break
    sleep 3
  done
  if ((size >= want)); then ok "system container grown to $((size / 1000000000)) GB"; else bad "system container is only $((size / 1000000000)) GB, expected about ${DISK_GB} GB"; fi
  printf '  free: %s\n' "$(df -h / | tail -1 | awk '{ print $4 " of " $2 }')"
}

main_checks() {
  printf 'macOS %s (%s)\n' "$(sw_vers -productVersion)" "$(sw_vers -buildVersion)"

  # The active keyboard layout can only be asked from inside the auto-login GUI session.
  for _ in $(seq 1 45); do pgrep -u "$(id -u)" -x Finder >/dev/null && break; sleep 2; done

  if [[ -n ${EXPECT_INPUT_SOURCE:-} ]]; then
    check "keyboard layout (user setting)" "$EXPECT_INPUT_SOURCE" "$(defaults read com.apple.HIToolbox AppleCurrentKeyboardLayoutInputSourceID 2>/dev/null)"
    check "keyboard layout (login window)" "$EXPECT_INPUT_SOURCE" "$(defaults read /Library/Preferences/com.apple.HIToolbox AppleCurrentKeyboardLayoutInputSourceID 2>/dev/null)"
    active=$(sudo launchctl asuser "$(id -u)" osascript -l JavaScript -e \
      'ObjC.import("Carbon"); const s = $.TISCopyCurrentKeyboardLayoutInputSource(); ObjC.unwrap(ObjC.castRefToObject($.TISGetInputSourceProperty(s, $.kTISPropertyInputSourceID)))' 2>/dev/null || true)
    if [[ -n $active ]]; then
      check "keyboard layout (active in the session)" "$EXPECT_INPUT_SOURCE" "$active"
    else
      note "the active keyboard layout could not be queried"
    fi
  fi
  [[ -z ${EXPECT_LOCALE:-} ]] || check "region/locale" "$EXPECT_LOCALE" "$(defaults read NSGlobalDomain AppleLocale 2>/dev/null)"
  [[ -z ${EXPECT_LANGUAGES:-} ]] || check "languages" "$EXPECT_LANGUAGES" "$(defaults export NSGlobalDomain - | plutil -extract AppleLanguages json -o - - 2>/dev/null)"
  [[ -z ${TIMEZONE:-} ]] || check "time zone" "$TIMEZONE" "$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')"

  if [[ ${ENABLE_GATEKEEPER:-1} == 1 ]]; then
    check "Gatekeeper" "assessments enabled" "$(spctl --status 2>&1)"
  fi
  if [[ ${INSTALL_ROSETTA:-0} == 1 ]]; then
    if [[ -f /Library/Apple/usr/libexec/oah/libRosettaRuntime ]]; then ok "Rosetta 2 installed"; else bad "Rosetta 2 missing"; fi
  fi
  if [[ ${INSTALL_GUEST_AGENT:-0} == 1 ]]; then
    if launchctl print "gui/$(id -u)/org.cirruslabs.tart-guest-agent" 2>/dev/null | grep -q 'state = running'; then
      ok "guest agent running"
    else
      bad "guest agent is not running"
    fi
  fi
  if [[ ${GROW_DISK:-0} == 1 ]]; then
    if sudo launchctl print system/org.cirruslabs.tart-guest-daemon 2>/dev/null | grep -q 'state = running'; then
      ok "guest daemon running"
    else
      bad "guest daemon is not running"
    fi
  fi
  if [[ ${INSTALL_BREWFILE:-1} == 1 ]]; then
    eval "$($BREW shellenv)"
    # `brew bundle check` would start VS Code to list extensions, which blocks on the Gatekeeper
    # confirmation dialog nobody can click in an unattended build. So leave `vscode` lines out here
    # and look for the extensions on disk instead.
    chk=$(mktemp -d)
    grep -v '^vscode ' Brewfile >"$chk/Brewfile"
    if brew bundle check --file "$chk/Brewfile" >/dev/null 2>&1; then
      ok "all Brewfile formulae and casks installed"
    else
      bad "Brewfile programs missing: $(brew bundle check --file "$chk/Brewfile" 2>&1 | tail -5 | tr '\n' ' ')"
    fi
    rm -rf "$chk"
    if [[ ${TRUST_BREWFILE_APPS:-1} == 1 && -d "/Applications/Visual Studio Code.app" ]]; then
      # canary: with Gatekeeper on, an untrusted app would hang here on a dialog (perl: poor man's timeout)
      if perl -e 'alarm 45; exec @ARGV' code --list-extensions >/dev/null 2>&1; then ok "VS Code starts without a Gatekeeper dialog"; else bad "VS Code did not start unattended (Gatekeeper dialog?)"; fi
    fi
    for ext in $(sed -n 's/^vscode "\([^"]*\)".*/\1/p' Brewfile); do
      lower=$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')
      if compgen -G "$HOME/.vscode/extensions/$lower-*" >/dev/null; then ok "VS Code extension $ext"; else bad "VS Code extension $ext missing"; fi
    done
  fi

  want=0
  for app in ${DOCK_APPS[@]+"${DOCK_APPS[@]}"}; do [[ -d $app ]] && want=$((want + 1)); done
  if ((${#DOCK_APPS[@]} > 0)); then
    check "Dock items" "$want" "$(defaults export com.apple.dock - | plutil -extract persistent-apps raw -o - - 2>/dev/null)"
  fi
}

case "${1:-all}" in
  disk) disk_checks ;;
  all)  main_checks ;;
  *)    echo "usage: $0 [all|disk]" >&2; exit 2 ;;
esac
finish
