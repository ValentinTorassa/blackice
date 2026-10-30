#!/bin/sh
# Run manually as: sudo ./scripts/linux-teardown.sh
# Terminates only blackice scopes. Never detaches policy from a populated cgroup.
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
[ "$(id -u)" -eq 0 ] || { echo 'Run this script with sudo after reviewing it.' >&2; exit 1; }
root=/sys/fs/cgroup/blackice
[ ! -L "$root" ] || { echo 'Refusing cgroup symlink.' >&2; exit 1; }
if [ -d "$root" ]; then
    for scope in "$root"/s-*; do
        [ -d "$scope" ] || continue
        [ ! -L "$scope" ] || exit 1
        printf '1\n' > "$scope/cgroup.kill"
        attempts=0
        while ! rmdir "$scope" 2>/dev/null; do
            [ -d "$scope" ] || break # the running helper may have removed its empty scope
            attempts=$((attempts + 1))
            [ "$attempts" -lt 50 ] || { echo "Still populated; policy retained: $scope" >&2; exit 1; }
            sleep 0.1
        done
    done
    rmdir "$root"
fi
rm -f /usr/local/libexec/blackice-linux-helper /etc/blackice-linux/namespaces
rmdir /etc/blackice-linux 2>/dev/null || true
printf '%s\n' 'Removed blackice helper and owned cgroups; host firewall rules were not changed.'
