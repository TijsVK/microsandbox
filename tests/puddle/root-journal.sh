#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# root-journal.sh - the root-disk journal (runtime/root-disk.json) cannot make a restart attach a
# file the sandbox does not own (GHSA-3f94-vm6x-3jv3), and an untouched restart still works
# (Linux host, real microVMs).
#
# usage: root-journal.sh <runtime dir> <work dir>
#   <runtime dir>  holds msb and libkrunfw.so.<version> (as msb looks for it beside itself)
#   <work dir>     private MSB_HOME, logs; created if missing
#
# Two alpine sandboxes: a stopped victim with /victim-marker on its root disk, and the target with
# /own-marker on its own. The hostile journal names the victim's upper.ext4 as the target's only
# layer and keeps the target's own upper.ext4 as launch base, so the base check alone passes it.
# Cases:
#   hidden:       the guest's /.msb holds no root-disk.json and no runtime-boot-id
#                 (stock: both are there, readable and writable by guest root)
#   restart:      stop and start; /own-marker is still there
#   guest-tamper: guest root writes the hostile journal to /.msb/root-disk.json, then stop and start:
#                 the start succeeds, /own-marker is there, /victim-marker is not, the victim's image
#                 is unchanged (stock: the target boots on the victim's disk)
#   host-tamper:  the hostile journal written over runtime/root-disk.json on the host: the start
#                 fails naming a layer outside its sandbox, the victim's image is unchanged
#   recover:      the genuine journal put back: the start succeeds and /own-marker is there
# Prints "CASE <name>: PASS|FAIL ..." per case. Exit 0: all passed. 1: a case failed. 2: setup failed.
set -uo pipefail

rt=$(cd "${1:?runtime dir}" && pwd)
mkdir -p "${2:?work dir}"
work=$(cd "$2" && pwd)
name=${ROOT_JOURNAL_NAME:-rjournal}
victim=$name-victim
image=${ROOT_JOURNAL_IMAGE:-mirror.gcr.io/library/alpine}
msb=$rt/msb
export MSB_HOME=$work/home
export MSB_PATH=$msb

# shellcheck disable=SC2329 # called by the EXIT trap
cleanup() {
  for sandbox in "$name" "$victim"; do
    "$msb" stop "$sandbox" >/dev/null 2>&1
    "$msb" rm -f "$sandbox" >/dev/null 2>&1
  done
}
trap cleanup EXIT

fail=0
case_result() { # name ok detail
  if [ "$2" = 1 ]; then echo "CASE $1: PASS $3"; else echo "CASE $1: FAIL $3"; fail=1; fi
}
g() { # sandbox command
  "$msb" exec --no-tty --no-stdin "$1" -- sh -c "$2" </dev/null
}
start() { # sandbox log
  timeout 300 "$msb" start "$1" >"$2" 2>&1
}
hex() { od -An -tx1 -N16 /dev/urandom | tr -d ' \n'; }

echo "runtime: $("$msb" --version) ($msb)"
"$msb" create --name "$victim" --replace --cpus 1 --memory 512 "$image" >"$work/create-victim.log" 2>&1 \
  || { echo "setup: msb create $victim failed"; cat "$work/create-victim.log"; exit 2; }
g "$victim" "echo victim > /victim-marker && sync" || { echo "setup: victim write failed"; exit 2; }
"$msb" stop "$victim" >/dev/null 2>&1 || { echo "setup: msb stop $victim failed"; exit 2; }
victim_img=$MSB_HOME/sandboxes/$victim/upper.ext4
[ -f "$victim_img" ] || { echo "setup: no victim image at $victim_img"; exit 2; }
victim_sum=$(sha256sum "$victim_img" | cut -d' ' -f1)

"$msb" create --name "$name" --replace --cpus 1 --memory 512 "$image" >"$work/create.log" 2>&1 \
  || { echo "setup: msb create $name failed"; cat "$work/create.log"; exit 2; }
g "$name" "echo own > /own-marker && sync" || { echo "setup: own write failed"; exit 2; }
seen=$(g "$name" "ls -a /.msb | tr '\n' ' '" 2>&1)
echo "guest /.msb: $seen"
ok=0
g "$name" "! test -e /.msb/root-disk.json && ! test -e /.msb/runtime-boot-id" && ok=1
case_result hidden "$ok" "ls -a /.msb: $seen"

"$msb" stop "$name" >/dev/null 2>&1 || { echo "setup: msb stop $name failed"; exit 2; }
runtime=$MSB_HOME/sandboxes/$name/runtime
journal=$runtime/root-disk.json
own_img=$MSB_HOME/sandboxes/$name/upper.ext4
[ -f "$journal" ] || { echo "setup: no journal at $journal"; ls -la "$runtime"; exit 2; }
cp "$journal" "$work/genuine.json"
echo "genuine journal: $(cat "$journal")"
hostile=$(printf '{"schema":"microsandbox.runtime-root-disk/1","volume_id":"vol_%s","device_id":"vdb","layout":"managed-upper","published_generation":0,"launch_base":"%s","layers":[{"layer_id":"layer_%s","path":"%s","format":"raw","integrity_root":null}]}' \
  "$(hex)" "$own_img" "$(hex)" "$victim_img")

start "$name" "$work/start-restart.log"; rc=$?
marker=$(g "$name" "cat /own-marker" 2>&1 | tr -d '\r\n')
ok=0; [ "$rc" -eq 0 ] && [ "$marker" = own ] && ok=1
case_result restart "$ok" "start rc=$rc /own-marker=$marker"

g "$name" "printf '%s' '$hostile' > /.msb/root-disk.json && sync" \
  || { echo "setup: guest journal write failed"; exit 2; }
"$msb" stop "$name" >/dev/null 2>&1 || { echo "setup: msb stop $name failed"; exit 2; }
start "$name" "$work/start-guest-tamper.log"; rc=$?
marker=$(g "$name" "cat /own-marker 2>/dev/null; test -e /victim-marker && echo +victim" 2>&1 | tr -d '\r\n')
sum=$(sha256sum "$victim_img" | cut -d' ' -f1)
ok=0; [ "$rc" -eq 0 ] && [ "$marker" = own ] && [ "$sum" = "$victim_sum" ] && ok=1
same=changed; cmp -s "$journal" "$work/genuine.json" && same=unchanged
case_result guest-tamper "$ok" "start rc=$rc markers=$marker victim image $( [ "$sum" = "$victim_sum" ] && echo unchanged || echo CHANGED ) host journal $same"

"$msb" stop "$name" >/dev/null 2>&1
printf '%s' "$hostile" >"$journal"
start "$name" "$work/start-host-tamper.log"; rc=$?
named=0
grep -rqs "outside its sandbox" "$work/start-host-tamper.log" "$MSB_HOME/sandboxes/$name/logs" && named=1
sum=$(sha256sum "$victim_img" | cut -d' ' -f1)
ok=0; [ "$rc" -ne 0 ] && [ "$named" = 1 ] && [ "$sum" = "$victim_sum" ] && ok=1
case_result host-tamper "$ok" "start rc=$rc refusal named=$named victim image $( [ "$sum" = "$victim_sum" ] && echo unchanged || echo CHANGED )"
sed 's/^/start (host-tamper): /' "$work/start-host-tamper.log" | tail -5

"$msb" stop "$name" >/dev/null 2>&1
cp "$work/genuine.json" "$journal"
start "$name" "$work/start-recover.log"; rc=$?
marker=$(g "$name" "cat /own-marker" 2>&1 | tr -d '\r\n')
ok=0; [ "$rc" -eq 0 ] && [ "$marker" = own ] && ok=1
case_result recover "$ok" "start rc=$rc /own-marker=$marker"
exit "$fail"
