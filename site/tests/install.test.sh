#!/bin/sh
# Runs lib/install.sh on fake Blackice.app bundles in a temporary folder and checks what it leaves
# there. A copy of the script calls stand-ins for the macOS tools it runs by full path (codesign,
# spctl, ditto, PlistBuddy, sw_vers, sysctl, curl), installs into the temporary folder through
# BLACKICE_APPLICATIONS, and has /nonexistent/Applications as its default, so a run that loses the
# variable fails instead of touching /Applications. curl's stand-in fails, so nothing is downloaded,
# except in the download cases, where it copies from the case's own release folder.
#
#   sh tests/install.test.sh                          # from site/, with /bin/sh
#   TEST_SHELL=/bin/dash sh tests/install.test.sh     # the script under another shell
#
# Needs zip, unzip and shasum. Runs on Linux too.

set -eu

here=$(cd "$(dirname "$0")" && pwd)
script=$here/../lib/install.sh
shell=${TEST_SHELL:-/bin/sh}
root=$(mktemp -d "${TMPDIR:-/tmp}/blackice-install-test.XXXXXX")
trap 'chmod -R u+w "$root" 2>/dev/null; rm -rf "$root"' EXIT
stubs=$root/stubs
mkdir "$stubs"
version=$(sed -n 's/^VERSION=//p' "$script")
extension=Contents/Library/SystemExtensions/com.valentorassa.blackice.filter.systemextension

stub() {
  printf '#!/bin/sh\n%s\n' "$2" > "$stubs/$1"
  chmod 755 "$stubs/$1"
}

stub uname 'case ${1:-} in -m) echo arm64 ;; *) echo Darwin ;; esac'
stub sw_vers 'echo 27.0.1'
stub sysctl 'echo 1'
# curl fails unless SERVE names a folder. Then it copies the file the URL ends with from there to
# the --output file, as a download would, and adds the URL to the file REQUESTS.
stub curl 'eval "url=\${$#}"
[ -n "${SERVE:-}" ] || { echo "curl must not run in this test: $*" >&2; exit 1; }
out=""
while [ $# -gt 0 ]; do
  [ "$1" != --output ] || out=$2
  shift
done
echo "$url" >> "$REQUESTS"
[ -f "$SERVE/${url##*/}" ] || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
exec cp "$SERVE/${url##*/}" "$out"'
# STUB=codesign-fail-copy: the copy beside the installed app does not verify.
# STUB=codesign-requirement: the unpacked app does not meet the code requirement (-R) the script
# gives; STUB=codesign-requirement-copy: the copy beside the installed app does not.
# STUB=codesign-other-team: the app is signed by another team.
# STUB=codesign-requirement-installed: the app already in Applications does not meet the code requirement.
stub codesign 'eval "last=\${$#}"
team=M294LK997M
[ "${STUB:-}" != codesign-other-team ] || team=ABCDE12345
case $1 in
  --verify)
    for arg; do
      case ${STUB:-}:$arg:$last in
        codesign-requirement:-R*:*/unpacked/Blackice.app | codesign-requirement-copy:-R*:*/.blackice-install.* | codesign-requirement-installed:-R*:*/Applications/Blackice.app)
          echo "$last: test-requirement: code failed to satisfy specified code requirement(s)" >&2; exit 3 ;;
      esac
    done
    case ${STUB:-}:$last in
      codesign-fail-copy:*/.blackice-install.*) echo "$last: code object is not signed at all" >&2; exit 1 ;;
    esac
    exit 0 ;;
  -dvv)
    printf "%s\n" "Executable=$last/Contents/MacOS/blackice" Identifier=com.valentorassa.blackice \
      "Authority=Developer ID Application: Test ($team)" "Authority=Developer ID Certification Authority" \
      TeamIdentifier=$team >&2
    exit 0 ;;
esac
exit 64'
# STUB=spctl-rejected: Gatekeeper rejects the app. STUB=spctl-not-notarized: it accepts a Developer
# ID app that is not notarized.
stub spctl 'eval "last=\${$#}"
case ${STUB:-} in
  spctl-rejected) printf "%s\n" "$last: rejected" "source=Unnotarized Developer ID" >&2; exit 3 ;;
  spctl-not-notarized) source="Developer ID" ;;
  *) source="Notarized Developer ID" ;;
esac
printf "%s\n" "$last: accepted" "source=$source" "origin=Developer ID Application: Test (M294LK997M)" >&2'
# ditto -x -k ZIP DIR unpacks; ditto SRC DST copies. STUB=ditto-fail-copy: the copy beside the
# installed app stops halfway.
stub ditto 'if [ "$1" = -x ]; then mkdir -p "$4" && cd "$4" && exec unzip -q "$3"; fi
case ${STUB:-}:$2 in
  ditto-fail-copy:*/.blackice-install.*) mkdir -p "$2/Contents"; echo "ditto: No space left on device" >&2; exit 1 ;;
esac
exec cp -R "$1" "$2"'
# PlistBuddy -c "Print :KEY" FILE, for the plists this test writes when the real one is missing.
stub PlistBuddy '[ ! -x /usr/libexec/PlistBuddy ] || exec /usr/libexec/PlistBuddy "$@"
key=${2#Print :}
[ -f "$3" ] || exit 1
value=$(sed -n "/<key>$key<\/key>/{n;s/^[[:space:]]*<string>\(.*\)<\/string>[[:space:]]*$/\1/p;}" "$3")
[ -n "$value" ] || exit 1
printf "%s\n" "$value"'
# mv is found on PATH. STUB=mv-fail-aside: the installed app cannot be moved aside.
# STUB=mv-fail-in: the new app cannot be moved into place. STUB=mv-interrupt-aside: the script
# gets SIGTERM just after the installed app was moved aside.
stub mv 'case ${STUB:-}:$1:$2 in
  mv-fail-aside:*:*/previous.app) echo "mv: rename $1 to $2: Operation not permitted" >&2; exit 1 ;;
  mv-fail-in:*/.blackice-install.*/Blackice.app:*) echo "mv: rename $1 to $2: Input/output error" >&2; exit 1 ;;
  mv-interrupt-aside:*:*/previous.app) /bin/mv "$1" "$2" || exit 1; kill -TERM "$PPID"; exit 0 ;;
esac
exec /bin/mv "$@"'

copy=$root/install.sh
sed -e "s#/usr/bin/codesign#$stubs/codesign#g" \
  -e "s#/usr/sbin/spctl#$stubs/spctl#g" \
  -e "s#/usr/bin/ditto#$stubs/ditto#g" \
  -e "s#/usr/libexec/PlistBuddy#$stubs/PlistBuddy#g" \
  -e "s#/usr/bin/sw_vers#$stubs/sw_vers#g" \
  -e "s#/usr/sbin/sysctl#$stubs/sysctl#g" \
  -e "s#/usr/bin/curl#$stubs/curl#g" \
  -e "s#Caskroom/blackice#Caskroom/blackice-not-installed#g" \
  -e "s#:-/Applications}#:-/nonexistent/Applications}#" \
  "$script" > "$copy"
for tool in /usr/bin/codesign /usr/sbin/spctl /usr/bin/ditto /usr/libexec/PlistBuddy /usr/bin/curl; do
  if grep -q "$tool" "$copy"; then
    echo "the test copy of install.sh still runs $tool" >&2
    exit 1
  fi
done
grep -q '^APPLICATIONS=${BLACKICE_APPLICATIONS:-/nonexistent/Applications}$' "$copy" || {
  echo "the test copy of install.sh does not take BLACKICE_APPLICATIONS as expected" >&2
  exit 1
}

# write_app DIR VERSION BUILD MARK [EXTENSION_VERSION EXTENSION_BUILD]
write_app() {
  mkdir -p "$1/Contents/MacOS" "$1/$extension/Contents"
  write_plist "$1/Contents/Info.plist" "$2" "$3"
  write_plist "$1/$extension/Contents/Info.plist" "${5:-$2}" "${6:-$3}"
  printf '#!/bin/sh\necho fake blackice\n' > "$1/Contents/MacOS/blackice"
  chmod 755 "$1/Contents/MacOS/blackice"
  echo "$4" > "$1/Contents/mark"
}

write_plist() {
  cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleShortVersionString</key>
	<string>$2</string>
	<key>CFBundleVersion</key>
	<string>$3</string>
</dict>
</plist>
EOF
}

# A fresh folder for one case: $box/Applications, $box/tmp, $box/home and the release zip, named
# for the script's version, holding an app of VERSION and BUILD (default: the script's, 15).
new_box() {
  box=$root/$1
  mkdir -p "$box/Applications" "$box/tmp" "$box/home" "$box/build" "$box/release"
  write_app "$box/build/Blackice.app" "${2:-$version}" "${3:-15}" new "${4:-${2:-$version}}" "${5:-${3:-15}}"
  (cd "$box/build" && zip -qry "$box/release/Blackice-$version.zip" Blackice.app)
  (cd "$box/release" && shasum -a 256 "Blackice-$version.zip" > "Blackice-$version.zip.sha256")
  STUB=''
}

installed() { write_app "$box/Applications/Blackice.app" "$1" "$2" old; }

# Runs the copy for the current box; sets $status and $output.
run() {
  set +e
  output=$(env PATH="$stubs:$PATH" HOME="$box/home" TMPDIR="$box/tmp" STUB="$STUB" \
    BLACKICE_APPLICATIONS="$box/Applications" BLACKICE_BIN_DIR="$box/bin" \
    BLACKICE_ZIP="$box/release/Blackice-$version.zip" "$shell" "$copy" "$@" 2>&1)
  status=$?
  set -e
}

# download PIN [OPTION...]: runs, without BLACKICE_ZIP, a copy that pins SHA-256 PIN and downloads
# the box's release folder through curl's stand-in, which lists the URLs in $box/requests. Sets
# $status and $output.
download() {
  sed "s/^SHA256=.*/SHA256=$1/" "$copy" > "$box/install.sh"
  shift
  set +e
  output=$(env -u BLACKICE_ZIP PATH="$stubs:$PATH" HOME="$box/home" TMPDIR="$box/tmp" STUB="$STUB" \
    SERVE="$box/release" REQUESTS="$box/requests" BLACKICE_APPLICATIONS="$box/Applications" \
    BLACKICE_BIN_DIR="$box/bin" "$shell" "$box/install.sh" "$@" 2>&1)
  status=$?
  set -e
}

# The SHA-256 of the box's release zip, and a new .sha256 file for it.
zip_sha() { shasum -a 256 "$box/release/Blackice-$version.zip" | cut -d' ' -f1; }
rehash() { (cd "$box/release" && shasum -a 256 "Blackice-$version.zip" > "Blackice-$version.zip.sha256"); }
downloaded_zip() { grep -q "/v$version/Blackice-$version.zip\$" "$box/requests" 2>/dev/null; }

failures=0 passed=0
problem() {
  failures=$((failures + 1))
  printf 'not ok - %s: %s\n--- output:\n%s\n---\n' "$name" "$1" "$output"
}
expect_status() { [ "$status" = "$1" ] || problem "exit status $status, expected $1"; }
expect_output() {
  case $output in *"$1"*) ;; *) problem "the output does not say: $1" ;; esac
}
# The app in the box's Applications: its mark, or "none".
expect_app() {
  mark=none
  [ ! -e "$box/Applications/Blackice.app" ] || mark=$(cat "$box/Applications/Blackice.app/Contents/mark" 2>/dev/null || echo unreadable)
  [ "$mark" = "$1" ] || problem "the installed app is $mark, expected $1"
}
expect_no_leftovers() {
  left=$(find "$box/Applications" "$box/tmp" -mindepth 1 -maxdepth 1 ! -name Blackice.app)
  [ -z "$left" ] || problem "left behind: $left"
}
done_case() {
  [ "$failures" != "$before" ] || { passed=$((passed + 1)); echo "ok - $name"; }
}
start() { name=$1; before=$failures; }

start 'a first install puts the app in place and writes the command'
new_box first
run
expect_status 0
expect_app new
expect_no_leftovers
expect_output "version: $version, build 15"
grep -qx "exec $box/Applications/Blackice.app/Contents/MacOS/blackice \"\$@\"" "$box/bin/blackice" 2>/dev/null \
  || problem "the command does not run the installed app"
done_case

start 'the same version installed is kept, with no download'
new_box same
installed "$version" 15
run
expect_status 0
expect_app old
expect_output "already in $box/Applications"
case $output in *Using*) problem 'it read the zip' ;; esac
done_case

start 'the same version installed but not signed by the team is refused, with no command written'
new_box samefake
installed "$version" 15
STUB=codesign-requirement-installed run
expect_status 1
expect_app old
expect_output "not an app signed with the Developer ID of team"
expect_output '--force'
[ ! -e "$box/bin/blackice" ] || problem 'it wrote the command for an app it did not check'
done_case

start 'another version installed needs --force'
new_box noforce
installed 0.0.9 1
run
expect_status 1
expect_app old
expect_output '--force'
expect_no_leftovers
done_case

start '--force replaces an older build and removes it'
new_box force
installed 0.0.9 1
run --force
expect_status 0
expect_app new
expect_output 'Replacing the installed'
expect_no_leftovers
done_case

start 'a zip that holds another version is refused'
new_box otherversion 0.0.8 15
installed 0.0.9 1
run --force
expect_status 1
expect_app old
expect_output "the zip holds Blackice.app 0.0.8, not $version"
expect_no_leftovers
done_case

start 'a zip that holds another version is refused on a first install too'
new_box otherversionfirst 0.0.8 15
run
expect_status 1
expect_app none
expect_no_leftovers
done_case

start 'an extension of another build is refused'
new_box extension "$version" 15 "$version" 14
run
expect_status 1
expect_app none
expect_output 'network extension inside the app'
expect_no_leftovers
done_case

start 'a build number that is not a whole number is refused'
new_box build "$version" 15a
run
expect_status 1
expect_app none
expect_output 'not a positive whole number'
done_case

start 'a newer build installed is not replaced by an older one'
new_box newer
installed 0.0.9 99
run --force
expect_status 1
expect_app old
expect_output 'is build 99, newer than build 15'
expect_no_leftovers
done_case

start 'a copy that fails halfway leaves the installed app'
new_box copyfails
installed 0.0.9 1
STUB=ditto-fail-copy
run --force
expect_status 1
expect_app old
expect_output 'could not copy Blackice.app'
expect_no_leftovers
done_case

start 'a copy that does not verify leaves the installed app'
new_box copyunsigned
installed 0.0.9 1
STUB=codesign-fail-copy
run --force
expect_status 1
expect_app old
expect_output 'does not verify'
expect_no_leftovers
done_case

start 'an installed app that cannot be moved stays, with the App Management hint'
new_box aside
installed 0.0.9 1
STUB=mv-fail-aside
run --force
expect_status 1
expect_app old
expect_output 'App Management'
expect_no_leftovers
done_case

start 'when the new app cannot be moved in, the installed one is put back'
new_box movein
installed 0.0.9 1
STUB=mv-fail-in
run --force
expect_status 1
expect_app old
expect_output 'put the previous Blackice.app back'
expect_no_leftovers
done_case

start 'a SIGTERM after the installed app was moved aside puts it back'
new_box interrupted
installed 0.0.9 1
STUB=mv-interrupt-aside
run --force
expect_status 1
expect_app old
expect_output 'put the previous Blackice.app back'
expect_no_leftovers
done_case

start 'a folder it cannot write to is left as it is'
new_box readonly
chmod 555 "$box/Applications"
run
chmod 755 "$box/Applications"
expect_status 1
expect_app none
expect_output 'could not write to'
expect_no_leftovers
done_case

start 'a relative BLACKICE_APPLICATIONS is refused'
new_box relative
set +e
output=$(cd "$box" && env PATH="$stubs:$PATH" HOME="$box/home" TMPDIR="$box/tmp" BLACKICE_APPLICATIONS=Applications \
  BLACKICE_ZIP="$box/release/Blackice-$version.zip" "$shell" "$copy" 2>&1)
status=$?
set -e
expect_status 1
expect_app none
expect_output 'absolute path'
done_case

start 'a download that matches the pin and the .sha256 on the release is installed'
new_box download
download "$(zip_sha)"
expect_status 0
expect_app new
expect_no_leftovers
expect_output "version: $version, build 15"
downloaded_zip || problem 'it did not download the zip'
done_case

start 'a release whose .sha256 is not the pin is refused before the zip is downloaded'
new_box pinmismatch
download "$(printf '%064d' 0)"
expect_status 1
expect_app none
expect_no_leftovers
expect_output 'but this script pins 0000'
expect_output 'nothing was downloaded'
! downloaded_zip || problem 'it downloaded the zip'
done_case

start 'a zip that is not the pinned one is refused, though the .sha256 is'
new_box zipswapped
pin=$(zip_sha)
printf x >> "$box/release/Blackice-$version.zip"
download "$pin"
expect_status 1
expect_app none
expect_no_leftovers
expect_output "but Blackice-$version.zip.sha256 says $pin"
done_case

start 'a script that pins no SHA-256 downloads nothing'
new_box nopin
download ''
expect_status 1
expect_app none
expect_no_leftovers
expect_output 'pins no SHA-256'
[ ! -e "$box/requests" ] || problem 'it downloaded something'
done_case

start 'BLACKICE_ZIP says when the pin is not used'
new_box localzip
run
expect_status 0
expect_app new
expect_output 'so the pin is not used'
done_case

start 'a zip that holds more than the app is refused'
new_box extra
(cd "$box/build" && echo extra > extra && zip -qry "$box/release/Blackice-$version.zip" extra)
rehash
run
expect_status 1
expect_app none
expect_no_leftovers
expect_output 'should hold only Blackice.app'
done_case

start 'a .sha256 of more than one line is refused'
new_box twolines
echo "$(zip_sha)  Blackice-0.0.1.zip" >> "$box/release/Blackice-$version.zip.sha256"
run
expect_status 1
expect_app none
expect_no_leftovers
expect_output 'should be one line'
done_case

start 'an app that does not meet the Developer ID requirement is refused'
new_box requirement
STUB=codesign-requirement
run
expect_status 1
expect_app none
expect_no_leftovers
expect_output 'not signed with the Developer ID of team M294LK997M'
done_case

start 'a copy that does not meet the Developer ID requirement leaves the installed app'
new_box requirementcopy
installed 0.0.9 1
STUB=codesign-requirement-copy
run --force
expect_status 1
expect_app old
expect_no_leftovers
expect_output 'does not verify'
done_case

start 'an app signed by another team is refused'
new_box team
STUB=codesign-other-team
run
expect_status 1
expect_app none
expect_no_leftovers
expect_output 'signed by team ABCDE12345, not M294LK997M'
done_case

start 'an app Gatekeeper rejects is refused'
new_box rejected
STUB=spctl-rejected
run
expect_status 1
expect_app none
expect_no_leftovers
expect_output 'Gatekeeper rejects the app'
done_case

start 'an app that is not notarized is refused'
new_box notarized
STUB=spctl-not-notarized
run
expect_status 1
expect_app none
expect_no_leftovers
expect_output 'does not see a notarized Developer ID app'
done_case

echo "$passed passed, $failures failed ($shell)"
[ "$failures" = 0 ]
