#!/bin/sh
# Run manually as: sudo ./scripts/linux-setup.sh USER EXPECTED_SHA256
# Installs only the prebuilt helper and a root-owned cgroup parent; no host firewall changes.
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
[ "$(id -u)" -eq 0 ] || { echo 'Run this script with sudo after reviewing it.' >&2; exit 1; }
owner=${1:-${SUDO_USER:-}}
[ -n "$owner" ] && [ "$(id -u "$owner")" -ne 0 ] || { echo 'Supply an existing non-root user.' >&2; exit 1; }
group=$(id -gn "$owner")
expected=${2:-}
[ "${#expected}" -eq 64 ] || { echo 'Supply the reviewed helper SHA-256 as the second argument.' >&2; exit 1; }
case "$expected" in *[!0-9a-f]*) echo 'Invalid SHA-256.' >&2; exit 1;; esac
cd "$(dirname "$0")/.."
[ -f zig-out/bin/blackice-linux-helper ] && [ ! -L zig-out/bin/blackice-linux-helper ] || { echo 'Build the helper as your normal user first.' >&2; exit 1; }
[ "$(stat -f -c %T /sys/fs/cgroup)" = cgroup2fs ] || { echo 'A unified cgroup v2 mount is required.' >&2; exit 1; }
command -v setcap >/dev/null
for dir in /usr/local /usr/local/libexec /etc/blackice-linux /sys/fs/cgroup/blackice; do
    [ ! -L "$dir" ] || { echo "Refusing symlink: $dir" >&2; exit 1; }
    if [ -e "$dir" ]; then
        mode=$(stat -c %a "$dir")
        [ "$(stat -c %u "$dir")" -eq 0 ] && [ "$((0$mode & 022))" -eq 0 ] || { echo "Unsafe installation directory: $dir" >&2; exit 1; }
    fi
done
install -d -o root -g root -m 0755 /usr/local/libexec
install -d -o root -g root -m 0700 /etc/blackice-linux
if [ ! -d /sys/fs/cgroup/blackice ]; then mkdir /sys/fs/cgroup/blackice; fi
chown root:root /sys/fs/cgroup/blackice
chmod 0700 /sys/fs/cgroup/blackice
[ -z "$(find /sys/fs/cgroup/blackice -mindepth 1 -maxdepth 1 -type d -print -quit)" ] || { echo 'Existing scopes remain; finish or recover them first.' >&2; exit 1; }
umask 077
staged=$(mktemp /usr/local/libexec/blackice-linux-helper.XXXXXX)
nsfile=$(mktemp /etc/blackice-linux/namespaces.XXXXXX)
trap 'rm -f "$staged" "$nsfile"' EXIT
trap 'exit 130' HUP INT TERM
install -o root -g root -m 0700 zig-out/bin/blackice-linux-helper "$staged"
actual=$(sha256sum "$staged")
actual=${actual%% *}
[ "$actual" = "$expected" ] || { echo 'Copied helper hash differs from the reviewed hash; no capabilities installed.' >&2; exit 1; }
for ns in user mnt net cgroup pid; do readlink "/proc/self/ns/$ns"; done > "$nsfile"
chown root:root "$nsfile"
chmod 0600 "$nsfile"
mv -f "$nsfile" /etc/blackice-linux/namespaces
chgrp "$group" "$staged"
chmod 0750 "$staged"
setcap cap_chown,cap_dac_override,cap_net_admin,cap_bpf=ep "$staged"
mv -f "$staged" /usr/local/libexec/blackice-linux-helper
getcap /usr/local/libexec/blackice-linux-helper
printf '%s\n' 'Installed. Run blackice as your normal user. Repeat setup after reboot.'
