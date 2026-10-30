#!/bin/bash
# blackice Linux app filter: kernel tests in a disposable VM (host driver).
#
# Builds the candidate INSIDE the VM from a git archive of one exact commit, records provenance, installs the
# test kit under /opt/aftest, runs the phases of vm/aftest.py one by one, drives the interactive `app off`
# cases (interactive_off.py) from here over `ssh -t`, and fetches the results. Nothing runs on this host except
# git, ssh and the pty driver. See EXPECTED.md for every case.
#
#   run.sh --vm /var/tmp/blackice-vm2 --commit <sha> --binary-sha <sha256> --bundle-sha <sha256> \
#          --label dry-run|evidence --results <dir> [--agent yes|no] [--extra] [--skip phase,...] [--secret-dir <dir>]
#
# --agent yes: the commit's CLI starts pkttyagent for `app off` on a tty (B1 must turn the filter off).
# --agent no:  it does not (6c849ec): every B case expects a refusal with no prompt.
set -euo pipefail
PINNED_KERNEL=6.12.113+deb13-amd64
here=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")" && pwd)
repo=$(git -C "$here" rev-parse --show-toplevel)

vm= commit= binary_sha= bundle_sha= label= results= agent=yes extra=0 skip= secret_dir=
while [[ $# -gt 0 ]]; do
    case $1 in
        --vm) vm=$2; shift 2 ;;
        --commit) commit=$2; shift 2 ;;
        --binary-sha) binary_sha=$2; shift 2 ;;
        --bundle-sha) bundle_sha=$2; shift 2 ;;
        --label) label=$2; shift 2 ;;
        --results) results=$2; shift 2 ;;
        --agent) agent=$2; shift 2 ;;
        --extra) extra=1; shift ;;
        --skip) skip=,$2,; shift 2 ;;
        --secret-dir) secret_dir=$2; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
[[ -n $vm && -n $commit && -n $label && -n $results ]] || { sed -n '9,14p' "$0" >&2; exit 2; }
[[ $binary_sha =~ ^[0-9a-f]{64}$ && $bundle_sha =~ ^[0-9a-f]{64}$ ]] || { echo 'binary and bundle sha256 required' >&2; exit 2; }
[[ $label == dry-run || $label == evidence ]] || { echo 'label: dry-run or evidence' >&2; exit 2; }
[[ $agent == yes || $agent == no ]] || { echo 'agent: yes or no' >&2; exit 2; }

vm=$(readlink -f -- "$vm")
[[ $vm != /var/tmp/blackice-vm ]] || { echo 'refusing the demo VM (/var/tmp/blackice-vm)' >&2; exit 1; }
vssh=$vm/vssh
[[ -x $vssh ]] || { echo "no ssh wrapper at $vssh" >&2; exit 1; }
v() { "$vssh" "$@"; }

# The kernel first, before anything else touches the VM.
kernel=$(v uname -r)
[[ $kernel == "$PINNED_KERNEL" ]] || { echo "VM kernel is $kernel, not $PINNED_KERNEL: stopping" >&2; exit 1; }
vmhost=$(v hostname)
[[ $vmhost != demo-vm ]] || { echo 'refusing demo-vm' >&2; exit 1; }
owner=$(v id -un)
other=other

commit=$(git -C "$repo" rev-parse --verify "$commit^{commit}")
tree=$(git -C "$repo" rev-parse "$commit^{tree}")
short=${commit:0:7}
stamp=$(date -u +%Y%m%dT%H%M%SZ)
out=$results/$label-$short-$stamp
mkdir -p "$out/host"
exec > >(tee -a "$out/driver.log") 2>&1
if [[ -z $secret_dir ]]; then secret_dir=$(mktemp -d); fi
umask 077
pwfile=$secret_dir/vm-owner-password-$stamp
python3 -I -c 'import secrets; print(secrets.token_urlsafe(18))' > "$pwfile"
umask 022

say() { echo; echo "== $(date -u +%FT%TZ) $*"; }
say "run $label of $commit in $vm ($vmhost, $kernel), owner $owner, other $other, agent $agent"
[[ $label == dry-run ]] && echo 'DRY RUN: for debugging the harness; not evidence.'

say 'VM packages (disposable VM only)'
v "sudo DEBIAN_FRONTEND=noninteractive apt-get -q update >/dev/null && sudo DEBIAN_FRONTEND=noninteractive apt-get -q install -y --no-install-recommends \
    git cron at systemd-resolved btrfs-progs curl wget bpftool nftables polkitd libcap2-bin iproute2 dbus-user-session >/dev/null && echo packages ok"

say 'Zig 0.17.0 in the VM'
zig=$(v 'z=$(command -v zig || true); [ -n "$z" ] && [ "$("$z" version)" = 0.17.0 ] && readlink -f "$z" || true')
if [[ -z $zig ]]; then
    zig=$(v 'echo $HOME')/zig-0.17.0/zig
    if [[ $(v "test -x $zig && $zig version || true") != 0.17.0 ]]; then
        tar -C "$HOME/.local" -cf - zig-0.17.0 | v 'tar -C "$HOME" -xf -'
    fi
fi
[[ $(v "$zig version") == 0.17.0 ]] || { echo 'no Zig 0.17.0 in the VM' >&2; exit 1; }
echo "zig: $zig"

say "source: git archive $commit"
src=$(v 'echo $HOME')/aftest-src-$short-$stamp
git -C "$repo" archive --format=tar "$commit" | v "mkdir -p $src && tar -C $src -xf -"

say 'provenance (before the build)'
{
    echo "run:         $label$([[ $label == dry-run ]] && echo ' (DRY RUN, not evidence)')"
    echo "date:        $(date -u +%FT%TZ)"
    echo "commit:      $commit"
    echo "vm host:     $vmhost"
    echo "kernel:      $(v uname -r)"
    echo "btf sha256:  $(v sha256sum /sys/kernel/btf/vmlinux | cut -d' ' -f1)"
    echo "debian:      $(v cat /etc/debian_version)"
    echo "zig:         $(v "$zig version")"
    vtree=$(v "t=\$(mktemp -d) && git init -q \$t && git --git-dir=\$t/.git --work-tree=$src add -A && git --git-dir=\$t/.git --work-tree=$src write-tree && rm -rf \$t")
    echo "source tree: $vtree (computed in the VM)"
    echo "  expected:  $tree (tree of commit $commit)"
} | tee "$out/provenance.txt"
grep -q "source tree: $tree " "$out/provenance.txt" || { echo 'source tree mismatch: stopping' >&2; exit 1; }

say 'build in the VM, as the user'
v "cd $src && ZIG=$zig bash scripts/linux-build-appfilter.sh && $zig build -Doptimize=ReleaseSafe" | tee "$out/build.log"
v "mkdir -p $src/aftest-uring && cat > $src/aftest-uring/uringprobe.zig" < "$here/vm/uringprobe.zig"
v "cd $src/aftest-uring && $zig build-exe uringprobe.zig -target x86_64-linux -mcpu=baseline -O ReleaseSafe -fstrip -femit-bin=uringprobe"
bundle=$(v sha256sum "$src/zig-out/blackice-linux-appfilter-install.tar" | cut -d' ' -f1)
binary=$(v "tar -xOf $src/zig-out/blackice-linux-appfilter-install.tar blackice-linux-appfilter | sha256sum" | cut -d' ' -f1)
cli=$(v sha256sum "$src/zig-out/bin/blackice" | cut -d' ' -f1)
uring=$(v sha256sum "$src/aftest-uring/uringprobe" | cut -d' ' -f1)
{
    echo "bundle:      $bundle"
    echo "  expected:  $bundle_sha"
    echo "service bin: $binary"
    echo "  expected:  $binary_sha"
    echo "cli:         $cli zig-out/bin/blackice"
    echo "uringprobe:  $uring (test tool, not product)"
    echo "aftest.py:   $(sha256sum "$here/vm/aftest.py" | cut -d' ' -f1)"
    echo "harness:     $(git -C "$repo" rev-parse HEAD) $(git -C "$repo" status --porcelain -- "$here" | wc -l) uncommitted harness files"
} | tee -a "$out/provenance.txt"
[[ $bundle == "$bundle_sha" && $binary == "$binary_sha" ]] || { echo 'bundle or binary hash differs from the reviewed hashes: stopping' >&2; exit 1; }

say 'leftovers of an earlier run in this VM'
v "sudo systemctl stop aftest-sniffer aftest-ns-server 2>/dev/null; true"
if v 'sudo test -e /etc/blackice-appfilter/owner.json'; then
    echo 'an app filter is installed in this VM: run its root teardown first' >&2; exit 1
fi
v "if sudo test -d /var/tmp/aftest/results; then sudo mv /var/tmp/aftest/results /var/tmp/aftest/results-before-$stamp && echo 'moved earlier results aside'; fi; sudo rm -f /var/tmp/aftest/last-policy"
v "if sudo test -d /var/lib/blackice-appfilter; then sudo install -d -o root -g root -m 0700 /var/tmp/aftest-archive && sudo mv /var/lib/blackice-appfilter /var/tmp/aftest-archive/var-lib-blackice-appfilter-$stamp && echo 'archived the preserved receipts of an earlier run (setup refuses to adopt them)'; fi" | tee -a "$out/provenance.txt"

say 'install the test kit under /opt/aftest'
v "sudo install -d -o root -g root -m 0755 /opt/aftest /opt/aftest/bin /opt/aftest/policies /opt/aftest/candidate /opt/aftest/candidate/scripts /opt/aftest/candidate/zig-out \
 && sudo install -o root -g root -m 0755 $src/zig-out/bin/blackice /opt/aftest/bin/blackice \
 && sudo install -o root -g root -m 0755 $src/aftest-uring/uringprobe /opt/aftest/bin/uringprobe \
 && sudo install -o root -g root -m 0755 $src/scripts/linux-appfilter-setup.sh $src/scripts/linux-appfilter-teardown.sh /opt/aftest/candidate/scripts/ \
 && sudo install -o root -g root -m 0644 $src/zig-out/blackice-linux-appfilter-install.tar /opt/aftest/candidate/zig-out/"
v 'sudo tee /opt/aftest/aftest.py >/dev/null && sudo chmod 0644 /opt/aftest/aftest.py' < "$here/vm/aftest.py"
printf 'BUNDLE_SHA256=%s\nBINARY_SHA256=%s\n' "$bundle_sha" "$binary_sha" | v 'sudo tee /opt/aftest/candidate/hashes.env >/dev/null'
printf '{"owner": "%s", "other": "%s", "label": "%s", "commit": "%s"}\n' "$owner" "$other" "$label" "$commit" \
    | v 'sudo tee /opt/aftest/aftest.json >/dev/null && sudo chmod 0644 /opt/aftest/aftest.json /opt/aftest/candidate/hashes.env'

A=/opt/aftest/aftest.py
CLI=/opt/aftest/bin/blackice
failed=()
phase() {
    local name=$1; shift
    if [[ $skip == *",$name,"* ]]; then echo "-- skipped $name"; return 0; fi
    say "phase $name $*"
    if v "sudo python3 -I $A phase $name $*"; then return 0; fi
    failed+=("$name")
    return 1
}
critical() { phase "$@" || { echo "critical phase $1 failed: stopping before later phases"; fetch; exit 1; }; }
fetch() {
    say "fetch results into $out"
    v 'sudo tar -C /var/tmp/aftest -cf - results' | tar -C "$out" -xf -
    echo "failed phases: ${failed[*]:-none}" | tee "$out/phases.txt"
}

critical preflight
critical provision
critical baseline
critical setup
[[ $extra == 1 ]] && phase extra-m4 || true
critical arm
phase guard || true
phase inbound || true
phase bind || true
phase srh || true
phase dns-redirect || true
phase service || true
if [[ $extra == 1 ]]; then phase extra-uring || true; phase extra-flood || true; fi
phase restart || true
phase kill-fork || true
phase off || true
phase kill-phases || true
phase host-like || true

# Security case B: the real polkit path, over ssh -t, in a fresh session each time.
if [[ $skip != *",interactive,"* ]]; then
    say 'interactive off: owner password (random, never logged)'
    printf '%s:%s\n' "$owner" "$(cat "$pwfile")" | v 'sudo chpasswd'
    phase interactive-setup --agent "$agent" || true
    for spec in B1-off-correct-password:correct:off B2-off-wrong-password:wrong:armed B3-off-ctrl-c:ctrl-c:armed B4-off-no-answer:no-answer:armed; do
        IFS=: read -r cid attempt expect <<<"$spec"
        [[ $agent == yes ]] || expect=armed
        phase interactive-pre --case "$cid" || true
        say "host: ssh -t ... app off ($attempt)"
        python3 -I "$here/interactive_off.py" --vssh "$vssh" --cli "$CLI" --owner "$owner" --attempt "$attempt" \
            --password-file "$pwfile" --out "$out/host/$cid.json" || true
        b64=$(python3 -I -c 'import base64,sys; print(base64.b64encode(open(sys.argv[1],"rb").read()).decode())' "$out/host/$cid.json")
        phase interactive-post --case "$cid" --expect "$expect" --agent "$agent" --host-result "$b64" || true
    done
    v "sudo passwd -l $owner >/dev/null && echo 'owner password locked again'"
fi

if [[ $skip != *",reboot-check,"* ]]; then
    say 'reboot the VM (M6)'
    v 'sudo systemctl reboot' || true
    sleep 20
    for _ in $(seq 60); do v true 2>/dev/null && break; sleep 5; done
    [[ $(v uname -r) == "$PINNED_KERNEL" ]] || { echo 'kernel changed across the reboot: stopping' >&2; fetch; exit 1; }
    phase reboot-check || true
fi
phase teardown || true
phase summary || true
fetch
say "done: $out"
