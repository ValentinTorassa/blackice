#!/bin/bash
# Run manually as: sudo ./scripts/linux-setup.sh USER EXPECTED_SHA256
# Installs only the prebuilt helper and a root-owned cgroup parent; no host firewall changes.
set -euo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH LC_ALL=C
PS4='+ blackice setup: '
set -x
[[ $EUID -eq 0 ]] || { echo 'Run this script with sudo after reviewing it.' >&2; exit 1; }
owner=${1:-${SUDO_USER:-}}
[[ -n $owner ]] && [[ $(/usr/bin/id -u -- "$owner") -ne 0 ]] || { echo 'Supply an existing non-root user.' >&2; exit 1; }
group=$(/usr/bin/id -g -- "$owner")
expected=${2:-}
[[ $expected =~ ^[0-9a-f]{64}$ ]] || { echo 'Supply the reviewed helper SHA-256 as the second argument.' >&2; exit 1; }
script=$(/usr/bin/readlink -f -- "$0")
source=$(/usr/bin/dirname -- "$script")/../zig-out/bin/blackice-linux-helper
[[ -f $source && ! -L $source ]] || { echo 'Build the helper as your normal user first.' >&2; exit 1; }
[[ $(/usr/bin/stat -f -c %T /sys/fs/cgroup) = cgroup2fs ]] || { echo 'A unified cgroup v2 mount is required.' >&2; exit 1; }
[[ -x /usr/sbin/setcap && -x /usr/sbin/getcap ]] || { echo 'Install libcap tools separately before setup.' >&2; exit 1; }
for dir in /usr/local /usr/local/libexec /etc/blackice-linux /sys/fs/cgroup/blackice; do
    [[ ! -L $dir ]] || { echo "Refusing symlink: $dir" >&2; exit 1; }
    if [[ -e $dir ]]; then
        mode=$(/usr/bin/stat -c %a "$dir")
        [[ $(/usr/bin/stat -c %u "$dir") -eq 0 && $((8#$mode & 022)) -eq 0 ]] || { echo "Unsafe installation directory: $dir" >&2; exit 1; }
    fi
done
/usr/bin/install -d -o root -g root -m 0755 /usr/local/libexec /etc/blackice-linux
if [[ ! -d /sys/fs/cgroup/blackice ]]; then /usr/bin/mkdir /sys/fs/cgroup/blackice; fi
/usr/bin/chown root:root /sys/fs/cgroup/blackice
/usr/bin/chmod 0700 /sys/fs/cgroup/blackice
[[ -z $(/usr/bin/find /sys/fs/cgroup/blackice -mindepth 1 -maxdepth 1 -type d -print -quit) ]] || { echo 'Existing scopes remain; finish or recover them first.' >&2; exit 1; }
umask 077
staged=''
nsfile=''
trap '[[ -z $staged ]] || /usr/bin/rm -f -- "$staged"; [[ -z $nsfile ]] || /usr/bin/rm -f -- "$nsfile"' EXIT
trap 'exit 130' HUP INT TERM
staged=$(/usr/bin/mktemp /usr/local/libexec/blackice-linux-helper.XXXXXX)
nsfile=$(/usr/bin/mktemp /etc/blackice-linux/namespaces.XXXXXX)
/usr/bin/install -o root -g root -m 0700 "$source" "$staged"
actual=$(/usr/bin/sha256sum "$staged")
actual=${actual%% *}
[[ $actual = "$expected" ]] || { echo 'Copied helper hash differs from the reviewed hash; no capabilities installed.' >&2; exit 1; }
for ns in user mnt net cgroup pid; do /usr/bin/readlink "/proc/self/ns/$ns"; done > "$nsfile"
/usr/bin/chown root:root "$nsfile"
/usr/bin/chmod 0644 "$nsfile"
/usr/bin/mv -f "$nsfile" /etc/blackice-linux/namespaces
/usr/bin/chgrp "$group" "$staged"
/usr/bin/chmod 0750 "$staged"
caps=cap_chown,cap_dac_override,cap_net_admin,cap_bpf=ep
/usr/sbin/setcap "$caps" "$staged"
verify_helper() {
    [[ $(/usr/bin/stat -c '%u:%g:%a' "$1") = "0:$group:750" ]] &&
    [[ $(/usr/sbin/getcap "$1") = "$1 $caps" ]] &&
    /usr/sbin/setcap -v "$caps" "$1"
}
verify_helper "$staged" || { echo 'Staged helper permissions or capabilities differ from the required values.' >&2; exit 1; }
[[ $(/usr/bin/stat -c '%u:%g:%a' /etc/blackice-linux) = 0:0:755 ]]
[[ $(/usr/bin/stat -c '%u:%g:%a' /etc/blackice-linux/namespaces) = 0:0:644 ]]
[[ $(/usr/bin/stat -c '%u:%g:%a' /sys/fs/cgroup/blackice) = 0:0:700 ]]
/usr/bin/mv -f "$staged" /usr/local/libexec/blackice-linux-helper
if ! verify_helper /usr/local/libexec/blackice-linux-helper; then
    /usr/bin/chmod 000 /usr/local/libexec/blackice-linux-helper
    /usr/bin/rm -f /usr/local/libexec/blackice-linux-helper
    echo 'Installed helper verification failed; helper removed.' >&2
    exit 1
fi
printf '%s\n' 'Installed. Run blackice as your normal user. Repeat setup after reboot.'
