#!/bin/bash
# Run manually as: sudo ./scripts/linux-teardown.sh
# Terminates only blackice scopes. Never detaches policy from a populated cgroup.
set -euo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH LC_ALL=C
PS4='+ blackice teardown: '
set -x
[[ $EUID -eq 0 ]] || { echo 'Run this script with sudo after reviewing it.' >&2; exit 1; }
shopt -s nullglob
root=/sys/fs/cgroup/blackice
for path in "$root" /etc/blackice-linux /usr/local/libexec/blackice-linux-helper; do
    [[ ! -L $path ]] || { echo "Refusing symlink: $path" >&2; exit 1; }
    [[ ! -e $path || $(/usr/bin/stat -c %u "$path") -eq 0 ]] || { echo "Refusing non-root-owned path: $path" >&2; exit 1; }
done
# Refuse new launches while active helpers finish cleanup. Live attachments stay in place.
if [[ -f /usr/local/libexec/blackice-linux-helper ]]; then /usr/bin/chmod 000 /usr/local/libexec/blackice-linux-helper; fi
# EXIT traps cannot run after SIGKILL. Remove only setup's reserved, root-owned staging files.
for staged in /usr/local/libexec/blackice-linux-helper.?????? /etc/blackice-linux/namespaces.??????; do
    [[ ${staged##*.} =~ ^[a-zA-Z0-9]{6}$ && -f $staged && ! -L $staged && $(/usr/bin/stat -c %u "$staged") -eq 0 ]] || { echo "Refusing unexpected staging file: $staged" >&2; exit 1; }
    /usr/bin/chmod 000 "$staged"
    /usr/bin/rm -f -- "$staged"
done
if [[ -d $root ]]; then
    for scope in "$root"/s-*; do
        [[ ${scope##*/} =~ ^s-[0-9a-f]{8}$ && -d $scope && ! -L $scope ]] || { echo "Unrecognized scope: $scope" >&2; exit 1; }
        printf '1\n' > "$scope/cgroup.kill"
        attempts=0
        while ! /usr/bin/rmdir "$scope" 2>/dev/null; do
            [[ -d $scope ]] || break # the running helper may have removed its empty scope
            attempts=$((attempts + 1))
            [[ $attempts -lt 50 ]] || { echo "Still populated; policy retained: $scope. New launches disabled; retry owner recovery." >&2; exit 1; }
            /usr/bin/sleep 0.1
        done
    done
    /usr/bin/rmdir "$root"
fi
/usr/bin/rm -f /usr/local/libexec/blackice-linux-helper /etc/blackice-linux/namespaces
if [[ -d /etc/blackice-linux ]]; then /usr/bin/rmdir /etc/blackice-linux; fi
printf '%s\n' 'Removed blackice helper and owned cgroups; host firewall rules were not changed.'
