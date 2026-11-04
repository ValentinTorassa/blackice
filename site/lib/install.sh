#!/bin/sh
# Installs blackice on a Mac:
#
#   curl -fsSL https://blackice-macos.vercel.app/install.sh | sh
#
# Downloads the release zip and its checksum from GitHub, checks the checksum, the app's signature
# and Gatekeeper's assessment (the checks of docs/install.md, step 1), copies Blackice.app to
# /Applications and writes a `blackice` command to ~/.local/bin. It starts nothing: no extension,
# no daemon. Options go after `sh -s --`:
#
#   --force   replace an installed Blackice.app of another version
#
# BLACKICE_BIN_DIR picks another folder for the command. BLACKICE_ZIP=/path/to/Blackice-<version>.zip
# installs a build that is not published yet, from that zip and the .sha256 file next to it, with
# the same checks. The site serves this file at
# /install.sh, and its build fails when VERSION differs from site/lib/release.ts.

set -eu

VERSION=0.3.2
REPOSITORY=ValentinTorassa/blackice
TEAM_ID=M294LK997M
IDENTIFIER=com.valentorassa.blackice
APP=/Applications/Blackice.app
EXECUTABLE=$APP/Contents/MacOS/blackice
SCRIPT_URL=https://blackice-macos.vercel.app/install.sh
GUIDE=https://blackice-macos.vercel.app/docs/install

say() { printf '%s\n' "$*"; }
fail() {
  printf 'blackice install: %s\n' "$*" >&2
  exit 1
}

usage() {
  say "Installs blackice $VERSION to /Applications."
  say ""
  say "  curl -fsSL $SCRIPT_URL | sh"
  say "  curl -fsSL $SCRIPT_URL | sh -s -- --force    # replace an installed copy"
  say ""
  say "BLACKICE_BIN_DIR sets the folder for the blackice command (default ~/.local/bin)."
  say "BLACKICE_ZIP installs an unpublished Blackice-$VERSION.zip, with its .sha256 beside it."
  say "Guide: $GUIDE"
}

check_system() {
  [ "$(uname -s)" = Darwin ] || fail "blackice runs on macOS only"
  # hw.optional.arm64 is 1 on Apple silicon, also in a terminal running under Rosetta.
  [ "$(uname -m)" = arm64 ] || [ "$(/usr/sbin/sysctl -in hw.optional.arm64 2>/dev/null)" = 1 ] \
    || fail "the blackice build is for Apple silicon (arm64) only"
  macos=$(/usr/bin/sw_vers -productVersion)
  [ "${macos%%.*}" -ge 14 ] 2>/dev/null || fail "blackice needs macOS 14 or later; this Mac has $macos"
  [ "$(id -u)" -ne 0 ] || fail "run this as your user, without sudo"
  for prefix in "${HOMEBREW_PREFIX:-/opt/homebrew}" /opt/homebrew /usr/local; do
    [ ! -d "$prefix/Caskroom/blackice" ] \
      || fail "blackice is installed with Homebrew; to upgrade it, run \`brew upgrade --cask blackice\`"
  done
}

# Downloads $1 to $2 over HTTPS only, redirects included.
fetch() {
  /usr/bin/curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --retry 2 --connect-timeout 20 --max-time 900 --max-filesize 209715200 \
    --user-agent "blackice-install/$VERSION" --output "$2" "$1" \
    || fail "could not download $1"
}

# Downloads the release into $work and checks it. Sets $app to the checked Blackice.app.
download_and_check() {
  zip=Blackice-$VERSION.zip
  base=https://github.com/$REPOSITORY/releases/download/v$VERSION

  if [ -n "${BLACKICE_ZIP:-}" ]; then
    [ "${BLACKICE_ZIP##*/}" = "$zip" ] || fail "BLACKICE_ZIP should name $zip, the zip of blackice $VERSION"
    say "Using $BLACKICE_ZIP.sha256, a build that is not published"
    /bin/cp "$BLACKICE_ZIP.sha256" "$work/$zip.sha256" || fail "could not read $BLACKICE_ZIP.sha256"
  else
    say "Downloading $base/$zip.sha256"
    fetch "$base/$zip.sha256" "$work/$zip.sha256"
  fi
  expected='' name=''
  read -r expected name < "$work/$zip.sha256" || true
  lines=$(wc -l < "$work/$zip.sha256" | tr -d ' ')
  case $expected in *[!0-9a-f]*) expected='' ;; esac
  if [ "$lines" -gt 1 ] || [ ${#expected} -ne 64 ] || { [ "$name" != "$zip" ] && [ "$name" != "*$zip" ]; }; then
    fail "$zip.sha256 should be one line with the SHA-256 of $zip"
  fi

  if [ -n "${BLACKICE_ZIP:-}" ]; then
    say "Using $BLACKICE_ZIP"
    /bin/cp "$BLACKICE_ZIP" "$work/$zip" || fail "could not read $BLACKICE_ZIP"
  else
    say "Downloading $base/$zip"
    fetch "$base/$zip" "$work/$zip"
  fi
  actual=$(/usr/bin/shasum -a 256 "$work/$zip")
  actual=${actual%% *}
  [ "$actual" = "$expected" ] || fail "$zip has SHA-256 $actual, but $zip.sha256 says $expected"
  say "  SHA-256: $actual, as $zip.sha256 says"

  /usr/bin/ditto -x -k "$work/$zip" "$work/unpacked" || fail "ditto could not unpack $zip"
  entries=$(ls -A "$work/unpacked")
  [ "$entries" = Blackice.app ] || fail "the zip should hold only Blackice.app; it holds: $entries"
  app=$work/unpacked/Blackice.app

  say "Checking Blackice.app"
  verify=$(/usr/bin/codesign --verify --strict --deep --verbose=2 "$app" 2>&1) \
    || fail "codesign --verify failed: $verify"
  say "  signature: valid, and satisfies its Designated Requirement"

  details=$(/usr/bin/codesign -dvv "$app" 2>&1) || fail "codesign -dvv failed: $details"
  identifier=$(printf '%s\n' "$details" | sed -n 's/^Identifier=//p' | head -n 1)
  team=$(printf '%s\n' "$details" | sed -n 's/^TeamIdentifier=//p' | head -n 1)
  leaf=$(printf '%s\n' "$details" | grep '^Authority=' | head -n 1 || true)
  [ "$identifier" = "$IDENTIFIER" ] || fail "the app is signed as ${identifier:-nothing}, not $IDENTIFIER"
  [ "$team" = "$TEAM_ID" ] || fail "the app is signed by team ${team:-none}, not $TEAM_ID"
  case $leaf in
    "Authority=Developer ID Application:"*"($TEAM_ID)") ;;
    *) fail "the app is not signed with a Developer ID Application certificate of team $TEAM_ID" ;;
  esac
  say "  signed by: Developer ID Application, team $TEAM_ID"

  assessment=$(/usr/sbin/spctl --assess --type execute -vv "$app" 2>&1) \
    || fail "Gatekeeper rejects the app: $assessment"
  printf '%s\n' "$assessment" | grep -q ': accepted$' || fail "Gatekeeper does not accept the app: $assessment"
  printf '%s\n' "$assessment" | grep -qx 'source=Notarized Developer ID' \
    || fail "Gatekeeper does not see a notarized Developer ID app: $assessment"
  origin=$(printf '%s\n' "$assessment" | sed -n 's/^origin=//p' | head -n 1)
  case $origin in
    '' | *"($TEAM_ID)") ;;
    *) fail "Gatekeeper names another origin: $origin" ;;
  esac
  say "  Gatekeeper: accepted, source=Notarized Developer ID"
}

# Copies the checked app to /Applications, replacing an installed copy if $replace is 1.
install_app() {
  if [ "$replace" = 1 ]; then
    say "Removing the installed $APP"
    rm -rf "$APP" || fail "could not remove $APP. Replacing an app needs App Management for your terminal:" \
      "System Settings > Privacy & Security > App Management."
  fi
  /usr/bin/ditto "$app" "$APP" || fail "could not copy Blackice.app to /Applications (it needs an admin account)"
  say "Blackice.app $VERSION is in /Applications."
}

# Writes the blackice command: a script that runs the app's executable by its full path, since
# started through a symbolic link the command refuses to run. Leaves any other file there alone.
install_command() {
  bin_dir=${BLACKICE_BIN_DIR:-$HOME/.local/bin}
  cmd=$bin_dir/blackice
  wrapper="#!/bin/sh
exec $EXECUTABLE \"\$@\""
  if [ -e "$cmd" ] || [ -L "$cmd" ]; then
    if [ "$(cat "$cmd" 2>/dev/null)" != "$wrapper" ]; then
      say "$cmd is already there and is not this installer's; left it as it is."
      say "Run $EXECUTABLE by its full path, or put its folder on your PATH."
      return
    fi
  else
    mkdir -p "$bin_dir" || fail "could not create $bin_dir"
    printf '%s\n' "$wrapper" > "$cmd" || fail "could not write $cmd"
    chmod 755 "$cmd"
    say "Wrote $cmd, which runs $EXECUTABLE."
  fi
  case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *)
      say ""
      say "$bin_dir is not on your PATH. Add it, for example in ~/.zshrc:"
      say "  export PATH=\"$bin_dir:\$PATH\""
      ;;
  esac
}

next_steps() {
  say ""
  say "Next:"
  say "  1. Run \`blackice start\`. The first time, it asks a few questions to write"
  say "     ~/.config/blackice/blackice.toml, then opens System Settings so you can allow the extension."
  say "  2. \`blackice agent install\` starts the daemon that runs your hooks in ask mode."
  say ""
  say "Before removing the app, run \`blackice agent uninstall\` and \`blackice stop\`."
  if [ "$replace" = 1 ]; then
    say ""
    say "You replaced an installed copy: run \`blackice start\`, then restart the Mac, then run"
    say "\`blackice agent uninstall\` and \`blackice agent install\` so that the daemon runs the new binary."
  fi
  say ""
  say "Install guide: $GUIDE"
}

main() {
  force=0
  for arg in "$@"; do
    case $arg in
      --force) force=1 ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) fail "unknown option: $arg (see --help)" ;;
    esac
  done

  check_system

  replace=0
  if [ -e "$APP" ]; then
    installed=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || true)
    if [ "$installed" = "$VERSION" ] && [ "$force" = 0 ]; then
      say "Blackice.app $VERSION is already in /Applications."
      install_command
      exit 0
    fi
    [ "$force" = 1 ] || fail "$APP ${installed:-(unknown version)} is already there. To replace it with $VERSION, run" \
      "\`curl -fsSL $SCRIPT_URL | sh -s -- --force\`, then \`blackice start\`, and restart the Mac."
    replace=1
  fi

  work=$(mktemp -d "${TMPDIR:-/tmp}/blackice-install.XXXXXX")
  trap 'rm -rf "$work"' EXIT
  trap 'exit 1' HUP INT TERM

  download_and_check
  install_app
  install_command
  next_steps
}

# Everything above only defines; nothing runs until the whole script has arrived.
main "$@"
