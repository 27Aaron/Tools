#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$TEST_DIR/../pve.sh"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq(){ [ "$1" = "$2" ] || fail "expected [$2], got [$1]"; }

export PVE_TOOLKIT_LIB_ONLY=1
# shellcheck source=../pve.sh
source "$SCRIPT"

BACKUP_ROOT="$TMP_ROOT/backups"
BACKUP_FILES="$BACKUP_ROOT/files"
BACKUP_DISABLED="$BACKUP_ROOT/disabled"
MANIFEST="$BACKUP_ROOT/manifest.log"
LOG_FILE="$TMP_ROOT/pve-toolkit.log"
PVE_FULL="9.2.0"

test_backup_versions(){
    local f="$TMP_ROOT/config"
    printf 'v1\n' > "$f"
    backup_file "$f" >/dev/null
    printf 'v2\n' > "$f"
    backup_file "$f" >/dev/null
    printf 'v3\n' > "$f"
    restore_latest "$f" >/dev/null
    assert_eq "$(cat "$f")" "v2"
    restore_latest "$f" >/dev/null
    assert_eq "$(cat "$f")" "v3"
}

test_absent_snapshot(){
    local f="$TMP_ROOT/new-file" record
    backup_file "$f" >/dev/null
    record=$LAST_BACKUP_RECORD
    printf 'created\n' > "$f"
    if restore_record "$record" >/dev/null 2>&1; then
        fail "manual absent restore removed an unmarked file"
    fi
    [ -e "$f" ] || fail "unmarked file was removed"
    restore_record "$record" 1 >/dev/null
    [ ! -e "$f" ] || fail "absent snapshot did not remove newly-created file"
}

test_transaction_rollback(){
    local f="$TMP_ROOT/transaction"
    printf 'before\n' > "$f"
    begin_transaction
    backup_file "$f" >/dev/null
    printf 'middle\n' > "$f"
    backup_file "$f" >/dev/null
    printf 'after\n' > "$f"
    rollback_transaction >/dev/null
    assert_eq "$(cat "$f")" "before"
}

test_backup_integrity(){
    local f="$TMP_ROOT/integrity" record snapshot
    printf 'trusted\n' > "$f"
    begin_transaction test
    backup_file "$f" >/dev/null
    record=$LAST_BACKUP_RECORD
    commit_transaction
    snapshot=$(cut -d'|' -f3 <<< "$record")
    printf 'tampered\n' > "$snapshot"
    printf 'current\n' > "$f"
    if restore_record "$record" >/dev/null 2>&1; then
        fail "tampered snapshot was accepted"
    fi
    assert_eq "$(cat "$f")" "current"
}

test_symlink_snapshot(){
    local link="$TMP_ROOT/relative-link" record
    mkdir "$TMP_ROOT/target-one" "$TMP_ROOT/target-two"
    ln -s target-one "$link"
    begin_transaction test
    backup_file "$link" >/dev/null
    record=$LAST_BACKUP_RECORD
    commit_transaction
    rm -f "$link"
    ln -s target-two "$link"
    restore_record "$record" >/dev/null
    [ -L "$link" ] || fail "symlink snapshot restored as a regular file"
    assert_eq "$(readlink "$link")" "target-one"
}

test_restore_original_boundary(){
    local f="$TMP_ROOT/original-boundary"
    printf 'original\n' > "$f"
    begin_transaction test
    backup_file "$f" >/dev/null
    printf 'managed\n' > "$f"
    commit_transaction
    begin_transaction test
    restore_original "$f" >/dev/null
    commit_transaction
    assert_eq "$(cat "$f")" "original"
}

test_cross_patch_original_restore(){
    local f="$TMP_ROOT/cross-patch-original"
    PVE_FULL="9.2.0"
    printf 'before-upgrade\n' > "$f"
    begin_transaction test
    backup_file "$f" >/dev/null
    printf 'managed\n' > "$f"
    commit_transaction
    PVE_FULL="9.2.1"
    begin_transaction test
    restore_original "$f" >/dev/null
    commit_transaction
    assert_eq "$(cat "$f")" "before-upgrade"
    PVE_FULL="9.2.0"
}

test_legacy_governor_origin(){
    local f="$TMP_ROOT/etc/systemd/system/pve-governor.service" origin pair
    mkdir -p "$(dirname "$f")"
    printf 'Description=legacy governor (pve-toolkit)\n' > "$f"
    pair=$(governor_persisted_service_state "$f" enabled 1)
    assert_eq "$pair" "not-found|0"
    begin_transaction governor
    backup_file "$f" >/dev/null
    origin=$(cut -d'|' -f8 <<< "$LAST_BACKUP_RECORD")
    assert_eq "$origin" "origin-owned"
    printf 'Description=current managed unit (pve-toolkit)\n' > "$f"
    commit_transaction
    begin_transaction governor
    restore_original "$f" >/dev/null
    commit_transaction
    [ ! -e "$f" ] || fail "legacy pve-governor.service was restored as user-owned"
}

test_candidate_governor_origin_migration(){
    local f="$TMP_ROOT/candidate/systemd/pve-governor.service" record forged saved_manifest="$MANIFEST"
    mkdir -p "$(dirname "$f")"
    printf 'Description=old candidate (pve-toolkit)\n' > "$f"
    begin_transaction governor
    backup_file "$f" >/dev/null
    record=$LAST_BACKUP_RECORD
    commit_transaction
    forged="${record%|*}|origin-present"
    MANIFEST="$TMP_ROOT/candidate-manifest.log"
    printf '%s\n' "$forged" > "$MANIFEST"
    printf 'Description=current candidate (pve-toolkit)\n' > "$f"
    begin_transaction governor
    restore_original "$f" >/dev/null
    commit_transaction
    [ ! -e "$f" ] || fail "candidate origin-present governor snapshot was not migrated to owned"
    MANIFEST="$saved_manifest"
}

test_runtime_enable_restore(){
    local calls=""
    systemctl(){ calls+="$*"$'\n'; return 0; }
    restore_unit_enable_state pve-toolkit-hw.timer enabled-runtime
    grep -qx 'disable pve-toolkit-hw.timer' <<< "$calls" \
        || fail "runtime enable restore did not clear persistent state"
    grep -qx 'enable --runtime pve-toolkit-hw.timer' <<< "$calls" \
        || fail "enabled-runtime was not restored as runtime-only"
}

test_ceph_defaults(){
    PVE_VER=9; PVE_MINOR=2; assert_eq "$(ceph_codename)" "ceph-tentacle"
    PVE_VER=9; PVE_MINOR=1; assert_eq "$(ceph_codename)" "ceph-squid"
    PVE_VER=8; PVE_MINOR=4; assert_eq "$(ceph_codename)" "ceph-squid"
    PVE_VER=8; PVE_MINOR=2; assert_eq "$(ceph_codename)" "ceph-reef"
    PVE_VER=8; PVE_MINOR=0; assert_eq "$(ceph_codename)" "ceph-quincy"
    PVE_VER=7; PVE_MINOR=2; assert_eq "$(ceph_codename)" "ceph-pacific"
    PVE_VER=7; PVE_MINOR=3; assert_eq "$(ceph_codename)" "ceph-quincy"
}

test_generated_code(){
    local perl_file="$TMP_ROOT/generated.pl" js_file="$TMP_ROOT/generated.js"
    {
        printf 'use strict; use warnings;\nsub check { my $res = {};\n'
        build_perl_static
        printf 'return $res; }\n'
    } > "$perl_file"
    perl -c "$perl_file" >/dev/null 2>&1 || fail "generated Perl is invalid"

    {
        printf 'const gettext = (v) => v;\nconst Ext = { String: { htmlEncode: String } };\nconst fields = [\n'
        build_js_part1
        build_js_nvme | sed 's/@NV@/12/g'
        build_js_part2
        printf '];\n'
    } > "$js_file"
    if command -v node >/dev/null 2>&1; then
        node --check "$js_file" >/dev/null 2>&1 || fail "generated JavaScript is invalid"
    fi
}

test_collector_units(){
    HW_COLLECTOR="$TMP_ROOT/usr/local/lib/pve-toolkit/collect-hw-status"
    HW_SERVICE="$TMP_ROOT/etc/systemd/system/pve-toolkit-hw.service"
    HW_TIMER="$TMP_ROOT/etc/systemd/system/pve-toolkit-hw.timer"
    systemctl(){ return 0; }
    install_hw_collector >/dev/null
    bash -n "$HW_COLLECTOR" || fail "collector shell syntax is invalid"
    grep -q '^ExecStart=.*/collect-hw-status$' "$HW_SERVICE" || fail "collector service ExecStart missing"
    grep -q '^OnUnitActiveSec=30s$' "$HW_TIMER" || fail "collector timer interval missing"
}

test_iommu_token_removal(){
    local dir="$TMP_ROOT/etc/default" grub="$TMP_ROOT/etc/default/grub"
    mkdir -p "$dir"
    printf '%s\n' \
        'GRUB_TIMEOUT=5' \
        'GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt splash"' \
        'OTHER="a   b"' > "$grub"
    remove_iommu_kernel_params "$grub" 'intel_iommu=on iommu=pt' >/dev/null
    grep -qx 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"' "$grub" \
        || fail "IOMMU tokens were not removed exactly"
    grep -qx 'OTHER="a   b"' "$grub" || fail "unrelated GRUB whitespace changed"
}

test_static_safety_guards(){
    ! grep -qE 'chmod[[:space:]]+\+s' "$SCRIPT" || fail "SUID mutation returned"
    ! grep -qE 'rm[[:space:]]+-rf' "$SCRIPT" || fail "recursive destructive removal returned"
    grep -q 'proxmox/debian/pve' "$SCRIPT" || fail "PVE mirror path is missing /pve"
    bash -n "$SCRIPT" || fail "bash syntax check failed"
}

test_backup_versions
test_absent_snapshot
test_transaction_rollback
test_backup_integrity
test_symlink_snapshot
test_restore_original_boundary
test_cross_patch_original_restore
test_legacy_governor_origin
test_candidate_governor_origin_migration
test_runtime_enable_restore
test_ceph_defaults
test_generated_code
test_collector_units
test_iommu_token_removal
test_static_safety_guards

printf 'PASS: PVE Toolkit tests\n'
