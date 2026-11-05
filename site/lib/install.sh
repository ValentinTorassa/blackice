#!/bin/sh
# Installs blackice on a Mac:
#
#   curl -fsSL https://blackice-macos.vercel.app/install.sh | sh
#
# Downloads the release zip and its checksum from GitHub, checks the checksum, the app's signature
# and Gatekeeper's assessment (the checks of docs/install.md, step 1) and that the app is version
# VERSION, copies Blackice.app to /Applications and writes a `blackice` command to ~/.local/bin.
# It starts nothing: no extension, no daemon. Options go after `sh -s --`:
#
#   --force   replace an installed Blackice.app of another version, unless it has a higher build
#
# BLACKICE_BIN_DIR picks another folder for the command. BLACKICE_ZIP=/path/to/Blackice-<version>.zip
# installs a build that is not published yet, from that zip and the .sha256 file next to it, with
# the same checks. BLACKICE_APPLICATIONS=/absolute/folder puts Blackice.app there instead of
# /Applications, for tests: macOS activates the extension only from /Applications. The site serves
# this file at /install.sh, and its build fails when VERSION differs from site/lib/release.ts.

set -eu

VERSION=0.4.3
REPOSITORY=ValentinTorassa/blackice
TEAM_ID=M294LK997M
IDENTIFIER=com.valentorassa.blackice
EXTENSION=Contents/Library/SystemExtensions/com.valentorassa.blackice.filter.systemextension
APPLICATIONS=${BLACKICE_APPLICATIONS:-/Applications}
APP=$APPLICATIONS/Blackice.app
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
  say "BLACKICE_APPLICATIONS puts Blackice.app in another folder, for tests."
  say "Guide: $GUIDE"
}

# Prints the value of key $2 in the Info.plist of bundle $1, or nothing.
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true; }

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

# Downloads the release into $work and checks it. Sets $app to the checked Blackice.app and
# $build to its build number.
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

  # The signature covers Info.plist, so these are the versions the release was signed with. Another
  # validly signed build under this zip's name, such as an older release, stops here.
  version=$(plist "$app" CFBundleShortVersionString)
  build=$(plist "$app" CFBundleVersion)
  [ "$version" = "$VERSION" ] || fail "the zip holds Blackice.app ${version:-of no version}, not $VERSION"
  case $build in
    '' | 0* | *[!0-9]*) fail "the app's build number is ${build:-missing}, not a positive whole number" ;;
  esac
  if [ "$(plist "$app/$EXTENSION" CFBundleShortVersionString)" != "$VERSION" ] \
    || [ "$(plist "$app/$EXTENSION" CFBundleVersion)" != "$build" ]; then
    fail "the network extension inside the app is not version $VERSION, build $build, as the app is"
  fi
  say "  version: $VERSION, build $build"
}

# Stops if the installed app has a higher build number than the checked one: macOS replaces an
# activated extension only with the same or a higher build, so the older app could not start.
check_not_older() {
  case $installed_build in
    '' | *[!0-9]*) return ;;
  esac
  [ "$installed_build" -le "$build" ] || fail "$APP is build $installed_build, newer than build $build of" \
    "$VERSION. To go back to an older build, uninstall blackice first, as the guide says: $GUIDE"
}

# Puts the checked app at $APP, replacing an installed copy if $replace is 1. The app is copied
# into a new folder beside $APP, $stage, and the copy is checked there. Then the installed copy is
# renamed into $stage and the new one renamed to $APP. Renaming within a folder is one step, and if
# anything stops the script after the installed copy was renamed, cleanup renames it back. The
# previous copy is removed only once the new one is in place.
install_app() {
  stage=$(mktemp -d "$APPLICATIONS/.blackice-install.XXXXXX") \
    || fail "could not write to $APPLICATIONS (it needs an admin account)"
  /usr/bin/ditto "$app" "$stage/Blackice.app" || fail "could not copy Blackice.app to $APPLICATIONS"
  verify=$(/usr/bin/codesign --verify --strict --deep "$stage/Blackice.app" 2>&1) \
    || fail "the copy of Blackice.app in $APPLICATIONS does not verify: $verify"

  if [ "$replace" = 1 ]; then
    say "Replacing the installed $APP"
    # Set before the rename, so that cleanup finds it whenever the rename happened.
    previous=$stage/previous.app
    if ! mv "$APP" "$previous"; then
      previous=''
      fail "could not move $APP. Replacing an app needs App Management for your terminal:" \
        "System Settings > Privacy & Security > App Management."
    fi
  fi
  # mv onto a folder would move the app into it.
  if [ -e "$APP" ] || [ -L "$APP" ]; then
    fail "something else is at $APP now; left it as it is"
  fi
  mv "$stage/Blackice.app" "$APP" || fail "could not move the new Blackice.app to $APP"
  previous=''
  rm -rf "$stage" || say "Could not remove $stage, which holds the previous Blackice.app; move it to the Trash."
  stage=''
  say "Blackice.app $VERSION is in $APPLICATIONS."
}

# Runs on exit. If the installed app was renamed aside and the new one is not in its place, it
# renames the installed app back; if it cannot, it says where that app is and leaves it there.
cleanup() {
  if [ -n "$previous" ] && { [ -e "$previous" ] || [ -L "$previous" ]; }; then
    if [ ! -e "$APP" ] && [ ! -L "$APP" ] && mv "$previous" "$APP"; then
      printf 'blackice install: put the previous Blackice.app back at %s\n' "$APP" >&2
    else
      printf 'blackice install: the previous Blackice.app is at %s\n' "$previous" >&2
      stage=''
    fi
  fi
  [ -z "$stage" ] || rm -rf "$stage" || true
  rm -rf "$work" || true
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
  if [ "$replace" = 1 ]; then
    say "Next: \`blackice start\` finishes the upgrade. If it exits with 75, restart the Mac and run it again."
  else
    say "Next: \`blackice start\`. It asks a few questions, then System Settings asks you to allow the extension."
  fi
  say "Guide: $GUIDE"
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

  case $APPLICATIONS in
    /*) ;;
    *) fail "BLACKICE_APPLICATIONS should be an absolute path, not $APPLICATIONS" ;;
  esac
  check_system

  replace=0 installed_build=''
  if [ -e "$APP" ]; then
    installed=$(plist "$APP" CFBundleShortVersionString)
    if [ "$installed" = "$VERSION" ] && [ "$force" = 0 ]; then
      say "Blackice.app $VERSION is already in $APPLICATIONS."
      install_command
      exit 0
    fi
    [ "$force" = 1 ] || fail "$APP ${installed:-(unknown version)} is already there. To replace it with $VERSION, run" \
      "\`curl -fsSL $SCRIPT_URL | sh -s -- --force\`, then \`blackice start\`."
    replace=1
    installed_build=$(plist "$APP" CFBundleVersion)
  fi

  work=$(mktemp -d "${TMPDIR:-/tmp}/blackice-install.XXXXXX")
  stage='' previous=''
  trap cleanup EXIT
  trap 'exit 1' HUP INT TERM

  download_and_check
  check_not_older
  install_app
  install_command
  next_steps
}

# Everything above only defines; nothing runs until the whole script has arrived.
main "$@"
