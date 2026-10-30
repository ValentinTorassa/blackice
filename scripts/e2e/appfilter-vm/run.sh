#!/bin/bash
# blackice Linux app filter: kernel tests in a disposable VM (host driver).
#
# Builds the candidate INSIDE the VM from a git archive of one exact commit, records provenance, installs a
# test kit under /opt/aftest, runs the phases of vm/aftest.py one by one, drives the interactive `app off`
# cases (interactive_off.py) from here over ssh, and fetches the results. Nothing runs on this host except git,
# ssh and the pty driver. See EXPECTED.md for every case.
#
#   run.sh --vm DIR --commit SHA --binary-sha SHA256 --bundle-sha SHA256 [--cli-sha SHA256] \
#          --label dry-run|evidence --results DIR [--agent yes|no] [--extra] [--skip phase,...] \
#          [--secret-dir DIR] [--only interactive|reboot|teardown,...] [--targeted] [--bcases "B1 B9a ..."]
#
# --agent yes: the commit's CLI starts pkttyagent for `app off` on a tty. --agent no: it does not (before c592f6e).
# --only:      re-run blocks against the kit already installed in the VM (after a harness fix); no build.
# --targeted:  a fresh build and install of a new SHA, then only P0-P4, the restart phase (F01, F02, F02b,
#              F02c), the interactive B1 and B9a-c, and the root teardown.
set -euo pipefail
PINNED_KERNEL=6.12.113+deb13-amd64
here=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")" && pwd)
repo=$(git -C "$here" rev-parse --show-toplevel)

vm= commit= binary_sha= bundle_sha= cli_sha= label= results= agent=yes extra=0 skip= secret_dir= only= targeted=0 bcases=
while [[ $# -gt 0 ]]; do
    case $1 in
        --vm) vm=$2; shift 2 ;;
        --commit) commit=$2; shift 2 ;;
        --binary-sha) binary_sha=$2; shift 2 ;;
        --bundle-sha) bundle_sha=$2; shift 2 ;;
        --cli-sha) cli_sha=$2; shift 2 ;;
        --label) label=$2; shift 2 ;;
        --results) results=$2; shift 2 ;;
        --agent) agent=$2; shift 2 ;;
        --extra) extra=1; shift ;;
        --skip) skip=,$2,; shift 2 ;;
        --secret-dir) secret_dir=$2; shift 2 ;;
        --only) only=,$2,; shift 2 ;;
        --targeted) targeted=1; shift ;;
        --bcases) bcases=$2; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
[[ -n $vm && -n $commit && -n $label && -n $results ]] || { sed -n '9,15p' "$0" >&2; exit 2; }
[[ $binary_sha =~ ^[0-9a-f]{64}$ && $bundle_sha =~ ^[0-9a-f]{64}$ ]] || { echo 'binary and bundle sha256 required' >&2; exit 2; }
[[ -z $cli_sha || $cli_sha =~ ^[0-9a-f]{64}$ ]] || { echo 'bad --cli-sha' >&2; exit 2; }
[[ $label == dry-run || $label == evidence ]] || { echo 'label: dry-run or evidence' >&2; exit 2; }
[[ $agent == yes || $agent == no ]] || { echo 'agent: yes or no' >&2; exit 2; }

# Nothing may run on this host: only a test VM's wrapper (never the demo VM's /var/tmp/blackice-vm), whose only
# command execs ssh, and a VM that answers hostname with test-vm.
vm=$(readlink -f -- "$vm")
[[ $vm =~ ^/var/tmp/blackice-vm[0-9]+$ ]] || { echo "refusing $vm: not a test VM directory (/var/tmp/blackice-vmN)" >&2; exit 1; }
vssh=$vm/vssh
[[ -x $vssh && ! -L $vssh ]] || { echo "no ssh wrapper at $vssh" >&2; exit 1; }
[[ $(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$vssh" | wc -l) == 1 && $(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$vssh") == 'exec ssh '*'"$@"' ]] \
    || { echo "refusing $vssh: it must be one exec ssh ... \"\$@\" line" >&2; exit 1; }
v() { "$vssh" "$@"; }
[[ $(v hostname </dev/null) == test-vm ]] || { echo 'refusing: the VM does not answer hostname with test-vm' >&2; exit 1; }

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
out=$results/$label-$short-$stamp${only:+-rerun}$([[ $targeted == 1 ]] && echo -targeted)
mkdir -p "$out/host"
exec > >(tee -a "$out/driver.log") 2>&1
if [[ -z $secret_dir ]]; then secret_dir=$(mktemp -d); fi
umask 077
pwfile=$secret_dir/vm-owner-password-$stamp
python3 -I -c 'import secrets; print(secrets.token_urlsafe(18))' > "$pwfile"
rootpwfile=$secret_dir/vm-root-password-$stamp
python3 -I -c 'import secrets; print(secrets.token_urlsafe(18))' > "$rootpwfile"
umask 022

say() { echo; echo "== $(date -u +%FT%TZ) $*"; }
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
fetch() {
    say "fetch results into $out"
    v 'sudo tar -C /var/tmp/aftest -cf - results' | tar -C "$out" -xf -
    echo "failed phases: ${failed[*]:-none}" | tee "$out/phases.txt"
}
critical() { phase "$@" || { echo "critical phase $1 failed: stopping before later phases"; fetch; exit 1; }; }
restore_agent() {
    # B7 moves /usr/bin/pkttyagent aside; never leave the VM without it.
    v 'if sudo test -e /var/tmp/aftest/pkttyagent.aside && ! sudo test -e /usr/bin/pkttyagent; then sudo mv /var/tmp/aftest/pkttyagent.aside /usr/bin/pkttyagent && echo "restored /usr/bin/pkttyagent"; fi' || true
}
trap restore_agent EXIT

say "run $label of $commit in $vm ($vmhost, $kernel), owner $owner, other $other, agent $agent${only:+, only $only}"
[[ $label == dry-run ]] && echo 'DRY RUN: for debugging the harness; not evidence.'

build_and_install() {
    say 'VM packages (disposable VM only)'
    v "sudo DEBIAN_FRONTEND=noninteractive apt-get -q update >/dev/null && sudo DEBIAN_FRONTEND=noninteractive apt-get -q install -y --no-install-recommends \
        git cron at systemd-resolved btrfs-progs curl wget bpftool nftables polkitd pkexec libcap2-bin iproute2 dbus-user-session strace >/dev/null && echo packages ok"

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

    say 'build in the VM, as the user (service bundle, then the release CLI)'
    v "cd $src && ZIG=$zig bash scripts/linux-build-appfilter.sh && $zig build release" | tee "$out/build.log"
    v "mkdir -p $src/aftest-uring && cat > $src/aftest-uring/uringprobe.zig" < "$here/vm/uringprobe.zig"
    v "cd $src/aftest-uring && $zig build-exe uringprobe.zig -target x86_64-linux -mcpu=baseline -O ReleaseSafe -fstrip -femit-bin=uringprobe"
    bundle=$(v sha256sum "$src/zig-out/blackice-linux-appfilter-install.tar" | cut -d' ' -f1)
    binary=$(v "tar -xOf $src/zig-out/blackice-linux-appfilter-install.tar blackice-linux-appfilter | sha256sum" | cut -d' ' -f1)
    cli=$(v sha256sum "$src/zig-out/release/blackice-x86_64-linux" | cut -d' ' -f1)
    uring=$(v sha256sum "$src/aftest-uring/uringprobe" | cut -d' ' -f1)
    {
        echo "bundle:      $bundle"
        echo "  expected:  $bundle_sha"
        echo "service bin: $binary"
        echo "  expected:  $binary_sha"
        echo "cli:         $cli zig-out/release/blackice-x86_64-linux (zig build release)"
        echo "  expected:  ${cli_sha:-(not given)}"
        echo "uringprobe:  $uring (test tool, not product)"
        echo "aftest.py:   $(sha256sum "$here/vm/aftest.py" | cut -d' ' -f1)"
        echo "harness:     $(git -C "$repo" rev-parse HEAD), $(git -C "$repo" status --porcelain -- "$here" | wc -l) uncommitted harness files"
    } | tee -a "$out/provenance.txt"
    [[ $bundle == "$bundle_sha" && $binary == "$binary_sha" ]] || { echo 'bundle or binary hash differs from the reviewed hashes: stopping' >&2; exit 1; }
    [[ -z $cli_sha || $cli == "$cli_sha" ]] || { echo 'CLI hash differs from the reviewed hash: stopping' >&2; exit 1; }

    say 'leftovers of an earlier run in this VM'
    v "sudo systemctl stop aftest-sniffer aftest-ns-server 2>/dev/null; true"
    if v 'sudo test -e /etc/blackice-appfilter/owner.json'; then
        echo 'an app filter is installed in this VM: run its root teardown first' >&2; exit 1
    fi
    v "if sudo test -d /var/tmp/aftest/results; then sudo mv /var/tmp/aftest/results /var/tmp/aftest/results-before-$stamp && echo 'moved earlier results aside'; fi; sudo rm -f /var/tmp/aftest/last-policy"
    v "if sudo test -d /var/lib/blackice-appfilter; then sudo install -d -o root -g root -m 0700 /var/tmp/aftest-archive && sudo mv /var/lib/blackice-appfilter /var/tmp/aftest-archive/var-lib-blackice-appfilter-$stamp && echo 'archived the preserved receipts of an earlier run (setup refuses to adopt them)'; fi" | tee -a "$out/provenance.txt"

    say 'install the test kit under /opt/aftest'
    v "sudo install -d -o root -g root -m 0755 /opt/aftest /opt/aftest/bin /opt/aftest/policies /opt/aftest/b9 /opt/aftest/candidate /opt/aftest/candidate/scripts /opt/aftest/candidate/zig-out \
     && sudo install -o root -g root -m 0755 $src/zig-out/release/blackice-x86_64-linux /opt/aftest/bin/blackice \
     && sudo install -o root -g root -m 0755 $src/aftest-uring/uringprobe /opt/aftest/bin/uringprobe \
     && sudo install -o root -g root -m 0755 $src/scripts/linux-appfilter-setup.sh $src/scripts/linux-appfilter-teardown.sh /opt/aftest/candidate/scripts/ \
     && sudo install -o root -g root -m 0644 $src/zig-out/blackice-linux-appfilter-install.tar /opt/aftest/candidate/zig-out/"
    v 'sudo tee /opt/aftest/aftest.py >/dev/null && sudo chmod 0644 /opt/aftest/aftest.py' < "$here/vm/aftest.py"
    v 'sudo tee /opt/aftest/b9/49-blackice-appfilter-admin.rules.test >/dev/null && sudo chmod 0644 /opt/aftest/b9/49-blackice-appfilter-admin.rules.test' \
        < "$here/vm/49-blackice-appfilter-admin.rules.test"
    printf 'BUNDLE_SHA256=%s\nBINARY_SHA256=%s\n' "$bundle_sha" "$binary_sha" | v 'sudo tee /opt/aftest/candidate/hashes.env >/dev/null'
    printf '{"owner": "%s", "other": "%s", "label": "%s", "commit": "%s"}\n' "$owner" "$other" "$label" "$commit" \
        | v 'sudo tee /opt/aftest/aftest.json >/dev/null && sudo chmod 0644 /opt/aftest/aftest.json /opt/aftest/candidate/hashes.env'
}

refresh_kit() {
    # --only: the harness may have been fixed; the product files stay as installed and verified.
    say 'refresh aftest.py in the VM (harness only; product files untouched)'
    v 'sudo tee /opt/aftest/aftest.py >/dev/null && sudo chmod 0644 /opt/aftest/aftest.py' < "$here/vm/aftest.py"
    echo "aftest.py: $(sha256sum "$here/vm/aftest.py" | cut -d' ' -f1)" | tee "$out/provenance.txt"
    v 'sudo cat /opt/aftest/aftest.json' | tee -a "$out/provenance.txt"
}

interactive_block() {
    # Security's case B: the real polkit path, each case in a fresh ssh session (a login shell under ssh -t).
    say 'interactive off: owner password (random, never logged)'
    printf '%s:%s\n' "$owner" "$(cat "$pwfile")" | v 'sudo chpasswd'
    phase interactive-setup --agent "$agent" || true
    local spec cid attempt prefix want=${1:-}
    for spec in B1-off-correct-password:correct B2-off-wrong-password:wrong B3-off-ctrl-c:ctrl-c B4-off-no-answer:no-answer \
                B5-off-no-tty:no-tty B7-off-agent-missing:agent-missing B8-off-owner-not-admin:correct \
                B8a-off-root-password:correct B8b-off-root-wrong:wrong \
                B9a-admin-rule-correct:correct B9b-admin-rule-wrong:wrong B9c-admin-rule-pkexec:pkexec; do
        IFS=: read -r cid attempt <<<"$spec"
        if [[ -n $want && " $want " != *" ${cid%%-*} "* && " $want " != *" ${cid:0:2} "* ]]; then continue; fi
        prefix=
        [[ $cid == B7-* ]] && prefix="strace -f -qq -e trace=connect,execve -o /var/tmp/aftest/drop/$owner/b7-strace.txt "
        answer=$pwfile
        if [[ $cid == B8a-* ]]; then
            # Root is locked in the cloud image: B8 records the refusal, then root gets a random password for B8a/B8b.
            say 'B8a: root password (random, never logged)'
            v 'sudo passwd -S root' | awk '{print "root password state before: " $2}'
            printf 'root:%s\n' "$(cat "$rootpwfile")" | v 'sudo chpasswd'
            v 'sudo passwd -S root' | awk '{print "root password state after chpasswd: " $2}'
        fi
        [[ $cid == B8a-* || $cid == B8b-* ]] && answer=$rootpwfile
        phase interactive-pre --case "$cid" || true
        say "host: $cid ($attempt)"
        python3 -I "$here/interactive_off.py" --vssh "$vssh" --cli "$CLI" --owner "$owner" --attempt "$attempt" \
            --prefix "$prefix" --password-file "$answer" --out "$out/host/$cid.json" || true
        [[ -s $out/host/$cid.json ]] || echo '{"attempt": "driver failed", "transcript": ""}' > "$out/host/$cid.json"
        b64=$(python3 -I -c 'import base64,sys; print(base64.b64encode(open(sys.argv[1],"rb").read()).decode())' "$out/host/$cid.json")
        phase interactive-post --case "$cid" --agent "$agent" --host-result "$b64" || true
        restore_agent
    done
    v "sudo passwd -l $owner >/dev/null && echo 'owner password locked again'"
    v "sudo passwd -l root >/dev/null && echo 'root password locked again'"
}

reboot_block() {
    say 'reboot the VM (M6)'
    v 'sudo systemctl reboot' || true
    sleep 20
    for _ in $(seq 60); do v true 2>/dev/null && break; sleep 5; done
    [[ $(v uname -r) == "$PINNED_KERNEL" ]] || { echo 'kernel changed across the reboot: stopping' >&2; fetch; exit 1; }
    phase reboot-check || true
}

if [[ -n $only ]]; then
    refresh_kit
    [[ $only == *",interactive,"* ]] && interactive_block "$bcases"
    [[ $only == *",reboot,"* ]] && reboot_block
    [[ $only == *",teardown,"* ]] && { phase teardown || true; }
    phase summary || true
    fetch
    say "done: $out"
    exit 0
fi

build_and_install
if [[ $targeted == 1 ]]; then
    critical preflight
    critical provision
    critical baseline
    critical setup
    critical arm
    phase restart || true
    phase host-like || true  # arms the curl-only policy the B cases start from
    interactive_block "${bcases:-B1 B9a B9b B9c}"
    phase teardown || true
    phase summary || true
    fetch
    say "done: $out"
    exit 0
fi
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
[[ $skip == *",interactive,"* ]] || interactive_block "$bcases"
[[ $skip == *",reboot-check,"* ]] || reboot_block
phase teardown || true
phase summary || true
fetch
say "done: $out"
