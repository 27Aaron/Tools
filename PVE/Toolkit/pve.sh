#!/usr/bin/env bash
# =============================================================================
#  PVE Toolkit — Proxmox VE 一键优化 / 一键还原 脚本
# =============================================================================
#  兼容: PVE 9; PVE 7/8 仅保留遗留兼容（均已 EOL）
#
#  功能:
#    - 安全换源: 官方/中科大/清华，修改前快照，apt 验证失败自动回滚
#    - 格式适配: PVE9 deb822(.sources), PVE7/8 传统(.list), 按版本使用正确密钥
#    - 摘要信息: CPU温度/频率/功耗 + NVMe/SATA健康，30秒后台缓存不阻塞 API
#        * AMD (Tdie/Tctl/k10temp) 与 Intel 通吃, 核心数量不限(4个一行)
#        * NVMe 硬盘数量不限(动态探测), SATA 盘逐盘解析 SMART
#    - 硬件直通: x86_64 Intel/AMD + GRUB/systemd-boot 自动适配，不粗暴 blacklist
#    - CPU 电源模式: 切换 governor, systemd 开机自持 (不再用脆弱的 cron)
#    - Ceph: 跟随已安装大版本配源 / 只读退役检查（不提供危险的一键删除）
#    - 旧内核清理: 保护当前、pin 和最新两个备用内核，先做 APT 模拟
#    - 还原中心: 官方源还原 / 官方包重装 / 本脚本备份回滚 / 残留清理
#    - 系统体检: dpkg 校验系统文件是否被改动 + 软件源冲突检查
#
#  还原中心说明:
#    网上各种 PVE 脚本质量参差, 改坏软件源后 apt 直接瘫痪。本脚本内置:
#      1) 官方源还原 —— 按当前 PVE/Debian 版本重建官方基线并验证
#         (PVE9: deb822 格式 pve-enterprise.sources / proxmox.sources / ceph.sources;
#          PVE7/8: 传统 .list 格式; Debian 源同样按版本重建)
#      2) 官方包重装 —— `apt-get install --reinstall pve-manager proxmox-widget-toolkit`
#         可将被改过的 Nodes.pm / pvemanagerlib.js / proxmoxlib.js / APLInfo.pm /
#         pveceph.pm 一步还原为官方原版 (最可靠的还原方式)
#      3) 每次修改的独立不可变快照位于 /var/backups/pve-toolkit/files/
#         manifest.log 同时记录『文件原本不存在』状态，新建文件也可回滚
#
#
#  用法:
#    bash pve.sh              # 进入主菜单
#    bash pve.sh --status     # 只做系统体检
#    bash pve.sh --restore    # 直达还原中心
# =============================================================================

VERSION="1.1.0"

# 管道中任一命令失败时返回失败。这里刻意不启用 set -e，交互式维护脚本需要
# 在每个高风险步骤给出明确错误并决定是否回滚，而不是在半途中静默退出。
set -o pipefail

# ---------- 全局常量 ----------
TOOLKIT="pve-toolkit"
BACKUP_ROOT="/var/backups/pve-toolkit"
BACKUP_FILES="$BACKUP_ROOT/files"
BACKUP_DISABLED="$BACKUP_ROOT/disabled"
MANIFEST="$BACKUP_ROOT/manifest.log"
LOG_FILE="/var/log/pve-toolkit.log"
LOCK_FILE="/run/lock/pve-toolkit.lock"
STATE_ROOT="/var/lib/pve-toolkit"
GOV_STATE="$STATE_ROOT/governors.before"
IOMMU_STATE="$STATE_ROOT/iommu-added"

# 运行状态
NONINTERACTIVE=0
TRANSACTION_ACTIVE=0
TRANSACTION_ID=""
TRANSACTION_KIND="generic"
DISPLAY_TIMER_WAS_ACTIVE=0
DISPLAY_TIMER_ENABLE_STATE="not-found"
GOV_SERVICE_WAS_ACTIVE=0
GOV_SERVICE_ENABLE_STATE="not-found"
GOV_IMMEDIATE_STATE=""
BACKUP_SEQ=0
LAST_BACKUP_RECORD=""
declare -a TRANSACTION_RECORDS=()

NODES_PM="/usr/share/perl5/PVE/API2/Nodes.pm"
PVE_MANAGER_JS="/usr/share/pve-manager/js/pvemanagerlib.js"
PROXMOXLIB_JS="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
APLINFO_PM="/usr/share/perl5/PVE/APLInfo.pm"
PVECEPH_PM="/usr/share/perl5/PVE/CLI/pveceph.pm"
HW_COLLECTOR="/usr/local/lib/pve-toolkit/collect-hw-status"
HW_SERVICE="/etc/systemd/system/pve-toolkit-hw.service"
HW_TIMER="/etc/systemd/system/pve-toolkit-hw.timer"

# 镜像变量(由 choose_mirror 设置)
MIR_DEBIAN="" ; MIR_SEC="" ; MIR_PVE="" ; MIR_CEPH_ROOT=""

# 环境变量(由 detect_env 设置)
PVE_VER="" ; PVE_MINOR="" ; PVE_FULL="" ; DEB_CODE="" ; DEB_VER=""

# ---------- 输出与交互 ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_R=$'\033[31;1m'; C_G=$'\033[32;1m'; C_Y=$'\033[33;1m'
    C_B=$'\033[34;1m'; C_C=$'\033[36;1m'; C_N=$'\033[0m'
else
    C_R=""; C_G=""; C_Y=""; C_B=""; C_C=""; C_N=""
fi

ok()   { printf " %b[ OK ]%b %s\n"  "$C_G" "$C_N" "$*"; }
warn() { printf " %b[!!] %b %s\n"  "$C_Y" "$C_N" "$*"; }
err()  { printf " %b[FAIL]%b %s\n" "$C_R" "$C_N" "$*"; }
info() { printf " %b[..] %b %s\n"  "$C_C" "$C_N" "$*"; }
title(){ printf "\n %b========  %s  ========%b\n" "$C_B" "$*" "$C_N"; }

pause(){
    [ "$NONINTERACTIVE" = "0" ] && [ -t 0 ] && [ -t 1 ] || return 0
    read -r -p " 按 Enter 键继续..." _
}

clear_screen(){
    [ -t 1 ] && [ -n "${TERM:-}" ] && command clear 2>/dev/null || true
}

log(){
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    printf '%s | v%s | PVE %s | %s\n' "$(date '+%F %T')" "$VERSION" "${PVE_FULL:-?}" "$*" \
        >> "$LOG_FILE" 2>/dev/null || true
}

atomic_replace_path(){
    # POSIX rename 不会把“指向目录的符号链接”当作目录进入；GNU/BSD mv
    # 在这个边界上的选项不一致，因此使用 PVE 必备的 Perl 实现。
    local src="$1" dst="$2"
    [ -e "$src" ] || [ -L "$src" ] || return 1
    if [ -d "$dst" ] && [ ! -L "$dst" ]; then
        err "拒绝用文件覆盖目录: $dst"
        return 1
    fi
    perl -e 'rename($ARGV[0], $ARGV[1]) or die "$ARGV[0] -> $ARGV[1]: $!\n"' -- "$src" "$dst"
}

unit_enable_state(){
    local state
    state=$(systemctl is-enabled "$1" 2>/dev/null || true)
    case "$state" in
        enabled|enabled-runtime|disabled|masked|masked-runtime|static|indirect|generated|transient|alias|linked|linked-runtime)
            printf '%s\n' "$state" ;;
        *) printf 'not-found\n' ;;
    esac
}

restore_unit_enable_state(){
    local unit="$1" state="$2"
    case "$state" in
        linked|linked-runtime|alias)
            err "无法无损重建 systemd 的 ${state} 链接状态: $unit"
            return 1 ;;
    esac
    systemctl disable "$unit" >/dev/null 2>&1 || true
    case "$state" in
        enabled) systemctl enable "$unit" >/dev/null 2>&1 ;;
        enabled-runtime) systemctl enable --runtime "$unit" >/dev/null 2>&1 ;;
        masked) systemctl mask "$unit" >/dev/null 2>&1 ;;
        masked-runtime) systemctl mask --runtime "$unit" >/dev/null 2>&1 ;;
        *) return 0 ;;
    esac
}

apt_update_strict(){
    # APT 默认可能在部分仓库拉取失败、回退旧索引时仍返回 0。
    apt-get -o APT::Update::Error-Mode=any update
}

reinstall_installed_packages(){
    # 明确锁定当前已安装版本，避免“重装”在用户不知情时升级整包。
    local package version
    local -a specs=()
    for package in "$@"; do
        version=$(dpkg-query -W -f='${Version}' "$package" 2>/dev/null) \
            || { err "无法读取已安装包版本: $package"; return 1; }
        [ -n "$version" ] || { err "软件包未安装: $package"; return 1; }
        specs+=("${package}=${version}")
    done
    apt-get install --reinstall --no-upgrade -y "${specs[@]}"
}

verify_single_pve_repo(){
    local -a ent=() nos=() test=() all_ent=() all_nos=() all_test=()
    local ent_pattern='enterprise\.proxmox\.com/debian/pve|Components:[[:space:]]*pve-enterprise|[[:space:]]pve-enterprise([[:space:]]|$)'
    local nos_pattern='Components:[[:space:]]*pve-no-subscription|[[:space:]]pve-no-subscription([[:space:]]|$)'
    local test_pattern='Components:[[:space:]]*(pve-test|pvetest)|[[:space:]](pve-test|pvetest)([[:space:]]|$)'
    mapfile -t all_ent < <(active_repo_files "$ent_pattern")
    mapfile -t all_nos < <(active_repo_files "$nos_pattern")
    mapfile -t all_test < <(active_repo_files "$test_pattern")
    mapfile -t ent < <(active_repo_files "$ent_pattern" "$DEB_CODE")
    mapfile -t nos < <(active_repo_files "$nos_pattern" "$DEB_CODE")
    mapfile -t test < <(active_repo_files "$test_pattern" "$DEB_CODE")
    if [ ${#all_ent[@]} -ne ${#ent[@]} ] || [ ${#all_nos[@]} -ne ${#nos[@]} ] \
        || [ ${#all_test[@]} -ne ${#test[@]} ]; then
        err "检测到 PVE 仓库 suite 与当前 Debian ${DEB_CODE} 不匹配"
        return 1
    fi
    if [ ${#test[@]} -eq 0 ] && { \
        { [ ${#ent[@]} -eq 1 ] && [ ${#nos[@]} -eq 0 ]; } \
        || { [ ${#ent[@]} -eq 0 ] && [ ${#nos[@]} -eq 1 ]; }; }; then
        return 0
    fi
    err "PVE 仓库必须且只能启用一个稳定通道（企业=${#ent[@]}，无订阅=${#nos[@]}，测试=${#test[@]}）"
    return 1
}

active_debian_suites(){
    local f
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
        [ -r "$f" ] || continue
        awk '
            /^[[:space:]]*#/ || NF < 3 || $1 !~ /^deb(-src)?$/ { next }
            {
                type=$1; i=2
                if ($i ~ /^\[/) { while (i <= NF && $i !~ /\]$/) i++; i++ }
                uri=$i; suite=$(i+1)
                if (uri ~ /^https?:\/\/(deb\.debian\.org\/(debian|debian-security)|security\.debian\.org\/debian-security|ftp\.debian\.org\/debian|mirrors\.ustc\.edu\.cn\/debian(-security)?|mirrors\.tuna\.tsinghua\.edu\.cn\/debian(-security)?)\/?$/) print type "|" suite
            }
        ' "$f"
    done
    for f in /etc/apt/sources.list.d/*.sources; do
        [ -r "$f" ] || continue
        awk -v RS='' '
            {
                n=split($0, raw_lines, "\n"); effective=""
                for (i=1; i<=n; i++) if (raw_lines[i] !~ /^[[:space:]]*#/) effective=effective "\n" raw_lines[i]
                lower=tolower(effective)
                if (lower ~ /enabled:[[:space:]]*no/) next
                if (lower !~ /uris:[[:space:]]*https?:\/\/(deb\.debian\.org\/(debian|debian-security)|security\.debian\.org\/debian-security|ftp\.debian\.org\/debian|mirrors\.ustc\.edu\.cn\/debian(-security)?|mirrors\.tuna\.tsinghua\.edu\.cn\/debian(-security)?)/) next
                type="deb-src"
                n=split(effective, lines, "\n")
                for (i=1; i<=n; i++) {
                    field=tolower(lines[i])
                    if (field ~ /^[[:space:]]*types:/ && field ~ /(^|[[:space:]])deb([[:space:]]|$)/) type="deb"
                    if (field ~ /^[[:space:]]*suites:/) {
                        sub(/^[[:space:]]*suites:[[:space:]]*/, "", field)
                        m=split(field, suites, /[[:space:]]+/)
                        for (j=1; j<=m; j++) if (suites[j] != "") print type "|" suites[j]
                    }
                }
            }
        ' "$f"
    done
}

verify_debian_repos(){
    local type suite base=0 updates=0 security=0 unknown
    unknown=$(unknown_debian_like_sources)
    if [ -n "$unknown" ]; then
        err "存在未经确认的 Debian-like 自定义仓库:"
        printf '%s\n' "$unknown" | sed 's/^/    /'
        return 1
    fi
    while IFS='|' read -r type suite; do
        case "$suite" in
            "$DEB_CODE") [ "$type" != "deb" ] || base=$((base + 1)) ;;
            "${DEB_CODE}-updates") [ "$type" != "deb" ] || updates=$((updates + 1)) ;;
            "${DEB_CODE}-security") [ "$type" != "deb" ] || security=$((security + 1)) ;;
            "${DEB_CODE}-backports") ;;
            bullseye*|bookworm*|trixie*)
                err "检测到与当前 Debian ${DEB_CODE} 不匹配的基础源 suite: $suite"
                return 1 ;;
        esac
    done < <(active_debian_suites)
    if [ "$base" -ne 1 ] || [ "$updates" -ne 1 ] || [ "$security" -ne 1 ]; then
        err "Debian 基础源必须各且只有一份（${DEB_CODE}=$base, updates=$updates, security=$security）"
        return 1
    fi
}

confirm(){
    local a
    [ "$NONINTERACTIVE" = "0" ] && [ -t 0 ] || return 1
    read -r -p " ${1:-确认执行?} [y/N]: " a || return 1
    [[ "$a" =~ ^[Yy]$ ]]
}

ask(){
    local a
    [ "$NONINTERACTIVE" = "0" ] && [ -t 0 ] || return 1
    read -r -p " ${1}: " a || return 1
    printf '%s' "$a"
}

# =============================================================================
#  环境检测
# =============================================================================
require_env(){
    if [ "$(id -u)" != "0" ]; then
        err "请使用 root 用户运行本脚本!"
        exit 2
    fi
    if ! command -v pveversion >/dev/null 2>&1; then
        err "未检测到 Proxmox VE (pveversion 不存在)。"
        err "本脚本只能在 PVE 宿主机上运行!"
        exit 2
    fi
    detect_env

    local expected=""
    case "$PVE_VER" in
        7) expected="bullseye" ;;
        8) expected="bookworm" ;;
        9) expected="trixie" ;;
        *)
            err "不支持的 PVE 主版本: ${PVE_VER:-未知} (仅支持 7/8/9)"
            exit 2 ;;
    esac
    if [ "$DEB_CODE" != "$expected" ]; then
        err "PVE ${PVE_VER} 与 Debian ${DEB_CODE:-未知} 不匹配 (应为 ${expected})。"
        err "为避免写入错误软件源，已中止。"
        exit 2
    fi
    if [ "$PVE_VER" -le 8 ]; then
        warn "PVE ${PVE_VER} 已结束上游常规支持，建议尽快规划升级到 PVE 9。"
    fi
}

detect_env(){
    PVE_FULL=$(pveversion 2>/dev/null | awk -F'/' '{print $2}')
    PVE_VER=${PVE_FULL%%.*}
    PVE_MINOR=$(printf '%s' "$PVE_FULL" | cut -d. -f2 | grep -oE '^[0-9]+' || true)
    DEB_CODE=""
    if [ -r /etc/os-release ]; then
        . /etc/os-release
        DEB_CODE=${VERSION_CODENAME:-}
    fi
    if [ -z "$DEB_CODE" ] && [ -r /etc/debian_version ]; then
        case $(cut -d. -f1 /etc/debian_version) in
            13) DEB_CODE=trixie ;;  12) DEB_CODE=bookworm ;;
            11) DEB_CODE=bullseye ;; 10) DEB_CODE=buster ;;
            9)  DEB_CODE=stretch ;;
        esac
    fi
    # Debian 版本主版本号(显示用)
    case "$DEB_CODE" in
        trixie) DEB_VER=13 ;;  bookworm) DEB_VER=12 ;; bullseye) DEB_VER=11 ;;
        buster) DEB_VER=10 ;; stretch) DEB_VER=9 ;;  *) DEB_VER="?" ;;
    esac
}

# 防止两个维护会话同时改宿主机。
acquire_lock(){
    command -v flock >/dev/null 2>&1 || { warn "未找到 flock，无法启用并发保护"; return 0; }
    mkdir -p "$(dirname "$LOCK_FILE")"
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        err "另一个 PVE Toolkit 正在运行，请稍后再试。"
        exit 2
    fi
}

# 优先跟随已安装/已配置的 Ceph 大版本，避免混用包。
# 仅在新节点没有任何线索时才使用 PVE 对应的默认值。
ceph_codename(){
    local release="" source_file raw
    local -a releases=()
    local -A unique=()
    if command -v ceph >/dev/null 2>&1; then
        raw=$(ceph --version 2>/dev/null || true)
        release=$(grep -oE '\b(pacific|quincy|reef|squid|tentacle)\b' <<< "$raw" | head -n1)
        if [ -n "$raw" ] && [ -z "$release" ]; then
            err "无法识别已安装的 Ceph 大版本: $raw" >&2
            return 1
        fi
    fi
    if [ -z "$release" ]; then
        for source_file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
            [ -r "$source_file" ] || continue
            if [[ "$source_file" == *.sources ]]; then
                raw=$(awk -v RS='' '
                    {
                        n=split($0, lines, "\n"); effective=""
                        for (i=1; i<=n; i++) if (lines[i] !~ /^[[:space:]]*#/) effective=effective "\n" lines[i]
                        if (tolower(effective) !~ /enabled:[[:space:]]*no/) print effective
                    }
                ' "$source_file")
            else
                raw=$(sed -E '/^[[:space:]]*#/d' "$source_file")
            fi
            while IFS= read -r release; do
                release=${release#ceph-}
                [ -n "$release" ] && unique["$release"]=1
            done < <(grep -oE 'ceph-(pacific|quincy|reef|squid|tentacle)' <<< "$raw" | sort -u)
        done
        releases=("${!unique[@]}")
        if [ ${#releases[@]} -gt 1 ]; then
            err "检测到多个已启用的 Ceph 大版本: ${releases[*]}；为避免混源已中止。" >&2
            return 1
        fi
        [ ${#releases[@]} -eq 1 ] && release=${releases[0]}
    fi
    if [ -z "$release" ]; then
        case "$PVE_VER" in
            9)
                if [ "${PVE_MINOR:-0}" -ge 2 ]; then release="tentacle"; else release="squid"; fi
                ;;
            8)
                case "${PVE_MINOR:-0}" in
                    0) release="quincy" ;;
                    1|2|3) release="reef" ;;
                    *) release="squid" ;;
                esac
                ;;
            7)
                if [ "${PVE_MINOR:-0}" -ge 3 ]; then release="quincy"; else release="pacific"; fi
                ;;
        esac
    fi
    case "${PVE_VER}:${release}" in
        7:pacific|7:quincy|8:quincy|8:reef|8:squid|9:squid|9:tentacle) ;;
        *)
            err "Ceph ${release} 与 PVE ${PVE_VER} 不在支持矩阵中；请先按官方升级顺序完成迁移。" >&2
            return 1 ;;
    esac
    printf 'ceph-%s\n' "$release"
}

warn_ceph_cluster_scope(){
    local nodes=0
    command -v pvecm >/dev/null 2>&1 || return 0
    nodes=$(timeout 5 pvecm nodes 2>/dev/null \
        | awk '$1 ~ /^[0-9]+$/ { count++ } END { print count + 0 }')
    if [ "${nodes:-0}" -gt 1 ]; then
        warn "检测到 ${nodes} 节点集群：本操作只修改当前节点的软件源，请在其他节点分别执行并保持 Ceph 大版本一致。"
    fi
}

# =============================================================================
#  备份 / 回滚框架
#    每次修改都创建不可变的独立快照；不再用同一备份路径覆盖旧版。
#    manifest.log: 时间戳|原路径|备份路径|present/absent|事务ID|PVE版本|类型化SHA256|原始标记
# =============================================================================
snapshot_hash(){
    local path="$1" target digest
    if [ -L "$path" ]; then
        target=$(readlink -- "$path") || return 1
        digest=$(printf '%s' "$target" | sha256sum | awk '{print $1}') || return 1
        printf 'link:%s\n' "$digest"
    elif [ -f "$path" ]; then
        digest=$(sha256sum "$path" 2>/dev/null | awk '{print $1}') || return 1
        printf 'file:%s\n' "$digest"
    else
        return 1
    fi
}

backup_file(){
    local f="$1" stamp dest state record txid="" free_kb total_kb free_inodes size_kb=0 required_kb reserve_kb hash="-" origin="-"
    [[ "$f" = /* ]] || { err "备份路径必须是绝对路径: $f"; return 1; }
    BACKUP_SEQ=$((BACKUP_SEQ + 1))
    stamp="$(date '+%Y%m%d-%H%M%S')-$$-${BACKUP_SEQ}"
    dest="-"
    state="absent"

    umask 077
    mkdir -p "$BACKUP_FILES" || { err "无法创建备份目录: $BACKUP_FILES"; return 1; }
    if [ -e "$f" ] && [ ! -L "$f" ] && [ ! -f "$f" ]; then
        err "仅支持普通文件或符号链接快照: $f"
        return 1
    fi
    [ -e "$f" ] && [ ! -L "$f" ] && size_kb=$(( ($(stat -c '%s' "$f" 2>/dev/null || echo 0) + 1023) / 1024 ))
    free_kb=$(df -Pk "$BACKUP_FILES" 2>/dev/null | awk 'NR == 2 {print $4}')
    total_kb=$(df -Pk "$BACKUP_FILES" 2>/dev/null | awk 'NR == 2 {print $2}')
    free_inodes=$(df -Pi "$BACKUP_FILES" 2>/dev/null | awk 'NR == 2 {print $4}')
    reserve_kb=524288
    if [ -n "$total_kb" ] && [ $((total_kb / 20)) -gt "$reserve_kb" ]; then reserve_kb=$((total_kb / 20)); fi
    required_kb=$((size_kb + reserve_kb)) # 快照后保留至少 512 MiB 或分区 5%
    if [ -n "$free_kb" ] && [ "$free_kb" -lt "$required_kb" ]; then
        err "备份空间不足：需要 ${required_kb} KiB，可用 ${free_kb} KiB"
        return 1
    fi
    if [ -n "$free_inodes" ] && [ "$free_inodes" -lt 1000 ]; then
        err "备份分区可用 inode 少于 1000，已中止变更"
        return 1
    fi
    if [ -e "$f" ] || [ -L "$f" ]; then
        dest="${BACKUP_FILES}/${stamp}${f}"
        mkdir -p "$(dirname "$dest")" || return 1
        cp -a -- "$f" "$dest" || { err "备份失败: $f"; return 1; }
        hash=$(snapshot_hash "$dest")
        [ -n "$hash" ] || { err "无法计算备份 SHA-256: $dest"; return 1; }
        state="present"
    fi

    [ "$TRANSACTION_ACTIVE" = "1" ] && txid="$TRANSACTION_ID"
    # origin-* 是 1.1+ 的可信接管边界。旧版同名工具文件视作本工具所有，
    # 防止升级后把旧 service/state 误当成用户原件永久恢复。
    if ! awk -F'|' -v path="$f" '$2 == path && $5 != "" && $6 != "" && $6 != "unknown" \
        && $8 ~ /^origin-(present|absent|owned)$/ { found=1 } END { exit !found }' \
        "$MANIFEST" 2>/dev/null; then
        origin="origin-${state}"
        if [ "$state" = "present" ]; then
            case "$f" in
                /usr/local/lib/pve-toolkit/*|/var/lib/pve-toolkit/*|\
                /etc/systemd/system/pve-toolkit-*|/etc/modules-load.d/pve-toolkit-*|\
                /etc/apt/sources.list.d/pve-toolkit-*) origin="origin-owned" ;;
            esac
            case "$f" in
                /usr/share/perl5/PVE/*|/usr/share/pve-manager/*)
                    grep -qi 'pve-toolkit' "$f" 2>/dev/null && origin="origin-untrusted" ;;
                */pve-governor.service)
                    grep -qi 'pve-toolkit' "$f" 2>/dev/null && origin="origin-owned" ;;
            esac
        fi
    fi
    record="${stamp}|${f}|${dest}|${state}|${txid}|${PVE_FULL:-unknown}|${hash}|${origin}"
    printf '%s\n' "$record" >> "$MANIFEST" || { err "无法写入备份索引"; return 1; }
    LAST_BACKUP_RECORD="$record"
    if [ "$TRANSACTION_ACTIVE" = "1" ]; then
        TRANSACTION_RECORDS+=("$record")
    fi
    log "backup path=$f state=$state snapshot=$dest"
    if [ "$state" = "present" ]; then
        ok "已备份: $f"
    else
        info "已记录文件原本不存在: $f"
    fi
}

restore_record(){
    local record="$1" force="${2:-0}" ts f d state txid snapshot_pve expected_hash origin actual_hash tmp
    IFS='|' read -r ts f d state txid snapshot_pve expected_hash origin <<< "$record"
    [[ "$f" = /* ]] || { err "备份索引中的路径非法: $f"; return 1; }
    state=${state:-present} # 兼容 v1.0 的三列 manifest
    if [ "$state" = "absent" ]; then
        if [ "$force" != "1" ]; then
            case "$f" in
                /usr/local/lib/pve-toolkit/*|/var/lib/pve-toolkit/*|\
                /etc/systemd/system/pve-toolkit-*|/etc/modules-load.d/pve-toolkit-*|\
                /etc/apt/sources.list.d/pve-toolkit-*) ;;
                *)
                    if ! grep -qi 'pve-toolkit' "$f" 2>/dev/null; then
                        err "拒绝删除『原本不存在』但已无本工具标记的文件: $f"
                        err "该文件可能已被软件包或管理员接管，请用官方包重装或手动确认。"
                        return 1
                    fi
                    ;;
            esac
        fi
        rm -f -- "$f" || { err "无法恢复『原本不存在』状态: $f"; return 1; }
    else
        [ -e "$d" ] || [ -L "$d" ] || { err "备份文件丢失: $d"; return 1; }
        { [ ! -d "$d" ] || [ -L "$d" ]; } && { [ ! -d "$f" ] || [ -L "$f" ]; } \
            || { err "不支持目录级原样回滚: $f"; return 1; }
        if [ -n "$expected_hash" ] && [ "$expected_hash" != "-" ]; then
            case "$expected_hash" in
                link:*)
                    [ -L "$d" ] || { err "备份类型不符（应为符号链接）: $d"; return 1; }
                    actual_hash=$(snapshot_hash "$d") ;;
                file:*)
                    [ -f "$d" ] && [ ! -L "$d" ] \
                        || { err "备份类型不符（应为普通文件）: $d"; return 1; }
                    actual_hash=$(snapshot_hash "$d") ;;
                [0-9a-f][0-9a-f]*)
                    [ -f "$d" ] && [ ! -L "$d" ] \
                        || { err "旧格式符号链接快照不安全，拒绝恢复: $d"; return 1; }
                    actual_hash=$(sha256sum "$d" 2>/dev/null | awk '{print $1}') ;;
                *) err "备份哈希格式非法: $d"; return 1 ;;
            esac
            [ "$actual_hash" = "$expected_hash" ] \
                || { err "备份 SHA-256 不匹配，拒绝恢复: $d"; return 1; }
        fi
        mkdir -p "$(dirname "$f")" || return 1
        tmp=$(mktemp "${f}.pve-toolkit-restore.XXXXXX") || return 1
        rm -f "$tmp"
        cp -a -- "$d" "$tmp" || { rm -f "$tmp"; err "回滚准备失败: $f"; return 1; }
        atomic_replace_path "$tmp" "$f" || { rm -f "$tmp"; err "原子回滚失败: $f"; return 1; }
    fi
    log "restore path=$f state=$state snapshot=$d"
    ok "已回滚: $f"
}

restore_latest(){
    local f="$1" allow_package="${2:-0}" latest="" latest_tx="" latest_pve="" ts p d state txid snapshot_pve snapshot_hash origin
    [ -e "$MANIFEST" ] || { warn "还没有备份记录"; return 1; }
    while IFS='|' read -r ts p d state txid snapshot_pve snapshot_hash origin; do
        if [ "$p" = "$f" ]; then
            latest="${ts}|${p}|${d}|${state:-present}|${txid}|${snapshot_pve}|${snapshot_hash}|${origin}"
            latest_tx="$txid"
            latest_pve="$snapshot_pve"
        fi
    done < "$MANIFEST"
    [ -n "$latest" ] || { warn "没有 $f 的备份记录"; return 1; }

    # 同一事务可能多次触碰同一文件。手动回滚应恢复事务开始前的
    # 第一份快照，而不是中间态。
    if [ -n "$latest_tx" ]; then
        while IFS='|' read -r ts p d state txid snapshot_pve snapshot_hash origin; do
            if [ "$p" = "$f" ] && [ "$txid" = "$latest_tx" ]; then
                latest="${ts}|${p}|${d}|${state:-present}|${txid}|${snapshot_pve}|${snapshot_hash}|${origin}"
                latest_pve="$snapshot_pve"
                break
            fi
        done < "$MANIFEST"
    fi

    case "$f" in
        /usr/share/perl5/PVE/*|/usr/share/pve-manager/*|/usr/share/javascript/proxmox-widget-toolkit/*)
            if [ "$allow_package" != "1" ]; then
                err "手动原样回滚软件包所有文件不安全: $f"
                err "该包可能已独立升级；请使用『官方包重装』。"
                return 1
            fi
            if [ -z "$latest_pve" ] || [ "$latest_pve" = "unknown" ] || [ "$latest_pve" != "$PVE_FULL" ]; then
                err "拒绝跨 PVE 版本回滚系统文件: $f"
                return 1
            fi
            ;;
    esac
    case "$f" in
        /etc/apt/*|/usr/share/keyrings/proxmox-*|/etc/default/grub|/etc/kernel/cmdline)
            if [ -z "$latest_pve" ] || [ "$latest_pve" = "unknown" ] \
                || [ "${latest_pve%%.*}" != "${PVE_FULL%%.*}" ]; then
                err "拒绝跨 PVE 主版本回滚软件源/密钥/引导文件: $f"
                err "快照 PVE=${latest_pve:-未知}, 当前 PVE=${PVE_FULL:-未知}"
                return 1
            fi
            ;;
    esac

    # 先固定『要恢复的记录』，再备份当前状态，这样回滚也可撤销。
    backup_file "$f" || return 1
    restore_record "$latest"
}

restore_original(){
    # 仅信任 1.1+ 明确记录的接管边界；旧版三列快照可能已被覆盖，绝不
    # 把它当作原件。origin-owned 表示升级时发现的旧工具文件，应恢复为不存在。
    local f="$1" first="" ts p d state txid snapshot_pve snapshot_hash origin effective_origin actual_hash
    [ -e "$MANIFEST" ] || return 1
    while IFS='|' read -r ts p d state txid snapshot_pve snapshot_hash origin; do
        if [ "$p" = "$f" ] && [ -n "$txid" ] && [ -n "$snapshot_pve" ] && [ "$snapshot_pve" != "unknown" ] \
            && [[ "$origin" =~ ^origin-(present|absent|owned)$ ]] \
            && { [ "$state" = "absent" ] || [[ "$snapshot_hash" =~ ^(file|link):[0-9a-f]{64}$ ]]; }; then
            case "$f" in
                /usr/share/perl5/PVE/*|/usr/share/pve-manager/*|/usr/share/javascript/proxmox-widget-toolkit/*)
                    [ "$snapshot_pve" = "$PVE_FULL" ] || continue ;;
            esac
            effective_origin="$origin"
            case "$f" in
                */pve-governor.service)
                    if [ "$origin" = "origin-present" ] && [ -e "$d" ] \
                        && grep -qi 'pve-toolkit' "$d" 2>/dev/null; then
                        actual_hash=$(snapshot_hash "$d" 2>/dev/null || true)
                        [ "$actual_hash" = "$snapshot_hash" ] && effective_origin="origin-owned"
                    fi ;;
            esac
            if [ "$effective_origin" = "origin-owned" ] || [ "$effective_origin" = "origin-absent" ]; then
                first="${ts}|${p}|-|absent|${txid}|${snapshot_pve}|-|${origin}"
            else
                first="${ts}|${p}|${d}|${state}|${txid}|${snapshot_pve}|${snapshot_hash}|${origin}"
            fi
            break
        fi
    done < "$MANIFEST"
    [ -n "$first" ] || return 1
    backup_file "$f" || return 1
    restore_record "$first"
}

begin_transaction(){
    TRANSACTION_ACTIVE=1
    TRANSACTION_KIND="${1:-generic}"
    TRANSACTION_ID="$(date '+%Y%m%d-%H%M%S')-$$-$((BACKUP_SEQ + 1))"
    TRANSACTION_RECORDS=()
}

commit_transaction(){
    TRANSACTION_ACTIVE=0
    TRANSACTION_ID=""
    TRANSACTION_KIND="generic"
    TRANSACTION_RECORDS=()
}

rollback_transaction(){
    local i failed=0 kind="$TRANSACTION_KIND"
    [ "$TRANSACTION_ACTIVE" = "1" ] || return 0
    TRANSACTION_ACTIVE=0
    warn "正在按相反顺序回滚本次变更..."
    for ((i=${#TRANSACTION_RECORDS[@]} - 1; i >= 0; i--)); do
        restore_record "${TRANSACTION_RECORDS[$i]}" 1 || failed=1
    done
    TRANSACTION_RECORDS=()
    TRANSACTION_ID=""
    TRANSACTION_KIND="generic"
    post_rollback "$kind" || failed=1
    [ "$failed" = "0" ]
}

post_rollback(){
    local kind="$1" failed=0
    case "$kind" in
        boot)
            update-grub >/dev/null 2>&1 || failed=1
            if command -v proxmox-boot-tool >/dev/null 2>&1; then proxmox-boot-tool refresh >/dev/null 2>&1 || failed=1; fi
            update-initramfs -u >/dev/null 2>&1 || failed=1
            ;;
        display_apply|display_remove)
            systemctl daemon-reload >/dev/null 2>&1 || failed=1
            restore_unit_enable_state pve-toolkit-hw.timer "$DISPLAY_TIMER_ENABLE_STATE" || failed=1
            if [ "$DISPLAY_TIMER_WAS_ACTIVE" = "1" ]; then
                systemctl start pve-toolkit-hw.timer >/dev/null 2>&1 || failed=1
            else
                systemctl stop pve-toolkit-hw.timer >/dev/null 2>&1 || true
            fi
            systemctl restart pveproxy pvedaemon >/dev/null 2>&1 || failed=1
            ;;
        ct) systemctl restart pvedaemon >/dev/null 2>&1 || failed=1 ;;
        nag) systemctl restart pveproxy >/dev/null 2>&1 || failed=1 ;;
        governor)
            systemctl daemon-reload >/dev/null 2>&1 || failed=1
            restore_unit_enable_state pve-governor.service "$GOV_SERVICE_ENABLE_STATE" || failed=1
            if [ "$GOV_SERVICE_WAS_ACTIVE" = "1" ]; then
                systemctl start pve-governor.service >/dev/null 2>&1 || failed=1
            else
                systemctl stop pve-governor.service >/dev/null 2>&1 || true
            fi
            ;;
        restore)
            systemctl daemon-reload >/dev/null 2>&1 || failed=1
            update-grub >/dev/null 2>&1 || failed=1
            if command -v proxmox-boot-tool >/dev/null 2>&1; then proxmox-boot-tool refresh >/dev/null 2>&1 || failed=1; fi
            update-initramfs -u >/dev/null 2>&1 || failed=1
            systemctl restart pveproxy pvedaemon >/dev/null 2>&1 || failed=1
            ;;
    esac
    [ "$failed" = "0" ]
}

replace_file(){
    # 用法: replace_file /绝对/路径 [新文件模式] <<EOF
    local f="$1" mode="${2:-0644}" tmp
    [[ "$f" = /* ]] || return 1
    mkdir -p "$(dirname "$f")" || return 1
    tmp=$(mktemp "${f}.pve-toolkit.XXXXXX") || return 1
    if ! cat > "$tmp"; then rm -f "$tmp"; return 1; fi
    if [ -e "$f" ] && cmp -s "$tmp" "$f"; then
        rm -f "$tmp"
        info "内容未变，跳过: $f"
        return 0
    fi
    backup_file "$f" || { rm -f "$tmp"; return 1; }
    if [ -e "$f" ]; then
        chmod --reference="$f" "$tmp" 2>/dev/null || chmod "$mode" "$tmp"
        chown --reference="$f" "$tmp" 2>/dev/null || true
    else
        chmod "$mode" "$tmp"
    fi
    atomic_replace_path "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

disable_file(){
    local f="$1"
    [ -e "$f" ] || [ -L "$f" ] || return 0
    backup_file "$f" || return 1
    rm -f -- "$f" || return 1
    warn "已禁用并可从备份恢复: $f"
}

restart_pve_web(){
    if systemctl restart pveproxy; then
        ok "已重启 pveproxy (Web控制台)"
    else
        err "pveproxy 重启失败，请执行: systemctl status pveproxy"
        return 1
    fi
}

# =============================================================================
#  PVE 密钥保障
#    PVE9: /usr/share/keyrings/proxmox-archive-keyring.gpg (deb822 Signed-By)
#    PVE7/8: /etc/apt/trusted.gpg.d/proxmox-release-<codename>.gpg
# =============================================================================
ensure_pve_keyring(){
    local target url checksum_algo checksum tmp actual expected_fpr="" key_valid=0
    case "$PVE_VER" in
        9)
            target="/usr/share/keyrings/proxmox-archive-keyring.gpg"
            url="https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg"
            checksum_algo="sha256sum"
            checksum="136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45"
            expected_fpr="24B30F06ECC1836A4E5EFECBA7BCD1420BFE778E"
            ;;
        8)
            target="/etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg"
            url="https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg"
            checksum_algo="sha256sum"
            checksum="13a87cec79f2d05f40f125629e4b509080a5c0286608bea273e36be9809ecaba"
            expected_fpr="F4E136C67CDCE41AE6DE6FC81140AF8F639E0C39"
            ;;
        7)
            target="/etc/apt/trusted.gpg.d/proxmox-release-bullseye.gpg"
            url="https://enterprise.proxmox.com/debian/proxmox-release-bullseye.gpg"
            checksum_algo="sha256sum"
            checksum="411b420c3ab024d099e1ef55d06695a9d90a7db7c49b76fa719b453eb376093e"
            expected_fpr="28139A2F830BD68478A1A01FDD4BA3917E23BF59"
            ;;
    esac
    if [ -s "$target" ] && command -v gpg >/dev/null 2>&1; then
        if [ -n "$expected_fpr" ]; then
            gpg --batch --show-keys --with-colons "$target" 2>/dev/null \
                | awk -F: '$1 == "fpr" {print $10}' | grep -qx "$expected_fpr" && key_valid=1
        elif gpg --batch --show-keys "$target" >/dev/null 2>&1; then
            key_valid=1
        fi
    elif [ -s "$target" ]; then
        if [ "$PVE_VER" -le 8 ] && [ "$($checksum_algo "$target" | awk '{print $1}')" = "$checksum" ]; then
            key_valid=1
        elif [ "$PVE_VER" = "9" ] && dpkg-query -W proxmox-archive-keyring >/dev/null 2>&1 \
            && ! dpkg -V proxmox-archive-keyring 2>/dev/null | grep -q .; then
            key_valid=1
        else
            warn "系统缺少 gpg，且现有 Proxmox 密钥无法通过包/校验和验证"
        fi
    fi
    if [ "$key_valid" = "1" ]; then
        ok "Proxmox 密钥已存在且可解析: $target"
        return 0
    elif [ -e "$target" ]; then
        warn "现有 Proxmox 密钥不可验证，将在备份后用官方密钥修复"
    fi
    command -v wget >/dev/null 2>&1 || { err "缺少 wget，无法下载 Proxmox 密钥"; return 1; }
    mkdir -p "$(dirname "$target")" || return 1
    tmp=$(mktemp "${target}.pve-toolkit.XXXXXX") || return 1
    info "从 Proxmox 官方站下载并校验密钥..."
    if ! wget -q --timeout=15 --tries=2 "$url" -O "$tmp"; then
        rm -f "$tmp"
        err "密钥下载失败: $url"
        return 1
    fi
    actual=$($checksum_algo "$tmp" | awk '{print $1}')
    if [ "$actual" != "$checksum" ]; then
        rm -f "$tmp"
        err "Proxmox 密钥校验失败，已拒绝安装"
        log "keyring checksum mismatch expected=$checksum actual=$actual url=$url"
        return 1
    fi
    backup_file "$target" || { rm -f "$tmp"; return 1; }
    chmod 0644 "$tmp"
    if atomic_replace_path "$tmp" "$target"; then
        ok "Proxmox 密钥安装完成: $target"
    else
        rm -f "$tmp"
        return 1
    fi
}

# =============================================================================
#  官方源写入函数 (换源与还原共用, 内容由参数决定)
# =============================================================================

# 写 Debian 源  $1=基础URI $2=安全URI
unknown_debian_like_sources(){
    local f
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
        [ -r "$f" ] || continue
        awk -v file="$f" '
            /^[[:space:]]*#/ || $1 !~ /^deb(-src)?$/ { next }
            {
                i=2; if ($i ~ /^\[/) { while (i <= NF && $i !~ /\]$/) i++; i++ }
                uri=$i; suite=$(i+1); hasmain=0
                for (j=i+2; j<=NF; j++) if ($j == "main") hasmain=1
                known=(uri ~ /^https?:\/\/(deb\.debian\.org\/(debian|debian-security)|security\.debian\.org\/debian-security|ftp\.debian\.org\/debian|mirrors\.ustc\.edu\.cn\/debian(-security)?|mirrors\.tuna\.tsinghua\.edu\.cn\/debian(-security)?)\/?$/)
                proxmox=(uri ~ /(proxmox|\/ceph-|\/debian\/pve)/)
                if (suite ~ /^(bullseye|bookworm|trixie)(-(updates|security|backports))?$/ && hasmain && !known && !proxmox) print file ":" NR ":" uri " " suite
            }
        ' "$f"
    done
    for f in /etc/apt/sources.list.d/*.sources; do
        [ -r "$f" ] || continue
        awk -v RS='' -v file="$f" '
            {
                n=split($0, lines, "\n"); effective=""
                for (i=1; i<=n; i++) if (lines[i] !~ /^[[:space:]]*#/) effective=effective "\n" lines[i]
                lower=tolower(effective)
                if (lower ~ /enabled:[[:space:]]*no/) next
                if (lower !~ /suites:[^\n]*(bullseye|bookworm|trixie)/ || lower !~ /components:[^\n]*main/) next
                if (lower ~ /uris:[[:space:]]*https?:\/\/(deb\.debian\.org\/(debian|debian-security)|security\.debian\.org\/debian-security|ftp\.debian\.org\/debian|mirrors\.ustc\.edu\.cn\/debian(-security)?|mirrors\.tuna\.tsinghua\.edu\.cn\/debian(-security)?)/) next
                if (lower ~ /uris:[^\n]*(proxmox|\/ceph-|\/debian\/pve)/) next
                print file ": custom Debian-like stanza"
            }
        ' "$f"
    done
}

comment_legacy_debian_entries(){
    local skip="${1:-}" f tmp
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
        [ -r "$f" ] || continue
        [ "$f" = "$skip" ] && continue
        tmp=$(mktemp "${f}.pve-toolkit.XXXXXX") || return 1
        awk '
            /^[[:space:]]*#/ || $1 !~ /^deb(-src)?$/ { print; next }
            {
                i=2; if ($i ~ /^\[/) { while (i <= NF && $i !~ /\]$/) i++; i++ }
                uri=$i
                if (uri ~ /^https?:\/\/(deb\.debian\.org\/(debian|debian-security)|security\.debian\.org\/debian-security|ftp\.debian\.org\/debian|mirrors\.ustc\.edu\.cn\/debian(-security)?|mirrors\.tuna\.tsinghua\.edu\.cn\/debian(-security)?)\/?$/) print "# disabled by pve-toolkit: " $0
                else print
            }
        ' "$f" > "$tmp"
        if cmp -s "$tmp" "$f"; then rm -f "$tmp"; continue; fi
        backup_file "$f" || { rm -f "$tmp"; return 1; }
        chmod --reference="$f" "$tmp" 2>/dev/null || chmod 0644 "$tmp"
        chown --reference="$f" "$tmp" 2>/dev/null || true
        atomic_replace_path "$tmp" "$f" || return 1
    done
    for f in /etc/apt/sources.list.d/*.sources; do
        [ -r "$f" ] || continue
        [ "$f" = "$skip" ] && continue
        if ! awk -v RS='' '
            {
                n=split($0, lines, "\n"); effective=""
                for (i=1; i<=n; i++) if (lines[i] !~ /^[[:space:]]*#/) effective=effective "\n" lines[i]
                lower=tolower(effective)
                if (lower !~ /enabled:[[:space:]]*no/ \
                    && lower ~ /uris:[[:space:]]*https?:\/\/(deb\.debian\.org\/(debian|debian-security)|security\.debian\.org\/debian-security|ftp\.debian\.org\/debian|mirrors\.ustc\.edu\.cn\/debian(-security)?|mirrors\.tuna\.tsinghua\.edu\.cn\/debian(-security)?)/) found=1
            }
            END { exit !found }
        ' "$f"; then
            continue
        fi
        tmp=$(mktemp "${f}.pve-toolkit.XXXXXX") || return 1
        awk -v RS='' -v ORS='\n\n' '
            {
                block=$0; n=split(block, lines, "\n"); effective=""
                for (i=1; i<=n; i++) if (lines[i] !~ /^[[:space:]]*#/) effective=effective "\n" lines[i]
                lower=tolower(effective)
                matchuri=(lower ~ /uris:[[:space:]]*https?:\/\/(deb\.debian\.org\/(debian|debian-security)|security\.debian\.org\/debian-security|ftp\.debian\.org\/debian|mirrors\.ustc\.edu\.cn\/debian(-security)?|mirrors\.tuna\.tsinghua\.edu\.cn\/debian(-security)?)/)
                if (!matchuri) { print block; next }
                rebuilt=""; had=0
                for (i=1; i<=n; i++) {
                    if (lines[i] !~ /^[[:space:]]*#/ && tolower(lines[i]) ~ /^[[:space:]]*enabled:/) { lines[i]="Enabled: no"; had=1 }
                    rebuilt=rebuilt (i > 1 ? "\n" : "") lines[i]
                }
                print (had ? rebuilt : "Enabled: no\n" rebuilt)
            }
        ' "$f" > "$tmp"
        if cmp -s "$tmp" "$f"; then rm -f "$tmp"; continue; fi
        backup_file "$f" || { rm -f "$tmp"; return 1; }
        chmod --reference="$f" "$tmp" 2>/dev/null || chmod 0644 "$tmp"
        chown --reference="$f" "$tmp" 2>/dev/null || true
        atomic_replace_path "$tmp" "$f" || return 1
    done
}

write_debian_repos(){
    local base="$1" sec="$2" comp target unknown
    mkdir -p /etc/apt/sources.list.d || return 1
    case "$DEB_CODE" in
        trixie|bookworm) comp="main contrib non-free non-free-firmware" ;;
        *)               comp="main contrib non-free" ;;
    esac

    if [ "$DEB_VER" = "13" ]; then target="/etc/apt/sources.list.d/pve-toolkit-debian.sources"; else target="/etc/apt/sources.list.d/pve-toolkit-debian.list"; fi
    unknown=$(unknown_debian_like_sources)
    if [ -n "$unknown" ]; then
        err "检测到无法安全判定用途的 Debian-like 自定义仓库，为避免重复/误禁用已中止:"
        printf '%s\n' "$unknown" | sed 's/^/    /'
        return 1
    fi

    if [ "$DEB_VER" = "13" ]; then
        # Debian 13 / PVE9 官方默认 deb822。仅注释 sources.list 中的
        # Debian 条目，保留用户的其他第三方仓库。
        comment_legacy_debian_entries "$target" || return 1
        replace_file "$target" 0644 <<DEB822EOF
# Managed by pve-toolkit
Types: deb
URIs: ${base}
Suites: ${DEB_CODE} ${DEB_CODE}-updates
Components: ${comp}
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: ${sec}
Suites: ${DEB_CODE}-security
Components: ${comp}
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
DEB822EOF
        [ "$?" = "0" ] || return 1
    else
        # Debian 11/12: 使用独立文件，不覆盖 sources.list 中的用户配置。
        comment_legacy_debian_entries "$target" || return 1
        replace_file "$target" 0644 <<LISTEOF
# Managed by pve-toolkit
deb ${base} ${DEB_CODE} ${comp}
deb ${base} ${DEB_CODE}-updates ${comp}
deb ${sec} ${DEB_CODE}-security ${comp}
LISTEOF
        [ "$?" = "0" ] || return 1
    fi
    ok "Debian 源写入完成 (${DEB_CODE})"
}

# 写 PVE 仓库  $1=enterprise|nosub  $2=基础URI
comment_legacy_proxmox_entries(){
    local kind="$1" skip="${2:-}" f tmp pattern
    case "$kind" in
        pve)  pattern='pve-(enterprise|no-subscription|test)|pvetest' ;;
        ceph) pattern='ceph-(pacific|quincy|reef|squid|tentacle)' ;;
        *) return 1 ;;
    esac
    # 注释所有 .list 中的同类活动条目（包括自定义文件名）。
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
        [ -r "$f" ] || continue
        [ "$f" = "$skip" ] && continue
        tmp=$(mktemp "${f}.pve-toolkit.XXXXXX") || return 1
        sed -E "\#^[[:space:]]*deb(-src)?[[:space:]].*${pattern}([[:space:]/]|$)# s|^|# disabled by pve-toolkit: |" \
            "$f" > "$tmp"
        if cmp -s "$tmp" "$f"; then rm -f "$tmp"; continue; fi
        backup_file "$f" || { rm -f "$tmp"; return 1; }
        chmod --reference="$f" "$tmp" 2>/dev/null || chmod 0644 "$tmp"
        chown --reference="$f" "$tmp" 2>/dev/null || true
        atomic_replace_path "$tmp" "$f" || return 1
    done
    # deb822 可以一文件多 stanza；只对匹配 stanza 加 Enabled: no，保留其他仓库。
    for f in /etc/apt/sources.list.d/*.sources; do
        [ -r "$f" ] || continue
        [ "$f" = "$skip" ] && continue
        if ! awk -v RS='' -v pattern="$pattern" '
            {
                n=split($0, lines, "\n"); effective=""
                for (i=1; i<=n; i++) if (lines[i] !~ /^[[:space:]]*#/) effective=effective "\n" lines[i]
                lower=tolower(effective)
                if (lower !~ /enabled:[[:space:]]*no/ && lower ~ pattern) found=1
            }
            END { exit !found }
        ' "$f"; then
            continue
        fi
        tmp=$(mktemp "${f}.pve-toolkit.XXXXXX") || return 1
        awk -v RS='' -v ORS='\n\n' -v pattern="$pattern" '
            {
                block=$0; n=split(block, lines, "\n"); effective=""
                for (i=1; i<=n; i++) if (lines[i] !~ /^[[:space:]]*#/) effective=effective "\n" lines[i]
                lower=tolower(effective)
                if (lower ~ pattern) {
                    rebuilt=""; had=0
                    for (i=1; i<=n; i++) {
                        if (lines[i] !~ /^[[:space:]]*#/ && tolower(lines[i]) ~ /^[[:space:]]*enabled:/) {
                            lines[i]="Enabled: no"; had=1
                        }
                        rebuilt=rebuilt (i > 1 ? "\n" : "") lines[i]
                    }
                    print (had ? rebuilt : "Enabled: no\n" rebuilt)
                } else {
                    print block
                }
            }
        ' "$f" > "$tmp"
        if cmp -s "$tmp" "$f"; then rm -f "$tmp"; continue; fi
        backup_file "$f" || { rm -f "$tmp"; return 1; }
        chmod --reference="$f" "$tmp" 2>/dev/null || chmod 0644 "$tmp"
        chown --reference="$f" "$tmp" 2>/dev/null || true
        atomic_replace_path "$tmp" "$f" || return 1
    done
}

write_pve_repo(){
    local kind="$1" base="$2" comp target f
    mkdir -p /etc/apt/sources.list.d || return 1
    if [ "$kind" = "enterprise" ]; then
        comp="pve-enterprise"
        if [ "$PVE_VER" = "9" ]; then
            target="/etc/apt/sources.list.d/pve-enterprise.sources"
        else
            target="/etc/apt/sources.list.d/pve-enterprise.list"
        fi
        comment_legacy_proxmox_entries pve "$target" || return 1
        for f in /etc/apt/sources.list.d/proxmox.sources \
                 /etc/apt/sources.list.d/pve-no-subscription.sources \
                 /etc/apt/sources.list.d/pve-no-subscription.list \
                 /etc/apt/sources.list.d/pve-install-repo.list; do
            [ "$f" = "$target" ] || disable_file "$f" || return 1
        done
    else
        comp="pve-no-subscription"
        if [ "$PVE_VER" = "9" ]; then
            target="/etc/apt/sources.list.d/proxmox.sources"
        else
            target="/etc/apt/sources.list.d/pve-no-subscription.list"
        fi
        comment_legacy_proxmox_entries pve "$target" || return 1
        for f in /etc/apt/sources.list.d/pve-enterprise.sources \
                 /etc/apt/sources.list.d/pve-enterprise.list \
                 /etc/apt/sources.list.d/proxmox.sources \
                 /etc/apt/sources.list.d/pve-no-subscription.sources \
                 /etc/apt/sources.list.d/pve-no-subscription.list \
                 /etc/apt/sources.list.d/pve-install-repo.list; do
            [ "$f" = "$target" ] || disable_file "$f" || return 1
        done
    fi

    if [ "$PVE_VER" = "9" ]; then
        replace_file "$target" 0644 <<PVE822EOF
# Managed by pve-toolkit
Types: deb
URIs: ${base}
Suites: ${DEB_CODE}
Components: ${comp}
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
PVE822EOF
        [ "$?" = "0" ] || return 1
    else
        replace_file "$target" 0644 <<PVE7EOF
# Managed by pve-toolkit
deb ${base} ${DEB_CODE} ${comp}
PVE7EOF
        [ "$?" = "0" ] || return 1
    fi
    ok "PVE 仓库写入完成: $(basename "$target") (${comp})"
}

# 兼容旧调用；真正的互斥清理已由 write_pve_repo 按目标类型完成。
clean_pve_repo_conflicts(){
    return 0
}

# 写 Ceph 仓库  $1=enterprise|nosub  $2=基础URI
write_ceph_repo(){
    local kind="$1" base="$2" comp cc target
    mkdir -p /etc/apt/sources.list.d || return 1
    cc=$(ceph_codename) || return 1
    if [ "$PVE_VER" = "9" ]; then
        target="/etc/apt/sources.list.d/ceph.sources"
    else
        target="/etc/apt/sources.list.d/ceph.list"
    fi
    comment_legacy_proxmox_entries ceph "$target" || return 1
    if [ "$PVE_VER" = "7" ]; then
        comp="main"
        if [ "$kind" = "enterprise" ]; then
            warn "PVE 7 的 Ceph 仓库不使用 enterprise 组件，已改用官方 main"
            base="http://download.proxmox.com/debian"
        fi
    elif [ "$kind" = "enterprise" ]; then
        comp="enterprise"
    else
        comp="no-subscription"
    fi

    if [ "$PVE_VER" = "9" ]; then
        disable_file /etc/apt/sources.list.d/ceph.list || return 1
        replace_file "$target" 0644 <<CEPH822EOF
# Managed by pve-toolkit
Types: deb
URIs: ${base}/${cc}
Suites: ${DEB_CODE}
Components: ${comp}
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
CEPH822EOF
        [ "$?" = "0" ] || return 1
    else
        disable_file /etc/apt/sources.list.d/ceph.sources || return 1
        replace_file "$target" 0644 <<CEPH7EOF
# Managed by pve-toolkit
deb ${base}/${cc} ${DEB_CODE} ${comp}
CEPH7EOF
        [ "$?" = "0" ] || return 1
    fi
    ok "Ceph 仓库写入完成: ${cc} (${comp})"
}

# 关闭企业源 (保留不可变快照, 可在还原中心找回)
disable_enterprise_repos(){
    local include_ceph="${1:-1}" p found=0 tmp legacy_pattern
    for p in /etc/apt/sources.list.d/pve-enterprise.sources \
             /etc/apt/sources.list.d/pve-enterprise.list \
             /etc/apt/sources.list.d/ceph.sources \
             /etc/apt/sources.list.d/ceph.list; do
        if [ "$include_ceph" != "1" ] && [[ "$p" == */ceph.* ]]; then continue; fi
        if [ -e "$p" ] && grep -qE '^[^#]*(enterprise\.proxmox\.com|Components:[[:space:]]*enterprise|[[:space:]]enterprise([[:space:]]|$))' "$p" 2>/dev/null; then
            disable_file "$p" || return 1
            found=1
        fi
    done
    # 用户选择『不处理 Ceph』时，只注释 PVE 企业行，不碰 Ceph 企业行。
    if [ "$include_ceph" = "1" ]; then
        legacy_pattern='enterprise\.proxmox\.com'
    else
        legacy_pattern='enterprise\.proxmox\.com/debian/pve|pve-enterprise'
    fi
    if grep -qE "^[[:space:]]*deb.*(${legacy_pattern})" /etc/apt/sources.list 2>/dev/null; then
        tmp=$(mktemp /etc/apt/sources.list.pve-toolkit.XXXXXX) || return 1
        sed -E "\#^[[:space:]]*deb.*(${legacy_pattern})# s|^|# disabled by pve-toolkit: |" \
            /etc/apt/sources.list > "$tmp"
        backup_file /etc/apt/sources.list || { rm -f "$tmp"; return 1; }
        chmod --reference=/etc/apt/sources.list "$tmp" 2>/dev/null || chmod 0644 "$tmp"
        chown --reference=/etc/apt/sources.list "$tmp" 2>/dev/null || true
        atomic_replace_path "$tmp" /etc/apt/sources.list || return 1
        warn "已注释 sources.list 中的企业源"
        found=1
    fi
    if [ "$found" = "0" ]; then info "未发现企业源, 跳过"; fi
    return 0
}

# 选择镜像站
choose_mirror(){
    while :; do
        clear_screen
        cat <<MENUEOF

   ${C_Y}选择镜像站${C_N}
   ------------------------------------------------
    1. 中科大镜像站 (推荐)
    2. 清华大学镜像站
    3. 官方源 (deb.debian.org / download.proxmox.com)
    0. 返回
   ------------------------------------------------
MENUEOF
        local m
        read -r -t 60 -p " 请选择 [默认1，超时取消]: " m || return 1
        m=${m:-1}
        case "$m" in
            1)
                MIR_DEBIAN="https://mirrors.ustc.edu.cn/debian"
                MIR_SEC="https://security.debian.org/debian-security"
                MIR_PVE="https://mirrors.ustc.edu.cn/proxmox/debian/pve"
                MIR_CEPH_ROOT="https://mirrors.ustc.edu.cn/proxmox/debian"
                return 0 ;;
            2)
                MIR_DEBIAN="https://mirrors.tuna.tsinghua.edu.cn/debian"
                MIR_SEC="https://security.debian.org/debian-security"
                MIR_PVE="https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian/pve"
                MIR_CEPH_ROOT="https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian"
                return 0 ;;
            3)
                MIR_DEBIAN="https://deb.debian.org/debian"
                MIR_SEC="https://security.debian.org/debian-security"
                MIR_PVE="http://download.proxmox.com/debian/pve"
                MIR_CEPH_ROOT="http://download.proxmox.com/debian"
                return 0 ;;
            0) return 1 ;;
            *) ;;
        esac
    done
}

# CT 模板源 (APLInfo.pm): 把 download.proxmox.com 指到镜像
switch_ct_source(){
    local root="$1" tmp
    [ -e "$APLINFO_PM" ] || { warn "未找到 APLInfo.pm, 跳过 CT 模板源"; return 1; }
    tmp=$(mktemp "${APLINFO_PM}.pve-toolkit.XXXXXX") || return 1
    sed -E \
        "s|https?://(download\\.proxmox\\.com|mirrors\\.ustc\\.edu\\.cn/proxmox|mirrors\\.tuna\\.tsinghua\\.edu\\.cn/proxmox)|${root}|g" \
        "$APLINFO_PM" > "$tmp"
    if cmp -s "$tmp" "$APLINFO_PM"; then
        rm -f "$tmp"
        ok "CT 模板源已是目标地址"
    else
        if ! grep -Fq "$root" "$tmp"; then
            rm -f "$tmp"
            err "APLInfo.pm 中未找到可识别的模板源，已中止"
            return 1
        fi
        backup_file "$APLINFO_PM" || { rm -f "$tmp"; return 1; }
        chmod --reference="$APLINFO_PM" "$tmp" 2>/dev/null || true
        chown --reference="$APLINFO_PM" "$tmp" 2>/dev/null || true
        atomic_replace_path "$tmp" "$APLINFO_PM" || return 1
        ok "CT 模板源已切换: $root"
        systemctl restart pvedaemon || { err "pvedaemon 重启失败"; return 1; }
    fi
    info "刷新 CT 模板列表..."
    if pveam update; then
        ok "CT 模板列表已刷新"
    else
        err "CT 模板列表刷新失败"
        return 1
    fi
}

# =============================================================================
#  一键优化
# =============================================================================
one_key_optimize(){
    clear_screen
    title "一键优化 PVE"
    info "当前环境: PVE ${PVE_FULL:-?} (Debian ${DEB_CODE:-?})"
    choose_mirror || return 0
    local with_ceph=0 with_ct=0 with_nag=0 ct_root ceph_release="" rc=0
    confirm "本机使用 Ceph，同时切换 Ceph 源?" && with_ceph=1
    confirm "同时修改 PVE 包文件以加速 CT 模板下载?" && with_ct=1
    confirm "同时修改 Web 包文件以移除订阅提示?" && with_nag=1

    echo
    title "变更预览"
    info "Debian 源: $MIR_DEBIAN (安全更新保持官方源)"
    info "PVE 源:    $MIR_PVE (no-subscription)"
    if [ "$with_ceph" = "1" ]; then
        ceph_release=$(ceph_codename) || return 1
        warn_ceph_cluster_scope
        info "Ceph 源:   $MIR_CEPH_ROOT/$ceph_release"
    fi
    [ "$with_ct" = "1" ] && info "CT 模板源: 修改 APLInfo.pm（包升级后可能需重做）"
    [ "$with_nag" = "1" ] && info "订阅提示: 修改 proxmoxlib.js（包升级后可能需重做）"
    warn "no-subscription 更新验证强度低于企业源，生产集群优先使用有订阅的企业源。"
    info "每个文件都会存入不可变快照: $BACKUP_FILES"
    confirm "确认执行上述变更?" || { info "已取消"; return 0; }

    begin_transaction sources
    echo; title "1/5 验证 PVE 密钥"
    ensure_pve_keyring || rc=1
    if [ "$rc" = "0" ]; then
        echo; title "2/5 更换 Debian 系统源"
        write_debian_repos "$MIR_DEBIAN" "$MIR_SEC" || rc=1
    fi
    if [ "$rc" = "0" ]; then
        echo; title "3/5 更换 PVE 无订阅源"
        write_pve_repo nosub "$MIR_PVE" || rc=1
    fi
    if [ "$rc" = "0" ] && [ "$with_ceph" = "1" ]; then
        echo; title "4/5 更换 Ceph 源"
        write_ceph_repo nosub "$MIR_CEPH_ROOT" || rc=1
    fi
    if [ "$rc" = "0" ]; then
        disable_enterprise_repos "$with_ceph" || rc=1
    fi
    if [ "$rc" = "0" ]; then
        echo; title "5/5 验证软件源"
        if ! apt_update_strict || ! verify_single_pve_repo || ! verify_debian_repos; then
            err "apt-get update 失败，不保留本次源配置"
            rc=1
        fi
    fi
    if [ "$rc" != "0" ]; then
        if rollback_transaction; then
            warn "源配置已恢复到本次操作前状态"
        else
            err "源配置回滚不完整，请勿继续升级；请检查 $MANIFEST"
        fi
        log "one-key optimize failed and rolled back"
        err "一键优化失败。"
        return 1
    fi
    commit_transaction

    if [ "$with_ct" = "1" ]; then
        case "$MIR_PVE" in
            *ustc*) ct_root="https://mirrors.ustc.edu.cn/proxmox" ;;
            *tuna*) ct_root="https://mirrors.tuna.tsinghua.edu.cn/proxmox" ;;
            *)      ct_root="http://download.proxmox.com" ;;
        esac
        begin_transaction ct
        if switch_ct_source "$ct_root"; then
            commit_transaction
        else
            rollback_transaction || true
            systemctl restart pvedaemon >/dev/null 2>&1 || true
            rc=1
        fi
    fi
    if [ "$with_nag" = "1" ]; then
        begin_transaction nag
        if remove_nag; then
            commit_transaction
        else
            rollback_transaction || true
            restart_pve_web >/dev/null 2>&1 || true
            rc=1
        fi
    fi

    echo
    if [ "$rc" = "0" ]; then
        ok "一键优化完成，且 apt 源已验证。"
        log "one-key optimize completed mirror=$MIR_PVE ceph=$with_ceph ct=$with_ct nag=$with_nag"
    else
        warn "软件源已成功，但可选项存在失败，请查看上方输出和 $LOG_FILE"
        log "one-key optimize completed with optional-step failure"
    fi
    info "脚本不会自动升级生产宿主机。需要时请手动执行: apt-get dist-upgrade"
    return "$rc"
}

# 手动换源菜单
source_menu(){
    clear_screen
    title "软件源管理"
    local act rc=0 ct_root
    read -r -t 60 -p " 1.只换Debian源 2.只换PVE源 3.只换Ceph源 4.只换CT模板源 5.关闭企业源 0.返回: " act || return 0
    case "$act" in
        0|"") return 0 ;;
        1|2|3)
            choose_mirror || return 0
            confirm "执行后将立即 apt-get update 验证，失败自动回滚。继续?" || return 0
            begin_transaction sources
            case "$act" in
                1) write_debian_repos "$MIR_DEBIAN" "$MIR_SEC" || rc=1 ;;
                2) ensure_pve_keyring && write_pve_repo nosub "$MIR_PVE" || rc=1 ;;
                3) warn_ceph_cluster_scope; ensure_pve_keyring && write_ceph_repo nosub "$MIR_CEPH_ROOT" || rc=1 ;;
            esac
            if [ "$rc" = "0" ] && apt_update_strict && verify_single_pve_repo \
                && { [ "$act" != "1" ] || verify_debian_repos; }; then
                commit_transaction
                ok "软件源已更新并验证"
            else
                err "配置或 apt 验证失败"
                rollback_transaction
                return 1
            fi
            ;;
        4)
            choose_mirror || return 0
            case "$MIR_PVE" in
                *ustc*) ct_root="https://mirrors.ustc.edu.cn/proxmox" ;;
                *tuna*) ct_root="https://mirrors.tuna.tsinghua.edu.cn/proxmox" ;;
                *)      ct_root="http://download.proxmox.com" ;;
            esac
            confirm "将修改 pve-manager 的 APLInfo.pm 并重启 pvedaemon，继续?" || return 0
            begin_transaction ct
            if switch_ct_source "$ct_root"; then
                commit_transaction
            else
                rollback_transaction || err "CT 模板源回滚不完整"
                return 1
            fi
            ;;
        5)
            local -a existing_nos=()
            mapfile -t existing_nos < <(active_repo_files 'Components:[[:space:]]*pve-no-subscription|[[:space:]]pve-no-subscription([[:space:]]|$)' "$DEB_CODE")
            [ ${#existing_nos[@]} -eq 1 ] || { err "未检测到唯一可用的 PVE no-subscription 源，拒绝直接关闭企业源。"; return 1; }
            confirm "禁用 PVE 企业源（不改 Ceph）?" || return 0
            begin_transaction sources
            if disable_enterprise_repos 0 && apt_update_strict && verify_single_pve_repo; then
                commit_transaction
                ok "企业源已禁用，apt 验证通过"
            else
                rollback_transaction
                return 1
            fi
            ;;
        *) warn "无效选择: $act"; return 1 ;;
    esac
}

# =============================================================================
#  订阅弹窗
# =============================================================================
remove_nag(){
    local tmp
    [ -e "$PROXMOXLIB_JS" ] || { err "未找到 proxmoxlib.js"; return 1; }
    if grep -qE 'if[[:space:]]*\([[:space:]]*false[[:space:]]*\)' "$PROXMOXLIB_JS"; then
        ok "订阅弹窗此前已移除, 跳过"
        return 0
    fi
    tmp=$(mktemp "${PROXMOXLIB_JS}.pve-toolkit.XXXXXX") || return 1
    cp -a "$PROXMOXLIB_JS" "$tmp" || { rm -f "$tmp"; return 1; }
    info "正在移除无有效订阅弹窗..."
    sed -r -i "/\/nodes\/localhost\/subscription/,+30 {
        /^\s+if\s*\(/ {
            :loop
            N
            /\s*\)\s*\{/!b loop
            s/(if\s*\([[:space:]]*res\s*===\s*null\s*(\|\|\s*res\s*===\s*undefined\s*)?(\|\|\s*!res\s*)?(\|\|\s*res\.data\.status\.toLowerCase\(\)\s*!==\s*['\'']active['\'']\s*)?[[:space:]]*\)\s*\{)/if(false){/
        }
    }" "$tmp"
    if ! grep -qE 'if[[:space:]]*\([[:space:]]*false[[:space:]]*\)' "$tmp"; then
        rm -f "$tmp"
        warn "自动替换未命中，可能是新版代码结构；原文件未做任何修改。"
        return 1
    fi
    if command -v node >/dev/null 2>&1 && ! node --check "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        err "proxmoxlib.js JavaScript 语法校验失败，原文件未修改"
        return 1
    fi
    backup_file "$PROXMOXLIB_JS" || { rm -f "$tmp"; return 1; }
    chmod --reference="$PROXMOXLIB_JS" "$tmp" 2>/dev/null || true
    chown --reference="$PROXMOXLIB_JS" "$tmp" 2>/dev/null || true
    atomic_replace_path "$tmp" "$PROXMOXLIB_JS" || return 1
    ok "订阅提示已移除"
    restart_pve_web
}

restore_nag(){
    info "重装 proxmox-widget-toolkit 以还原订阅弹窗..."
    if reinstall_installed_packages proxmox-widget-toolkit; then
        ok "已还原为官方原版"
        restart_pve_web
    else
        err "重装失败, 请先修复软件源(还原中心选项1)"
        return 1
    fi
}

# =============================================================================
#  硬件直通
# =============================================================================
pt_status(){
    title "硬件直通状态"
    if [ -d /sys/kernel/iommu_groups ] && find /sys/kernel/iommu_groups -mindepth 1 -maxdepth 1 -type d -print -quit 2>/dev/null | grep -q .; then
        ok "IOMMU 已在内核中启用"
    else
        warn "未检测到 IOMMU 分组（可能尚未重启，或 BIOS 未开启 VT-d/AMD-Vi）"
    fi
    local n
    n=$(find /sys/kernel/iommu_groups -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    if [ "${n:-0}" -gt 0 ]; then
        ok "检测到 ${n} 个 IOMMU 分组"
    else
        warn "未检测到 IOMMU 分组"
    fi
    info "当前内核参数: $(cat /proc/cmdline 2>/dev/null)"
    [ -e /etc/modules-load.d/pve-toolkit-vfio.conf ] \
        && ok "vfio 模块已由本工具配置开机加载" || info "本工具未配置 vfio 模块"
}

detect_bootloader(){
    local current entry
    if command -v efibootmgr >/dev/null 2>&1; then
        current=$(efibootmgr 2>/dev/null | awk '/^BootCurrent:/ {print $2}')
        if [ -n "$current" ]; then
            entry=$(efibootmgr -v 2>/dev/null | grep -i "^Boot${current}" | head -n1)
            if grep -qiE 'systemd-boot|Linux Boot Manager' <<< "$entry"; then
                printf 'systemd-boot\n'
            else
                printf 'grub\n'
            fi
            return 0
        fi
    fi
    if [ -d /sys/firmware/efi/efivars ] \
        && command -v bootctl >/dev/null 2>&1 && bootctl is-installed >/dev/null 2>&1; then
        printf 'systemd-boot\n'
    else
        printf 'grub\n'
    fi
}

refresh_boot_config(){
    local loader="$1"
    if [ "$loader" = "systemd-boot" ]; then
        command -v proxmox-boot-tool >/dev/null 2>&1 || { err "缺少 proxmox-boot-tool"; return 1; }
        proxmox-boot-tool refresh
    else
        update-grub || return 1
        if command -v proxmox-boot-tool >/dev/null 2>&1; then
            proxmox-boot-tool refresh || return 1
        fi
    fi
}

add_iommu_kernel_params(){
    local loader="$1" params="$2" f tmp current p missing=""
    IOMMU_ADDED_PARAMS=""
    IOMMU_TARGET_FILE=""
    if [ "$loader" = "systemd-boot" ]; then
        f="/etc/kernel/cmdline"
        [ -e "$f" ] || { err "未找到 $f，拒绝猜测内核命令行"; return 1; }
        current=$(tr '\n' ' ' < "$f" | sed -E 's/[[:space:]]+$//')
        for p in $params; do
            grep -qw -- "$p" <<< "$current" || missing+=" $p"
        done
        IOMMU_ADDED_PARAMS=${missing# }
        IOMMU_TARGET_FILE="$f"
        [ -z "$missing" ] && { info "systemd-boot 已包含所需 IOMMU 参数"; return 0; }
        replace_file "$f" 0644 <<EOF
${current}${missing}
EOF
    else
        f="/etc/default/grub"
        [ -e "$f" ] || { err "未找到 $f"; return 1; }
        current=$(sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/\1/p' "$f" | head -n1)
        for p in $params; do
            grep -qw -- "$p" <<< "$current" || missing+=" $p"
        done
        IOMMU_ADDED_PARAMS=${missing# }
        IOMMU_TARGET_FILE="$f"
        [ -z "$missing" ] && { info "GRUB 已包含所需 IOMMU 参数"; return 0; }
        tmp=$(mktemp "${f}.pve-toolkit.XXXXXX") || return 1
        awk -v extra="$missing" '
            BEGIN { done=0 }
            /^GRUB_CMDLINE_LINUX_DEFAULT="/ && !done {
                sub(/"$/, extra "\""); done=1
            }
            { print }
            END { if (!done) print "GRUB_CMDLINE_LINUX_DEFAULT=\"" substr(extra, 2) "\"" }
        ' "$f" > "$tmp"
        backup_file "$f" || { rm -f "$tmp"; return 1; }
        chmod --reference="$f" "$tmp" 2>/dev/null || chmod 0644 "$tmp"
        chown --reference="$f" "$tmp" 2>/dev/null || true
        atomic_replace_path "$tmp" "$f"
    fi
}

remove_iommu_kernel_params(){
    local f="$1" remove="$2" tmp current filtered="" token drop p
    [ -e "$f" ] || return 0
    [ -n "$remove" ] || { info "本工具上次未新增 IOMMU 参数，不删除用户原有参数"; return 0; }
    if [[ "$f" == */default/grub ]]; then
        current=$(sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/\1/p' "$f" | head -n1)
    else
        current=$(tr '\n' ' ' < "$f" | sed -E 's/[[:space:]]+$//')
    fi
    for token in $current; do
        drop=0
        for p in $remove; do [ "$token" = "$p" ] && drop=1; done
        [ "$drop" = "1" ] || filtered="${filtered}${filtered:+ }${token}"
    done
    tmp=$(mktemp "${f}.pve-toolkit.XXXXXX") || return 1
    if [[ "$f" == */default/grub ]]; then
        awk -v value="$filtered" '
            /^GRUB_CMDLINE_LINUX_DEFAULT="/ { print "GRUB_CMDLINE_LINUX_DEFAULT=\"" value "\""; next }
            { print }
        ' "$f" > "$tmp"
    else
        printf '%s\n' "$filtered" > "$tmp"
    fi
    if cmp -s "$tmp" "$f"; then rm -f "$tmp"; return 0; fi
    backup_file "$f" || { rm -f "$tmp"; return 1; }
    chmod --reference="$f" "$tmp" 2>/dev/null || chmod 0644 "$tmp"
    chown --reference="$f" "$tmp" 2>/dev/null || true
    atomic_replace_path "$tmp" "$f" || return 1
}

validate_iommu_state(){
    local loader="$1" target="$2" added="$3" token
    case "${loader}|${target}" in
        'grub|/etc/default/grub'|'systemd-boot|/etc/kernel/cmdline') ;;
        *) return 1 ;;
    esac
    for token in $added; do
        case "$token" in intel_iommu=on|amd_iommu=on|iommu=pt) ;; *) return 1 ;; esac
    done
}

pt_enable(){
    clear_screen
    title "开启硬件直通"
    if [ "$(uname -m)" != "x86_64" ]; then
        err "当前自动直通配置仅支持 x86_64；未对 $(uname -m) 写入任何参数。"
        return 1
    fi
    local params loader rc=0 state_loader="" state_target="" existing_added="" merged_added="" token
    if grep -q 'GenuineIntel' /proc/cpuinfo; then
        params="intel_iommu=on iommu=pt"
        info "检测到 Intel 平台: 使用 intel_iommu=on iommu=pt"
    elif grep -q 'AuthenticAMD' /proc/cpuinfo; then
        params="iommu=pt"
        info "检测到 AMD 平台: AMD IOMMU 默认开启, 追加 iommu=pt"
    else
        err "无法识别 CPU 厂商，已中止"
        return 1
    fi
    loader=$(detect_bootloader)
    info "检测到引导方式: $loader"
    if [ -e "$IOMMU_STATE" ]; then
        IFS='|' read -r state_loader state_target existing_added < "$IOMMU_STATE"
        if ! validate_iommu_state "$state_loader" "$state_target" "$existing_added" \
            || [ "$state_loader" != "$loader" ]; then
            err "现有 IOMMU 状态与当前引导方式不一致或已损坏，拒绝覆盖。"
            info "请先恢复/移除旧配置，或检查 $IOMMU_STATE"
            return 1
        fi
    fi
    if ! dmesg 2>/dev/null | grep -qE 'DMAR|IOMMU'; then
        warn "当前内核尚未显示 IOMMU；请先确认 BIOS 已开启 VT-d/AMD-Vi。"
    fi
    warn "本工具不会粗暴屏蔽 i915/amdgpu/声卡驱动，也不会按型号绑定所有同款设备。"
    info "重启后请在 PVE 虚拟机的『添加 -> PCI 设备』中选择具体设备。"
    confirm "写入内核参数和 vfio 模块配置?" || return 0

    begin_transaction boot
    add_iommu_kernel_params "$loader" "$params" || rc=1
    if [ "$rc" = "0" ]; then
        for token in $existing_added $IOMMU_ADDED_PARAMS; do
            case " $merged_added " in *" $token "*) ;; *) merged_added="${merged_added}${merged_added:+ }${token}" ;; esac
        done
        replace_file "$IOMMU_STATE" 0600 <<EOF || rc=1
${loader}|${IOMMU_TARGET_FILE}|${merged_added}
EOF
    fi
    if [ "$rc" = "0" ]; then
        replace_file /etc/modules-load.d/pve-toolkit-vfio.conf 0644 <<'EOF' || rc=1
# Managed by pve-toolkit
vfio
vfio_iommu_type1
vfio_pci
EOF
    fi
    [ "$rc" = "0" ] && refresh_boot_config "$loader" || rc=1
    [ "$rc" = "0" ] && update-initramfs -u || rc=1
    if [ "$rc" != "0" ]; then
        rollback_transaction
        refresh_boot_config "$loader" >/dev/null 2>&1 || true
        update-initramfs -u >/dev/null 2>&1 || true
        err "直通配置失败，已回滚"
        return 1
    fi
    commit_transaction
    ok "引导配置与 initramfs 已更新，请重启后再查看 IOMMU 分组。"
    log "passthrough enabled bootloader=$loader params=$params"
}

pt_disable(){
    clear_screen
    title "关闭硬件直通"
    local loader current_loader target added rc=0
    current_loader=$(detect_bootloader)
    confirm "移除 IOMMU 内核参数与本工具的 vfio 模块配置?" || return 0
    if [ ! -r "$IOMMU_STATE" ]; then
        err "没有本工具新增参数的状态记录；为避免删除用户原有 IOMMU 配置，已中止。"
        info "旧版脚本配置请使用『还原中心 -> 从备份回滚』或手动检查。"
        return 1
    fi
    IFS='|' read -r loader target added < "$IOMMU_STATE"
    [ -n "$target" ] || { err "IOMMU 状态文件损坏"; return 1; }
    case "$loader" in grub|systemd-boot) ;; *) err "IOMMU 状态中的引导方式非法"; return 1 ;; esac
    validate_iommu_state "$loader" "$target" "$added" \
        || { err "IOMMU 状态中的目标或参数非法"; return 1; }
    if [ "$loader" != "$current_loader" ]; then
        err "IOMMU 配置记录使用 $loader，当前检测为 $current_loader；拒绝修改旧引导目标。"
        info "请先确认实际引导器并手动处理，或恢复切换引导器前的状态。"
        return 1
    fi
    begin_transaction boot
    remove_iommu_kernel_params "$target" "$added" || rc=1
    if [ -e /etc/modules-load.d/pve-toolkit-vfio.conf ]; then
        restore_original /etc/modules-load.d/pve-toolkit-vfio.conf \
            || { grep -q 'Managed by pve-toolkit' /etc/modules-load.d/pve-toolkit-vfio.conf 2>/dev/null \
                && disable_file /etc/modules-load.d/pve-toolkit-vfio.conf; } || rc=1
    fi
    if [ -e "$IOMMU_STATE" ]; then restore_original "$IOMMU_STATE" || disable_file "$IOMMU_STATE" || rc=1; fi
    [ "$rc" = "0" ] && refresh_boot_config "$loader" || rc=1
    [ "$rc" = "0" ] && update-initramfs -u || rc=1
    if [ "$rc" != "0" ]; then
        rollback_transaction
        refresh_boot_config "$loader" >/dev/null 2>&1 || true
        update-initramfs -u >/dev/null 2>&1 || true
        err "关闭直通失败，已回滚"
        return 1
    fi
    commit_transaction
    if grep -qsE '^(vfio|vfio_iommu_type1|vfio_pci|vfio_virqfd)$' /etc/modules; then
        warn "检测到 /etc/modules 仍有旧配置；本工具未自动删除用户文件，可在『残留清理』中处理。"
    fi
    ok "直通引导配置已移除，请重启系统生效。"
    log "passthrough disabled bootloader=$loader"
}

passthrough_menu(){
    while :; do
        clear_screen
        cat <<MENUEOF

   ${C_Y}配置硬件直通${C_N}
   ------------------------------------------------
    1. 开启硬件直通
    2. 关闭硬件直通
    3. 查看直通状态
    0. 返回
   ------------------------------------------------
MENUEOF
        local c
        read -r -t 60 -p " 请选择 [默认0]: " c || return 0
        c=${c:-0}
        case "$c" in
            1) pt_enable; pause ;;
            2) pt_disable; pause ;;
            3) pt_status; pause ;;
            0) return 0 ;;
            *) ;;
        esac
    done
}

# =============================================================================
#  CPU 电源模式 (systemd 开机持久化, 取代脆弱的 cron @reboot)
# =============================================================================
GOVERNOR=""

set_governor_now(){
    local governor="$1" f failed=0
    for f in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do
        [ -w "$f" ] || continue
        printf '%s\n' "$governor" > "$f" || failed=1
    done
    [ "$failed" = "0" ]
}

capture_governors(){
    local output="$1" f
    : > "$output" || return 1
    for f in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do
        [ -r "$f" ] && printf '%s|%s\n' "$f" "$(cat "$f")" >> "$output"
    done
}

restore_governors_file(){
    local input="$1" f old failed=0
    [ -r "$input" ] || return 1
    while IFS='|' read -r f old; do
        if [ -w "$f" ] && [[ "$old" =~ ^[a-z0-9_-]+$ ]]; then
            printf '%s\n' "$old" > "$f" || failed=1
        fi
    done < "$input"
    [ "$failed" = "0" ]
}

governor_persisted_service_state(){
    local unit_file="$1" enable_state="$2" active="$3"
    if [ -e "$unit_file" ] && grep -qi 'pve-toolkit' "$unit_file" 2>/dev/null; then
        # 旧版/当前工具 unit 不是“首次接管前”的用户状态。
        printf 'not-found|0\n'
    else
        printf '%s|%s\n' "$enable_state" "$active"
    fi
}

gov_set(){
    local cur f rc=0 immediate state_content="" persisted_enable_state persisted_active persisted_pair
    immediate=$(mktemp) || return 1
    capture_governors "$immediate" || { rm -f "$immediate"; return 1; }
    GOV_IMMEDIATE_STATE="$immediate"
    GOV_SERVICE_WAS_ACTIVE=0
    GOV_SERVICE_ENABLE_STATE=$(unit_enable_state pve-governor.service)
    case "$GOV_SERVICE_ENABLE_STATE" in
        linked|linked-runtime|alias)
            rm -f "$immediate"; GOV_IMMEDIATE_STATE=""
            err "现有 pve-governor.service 为 ${GOV_SERVICE_ENABLE_STATE}，无法保证无损恢复，已中止。"
            return 1 ;;
    esac
    systemctl is-active pve-governor.service >/dev/null 2>&1 && GOV_SERVICE_WAS_ACTIVE=1
    begin_transaction governor
    mkdir -p "$STATE_ROOT"
    if [ ! -e "$GOV_STATE" ]; then
        persisted_pair=$(governor_persisted_service_state \
            /etc/systemd/system/pve-governor.service "$GOV_SERVICE_ENABLE_STATE" "$GOV_SERVICE_WAS_ACTIVE")
        IFS='|' read -r persisted_enable_state persisted_active <<< "$persisted_pair"
        state_content="# service_enable_state=${persisted_enable_state}"$'\n'
        state_content+="# service_active=${persisted_active}"$'\n'
        for f in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do
            [ -r "$f" ] && state_content+="${f}|$(cat "$f")"$'\n'
        done
        replace_file "$GOV_STATE" 0600 <<< "${state_content%$'\n'}" || rc=1
    fi
    if [ "$rc" = "0" ] && ! set_governor_now "$GOVERNOR"; then
        err "部分 CPU policy 无法切换到 ${GOVERNOR}"
        rc=1
    fi
    cur=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null)

    if [ "$rc" = "0" ]; then
        replace_file /etc/systemd/system/pve-governor.service 0644 <<UNIT || rc=1
[Unit]
Description=Set CPU governor to ${GOVERNOR} (${TOOLKIT})
After=systemd-modules-load.service
Before=pve-guests.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for f in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do [ ! -w "\$f" ] || printf "%s\\n" ${GOVERNOR} > "\$f"; done'

[Install]
WantedBy=multi-user.target
UNIT
    fi
    [ "$rc" = "0" ] && systemctl daemon-reload || rc=1
    [ "$rc" = "0" ] && systemctl enable --now pve-governor.service || rc=1
    if [ "$rc" != "0" ]; then
        systemctl disable --now pve-governor.service >/dev/null 2>&1 || true
        restore_governors_file "$immediate" || true
        rollback_transaction || err "CPU governor 文件或服务状态回滚不完整"
        rm -f "$immediate"; GOV_IMMEDIATE_STATE=""
        err "CPU governor 切换失败"
        return 1
    fi
    commit_transaction
    rm -f "$immediate"; GOV_IMMEDIATE_STATE=""
    ok "当前 CPU 模式: ${cur}; 开机自持服务已启用"
    log "governor set to ${GOVERNOR}"
}

gov_restore(){
    local restored=0 rc=0 immediate service_enable_state="disabled" service_was_active=0
    immediate=$(mktemp) || return 1
    capture_governors "$immediate" || { rm -f "$immediate"; return 1; }
    GOV_IMMEDIATE_STATE="$immediate"
    GOV_SERVICE_WAS_ACTIVE=0
    GOV_SERVICE_ENABLE_STATE=$(unit_enable_state pve-governor.service)
    case "$GOV_SERVICE_ENABLE_STATE" in
        linked|linked-runtime|alias)
            rm -f "$immediate"; GOV_IMMEDIATE_STATE=""
            err "现有 pve-governor.service 为 ${GOV_SERVICE_ENABLE_STATE}，无法保证无损恢复，已中止。"
            return 1 ;;
    esac
    systemctl is-active pve-governor.service >/dev/null 2>&1 && GOV_SERVICE_WAS_ACTIVE=1
    begin_transaction governor
    systemctl disable --now pve-governor.service >/dev/null 2>&1 || true
    if [ -e /etc/systemd/system/pve-governor.service ]; then
        restore_original /etc/systemd/system/pve-governor.service \
            || { grep -qi 'pve-toolkit' /etc/systemd/system/pve-governor.service 2>/dev/null \
                && disable_file /etc/systemd/system/pve-governor.service; } || rc=1
    fi
    [ "$rc" = "0" ] && systemctl daemon-reload || rc=1
    if [ -r "$GOV_STATE" ]; then
        service_enable_state=$(sed -n 's/^# service_enable_state=//p' "$GOV_STATE" | head -n1)
        if [ -z "$service_enable_state" ]; then
            if grep -q '^# service_enabled=1$' "$GOV_STATE"; then service_enable_state="enabled"; else service_enable_state="disabled"; fi
        fi
        service_was_active=$(sed -n 's/^# service_active=//p' "$GOV_STATE" | head -n1)
        [[ "$service_was_active" =~ ^[01]$ ]] || service_was_active=0
        restored=$(grep -c '^[^#].*|' "$GOV_STATE" || true)
        restore_governors_file "$GOV_STATE" || rc=1
        restore_original "$GOV_STATE" || disable_file "$GOV_STATE" || rc=1
        ok "已恢复 ${restored} 个 CPU policy 修改前的模式"
    else
        warn "没有修改前的 governor 快照；已移除自持服务，不强制猜测默认值。"
    fi
    if [ "$rc" = "0" ]; then
        restore_unit_enable_state pve-governor.service "$service_enable_state" || rc=1
        if [ "$rc" = "0" ] && [ "$service_was_active" = "1" ] \
            && [ -e /etc/systemd/system/pve-governor.service ]; then
            systemctl start pve-governor.service || rc=1
        else
            systemctl stop pve-governor.service >/dev/null 2>&1 || true
        fi
    fi
    if [ "$rc" != "0" ]; then
        rollback_transaction || err "CPU governor 文件或服务状态回滚不完整"
        restore_governors_file "$immediate" || true
        rm -f "$immediate"; GOV_IMMEDIATE_STATE=""
        err "CPU governor 恢复失败，已尽力回到操作前状态"
        return 1
    fi
    commit_transaction
    rm -f "$immediate"; GOV_IMMEDIATE_STATE=""
    log "governor persistence removed"
}

cpu_power_menu(){
    local governors
    governors=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_available_governors 2>/dev/null)
    [ -n "$governors" ] || { err "本机 CPU 无可切换的 governor (可能是 pstate 驱动限制或当前为虚拟机)"; pause; return 0; }
    while :; do
        clear_screen
        cat <<MENUEOF

   ${C_Y}设置 CPU 电源模式${C_N}
   ------------------------------------------------
    1. conservative (保守)     2. ondemand (按需)
    3. powersave (节能)        4. performance (性能)
    5. schedutil (负载)

    6. 恢复修改前的模式并移除自持服务
    0. 返回
   ------------------------------------------------
    部分新型 CPU 走 intel_pstate/amd-pstate 驱动, 仅 performance/powersave,
    属正常现象, 响应更智能。
    本机支持: ${governors}
MENUEOF
        local c
        read -r -t 60 -p " 请选择 [默认0]: " c || return 0
        c=${c:-0}
        case "$c" in
            1) GOVERNOR=conservative ;;
            2) GOVERNOR=ondemand ;;
            3) GOVERNOR=powersave ;;
            4) GOVERNOR=performance ;;
            5) GOVERNOR=schedutil ;;
            6) gov_restore; pause; return 0 ;;
            0) return 0 ;;
            *) continue ;;
        esac
        if echo " ${governors} " | grep -q " ${GOVERNOR} "; then
            gov_set
        else
            err "本机 CPU 不支持 ${GOVERNOR} 模式!"
        fi
        pause
    done
}

# =============================================================================
#  CPU / 硬盘信息显示 (核心功能)
# =============================================================================

# --- Perl 片段(静态部分): API 仅读取后台采集器的缓存 ---
build_perl_static(){
    cat <<PERLEOF
# ${TOOLKIT}
        my \$pve_toolkit_cache = '/run/pve-toolkit';
        for my \$field (qw(thermalstate cpusensors hdd_temperatures cpupower)) {
            my \$path = "\$pve_toolkit_cache/\$field";
            if (open(my \$fh, '<', \$path)) {
                local \$/;
                \$res->{\$field} = <\$fh> // '';
                close(\$fh);
            } else {
                \$res->{\$field} = '';
            }
        }
        for my \$path (glob("\$pve_toolkit_cache/nvme*_status")) {
            next if \$path !~ m{/nvme([0-9]+)_status\$};
            my \$field = "nvme\${1}_status";
            if (open(my \$fh, '<', \$path)) {
                local \$/;
                \$res->{\$field} = <\$fh> // '';
                close(\$fh);
            }
        }

PERLEOF
}

# NVMe 数据已由上面的缓存目录动态读取，保留函数以兼容旧调用。
build_perl_nvme(){
    :
}

# --- JS 片段(静态部分1): CPU功耗/频率/温度/核心频率 ---
build_js_part1(){
    cat <<'JSEOF'
/* pve-toolkit */
        {
              itemId: 'CPUW',
              colspan: 2,
              printBar: false,
              title: gettext('CPU功耗'),
              textField: 'cpupower',
              renderer:function(value){
                  const esc = (v) => Ext.String.htmlEncode(String(v ?? ''));
                  const w0 = value.split('\n')[0].split(' ')[0];
                  const w1 = value.split('\n')[1] ? value.split('\n')[1].split(' ')[0] : '';
                  return `CPU电源模式: <strong>${esc(w0)}</strong> | CPU功耗: <strong>${esc(w1)} W</strong> `
                }
        },

        {
              itemId: 'MHz',
              colspan: 2,
              printBar: false,
              title: gettext('CPU频率'),
              textField: 'cpusensors',
              renderer:function(value){
                  const f0 = value.match(/cpu MHz.*?([\d]+)/);
                  const f1 = value.match(/CPU min MHz.*?([\d]+)/);
                  const f2 = value.match(/CPU max MHz.*?([\d]+)/);
                  if (!f0 || !f1 || !f2) return 'CPU实时: 未知';
                  return `CPU实时: <strong>${f0[1]} MHz</strong> | 最小: ${f1[1]} MHz | 最大: ${f2[1]} MHz `
                }
        },

        {
              itemId: 'thermal',
              colspan: 2,
              printBar: false,
              title: gettext('CPU温度'),
              textField: 'thermalstate',
              renderer: function(value) {
                  const coreTemps = [];
                  let coreMatch;
                  const coreRegex = /(Core\s*\d+|Core\d+|Tdie|Tctl|Physical id\s*\d+).*?\+\s*([\d\.]+)/gi;

                  while ((coreMatch = coreRegex.exec(value)) !== null) {
                      let label = coreMatch[1];
                      let tempValue = coreMatch[2];

                      if (label.match(/Tdie|Tctl/i)) {
                          coreTemps.push(`CPU温度: <strong>${tempValue}℃</strong>`);
                      } else {
                          const coreNumberMatch = label.match(/\d+/);
                          const coreNum = coreNumberMatch ? parseInt(coreNumberMatch[0]) + 1 : 1;
                          coreTemps.push(`核心${coreNum}: <strong>${tempValue}℃</strong>`);
                      }
                  }

                  // 核显温度: Intel(GFX/Graphics) / AMD(junction/edge)
                  let igpuTemp = '';
                  const intelIgpuMatch = value.match(/(GFX|Graphics).*?\+\s*([\d\.]+)/i);
                  const amdIgpuMatch = value.match(/(junction|edge).*?\+\s*([\d\.]+)/i);
                  if (intelIgpuMatch) {
                      igpuTemp = `核显: ${intelIgpuMatch[2]}℃`;
                  } else if (amdIgpuMatch) {
                      igpuTemp = `核显: ${amdIgpuMatch[2]}℃`;
                  }

                  // AMD k10temp 兜底
                  if (coreTemps.length === 0) {
                      const k10tempMatch = value.match(/k10temp-pci-\w+\n[^+]*\+\s*([\d\.]+)/);
                      if (k10tempMatch) {
                          coreTemps.push(`CPU温度: <strong>${k10tempMatch[1]}℃</strong>`);
                      }
                  }

                  // 4 个核心一行
                  const groupedTemps = [];
                  for (let i = 0; i < coreTemps.length; i += 4) {
                      groupedTemps.push(coreTemps.slice(i, i + 4).join(' | '));
                  }

                  const packageMatch = value.match(/(Package|SoC)\s*(id \d+)?.*?\+\s*([\d\.]+)/i);
                  const packageTemp = packageMatch ? `CPU Package: <strong>${packageMatch[3]}℃</strong>` : '';

                  const boardTempMatch = value.match(/(?:temp1|motherboard|sys).*?\+\s*([\d\.]+)/i);
                  const boardTemp = boardTempMatch ? `主板: <strong>${boardTempMatch[1]}℃</strong>` : '';

                  const combinedTemps = [igpuTemp, packageTemp, boardTemp].filter(Boolean).join(' | ');
                  const result = [groupedTemps.join('<br>'), combinedTemps].filter(Boolean).join('<br>');
                  return result || '未获取到温度信息';
              }
        },

        {
              itemId: 'HEXIN',
              colspan: 2,
              printBar: false,
              title: gettext('核心频率'),
              textField: 'cpusensors',
              renderer: function(value) {
                  const freqMatches = value.matchAll(/^cpu MHz\s*:\s*([\d\.]+)/gm);
                  const frequencies = [];
                  for (const match of freqMatches) {
                      const coreNum = frequencies.length + 1;
                      frequencies.push(`核心${coreNum}: <strong>${parseInt(match[1])} MHz</strong>`);
                  }
                  if (frequencies.length === 0) {
                      return '无法获取CPU频率信息';
                  }
                  const groupedFreqs = [];
                  for (let i = 0; i < frequencies.length; i += 4) {
                      groupedFreqs.push(frequencies.slice(i, i + 4).join(' | '));
                  }
                  return groupedFreqs.join('<br>');
               }
        },

        /* 检测不到风扇参数的机器可整体注释掉
        {
              itemId: 'RPM',
              colspan: 2,
              printBar: false,
              title: gettext('风扇转速'),
              textField: 'thermalstate',
              renderer:function(value){
                  const fan1 = value.match(/fan1:.*?\ ([\d.]+) R/);
                  const fan2 = value.match(/fan2:.*?\ ([\d.]+) R/);
                  if (!fan1 && !fan2) return '未检测到风扇传感器';
                  const fmt = (m) => m ? (m[1] === "0" ? "停转" : m[1] + " RPM") : "无";
                  return `CPU风扇: ${fmt(fan1)} | 系统风扇: ${fmt(fan2)}`
                }
        },
        */

JSEOF
}

# --- JS 片段(NVMe 模板): @NV@=nvme 序号 ---
build_js_nvme(){
    cat <<'NVJSEOF'
        {
            itemId: 'nvme@NV@-status',
            colspan: 2,
            printBar: false,
            title: gettext('NVME盘 @NV@'),
            textField: 'nvme@NV@_status',
            renderer:function(value){
                if (value && value.length > 0) {
                    const esc = (v) => Ext.String.htmlEncode(String(v ?? ''));
                    value = value.replace(/Â/g, '');
                    let data = [];
                    let nvmeNumber = -1;
                    const emptyNvme = () => ({
                        Models: [], Integrity_Errors: [], Capacitys: [], Temperatures: [],
                        Available_Spares: [], Useds: [], Reads: [], Writtens: [],
                        Cycles: [], Hours: [], Shutdowns: [], States: [],
                        r_kBs: [], r_awaits: [], w_kBs: [], w_awaits: [], utils: []
                    });
                    let nvmes = value.matchAll(/(^(?:Model|Total|Temperature:|Available Spare:|Percentage|Data|Power|Unsafe|Integrity Errors|nvme)[\s\S]*)+/gm);
                    for (const nvme of nvmes) {
                        if (/Model Number:/.test(nvme[1])) {
                            nvmeNumber++;
                            data[nvmeNumber] = emptyNvme();
                        }
                        if (nvmeNumber < 0) { nvmeNumber = 0; data[nvmeNumber] = emptyNvme(); }
                        let Models = nvme[1].matchAll(/^Model Number: *([ \S]*)$/gm);
                        for (const Model of Models) { data[nvmeNumber]['Models'].push(Model[1]); }
                        let Integrity_Errors = nvme[1].matchAll(/^Media and Data Integrity Errors: *([ \S]*)$/gm);
                        for (const Integrity_Error of Integrity_Errors) { data[nvmeNumber]['Integrity_Errors'].push(Integrity_Error[1]); }
                        let Capacitys = nvme[1].matchAll(/^(?=Total|Namespace)[^:]+Capacity:[^\[]*\[([ \S]*)\]$/gm);
                        for (const Capacity of Capacitys) { data[nvmeNumber]['Capacitys'].push(Capacity[1]); }
                        let Temperatures = nvme[1].matchAll(/^Temperature: *([\d]*)[ \S]*$/gm);
                        for (const Temperature of Temperatures) { data[nvmeNumber]['Temperatures'].push(Temperature[1]); }
                        let Available_Spares = nvme[1].matchAll(/^Available Spare: *([\d]*%)[ \S]*$/gm);
                        for (const Available_Spare of Available_Spares) { data[nvmeNumber]['Available_Spares'].push(Available_Spare[1]); }
                        let Useds = nvme[1].matchAll(/^Percentage Used: *([ \S]*)%$/gm);
                        for (const Used of Useds) { data[nvmeNumber]['Useds'].push(Used[1]); }
                        let Reads = nvme[1].matchAll(/^Data Units Read:[^\[]*\[([ \S]*)\]$/gm);
                        for (const Read of Reads) { data[nvmeNumber]['Reads'].push(Read[1]); }
                        let Writtens = nvme[1].matchAll(/^Data Units Written:[^\[]*\[([ \S]*)\]$/gm);
                        for (const Written of Writtens) { data[nvmeNumber]['Writtens'].push(Written[1]); }
                        let Cycles = nvme[1].matchAll(/^Power Cycles: *([ \S]*)$/gm);
                        for (const Cycle of Cycles) { data[nvmeNumber]['Cycles'].push(Cycle[1]); }
                        let Hours = nvme[1].matchAll(/^Power On Hours: *([ \S]*)$/gm);
                        for (const Hour of Hours) { data[nvmeNumber]['Hours'].push(Hour[1]); }
                        let Shutdowns = nvme[1].matchAll(/^Unsafe Shutdowns: *([ \S]*)$/gm);
                        for (const Shutdown of Shutdowns) { data[nvmeNumber]['Shutdowns'].push(Shutdown[1]); }
                        let States = nvme[1].matchAll(/^nvme\S+(( *\d+\.\d{2}){22})/gm);
                        for (const State of States) {
                            data[nvmeNumber]['States'].push(State[1]);
                            const IO_array = [...State[1].matchAll(/\d+\.\d{2}/g)];
                            if (IO_array.length > 0) {
                                data[nvmeNumber]['r_kBs'].push(IO_array[1]);
                                data[nvmeNumber]['r_awaits'].push(IO_array[4]);
                                data[nvmeNumber]['w_kBs'].push(IO_array[7]);
                                data[nvmeNumber]['w_awaits'].push(IO_array[10]);
                                data[nvmeNumber]['utils'].push(IO_array[21]);
                            }
                        }
                    }
                    let output = '';
                    for (const [idx, nv] of data.entries()) {
                        if (idx > 0) output += '<br><br>';
                        if (nv.Models.length > 0) {
                            output += `<strong>${esc(nv.Models[0])}</strong>`;
                            if (nv.Integrity_Errors.length > 0) {
                                for (const ie of nv.Integrity_Errors) {
                                    if (ie != 0) {
                                        output += `(`;
                                        output += `0E: ${esc(ie)}-故障！`;
                                        if (nv.Available_Spares.length > 0) {
                                            output += ', ';
                                            for (const as of nv.Available_Spares) { output += `备用空间: ${esc(as)}`; }
                                        }
                                        output += `)`;
                                    }
                                }
                            }
                            output += '<br>';
                        }
                        if (nv.Capacitys.length > 0) {
                            for (const cap of nv.Capacitys) { output += `容量: ${esc(cap.replace(/ |,/gm, ''))}`; }
                        }
                        if (nv.Useds.length > 0) {
                            output += ' | ';
                            for (const used of nv.Useds) {
                                output += `寿命: <strong>${esc(100-Number(used))}%</strong>`;
                                if (nv.Reads.length > 0) {
                                    output += '(';
                                    for (const rd of nv.Reads) { output += `已读${esc(rd.replace(/ |,/gm, ''))}`; output += ')'; }
                                }
                                if (nv.Writtens.length > 0) {
                                    output = output.slice(0, -1);
                                    output += ', ';
                                    for (const wr of nv.Writtens) { output += `已写${esc(wr.replace(/ |,/gm, ''))}`; }
                                    output += ')';
                                }
                            }
                        }
                        if (nv.Temperatures.length > 0) {
                            output += ' | ';
                            for (const tp of nv.Temperatures) { output += `温度: <strong>${esc(tp)}°C</strong>`; }
                        }
                        if (nv.States.length > 0) {
                            if (nv.Models.length > 0) { output += '\n'; }
                            output += 'I/O: ';
                            if (nv.r_kBs.length > 0 || nv.r_awaits.length > 0) {
                                output += '读-';
                                for (const rk of nv.r_kBs) {
                                    let rmb = (Number(rk) / 1024).toFixed(2);
                                    output += `速度${rmb}MB/s`;
                                }
                                for (const ra of nv.r_awaits) { output += `, 延迟${ra}ms /`; }
                            }
                            if (nv.w_kBs.length > 0 || nv.w_awaits.length > 0) {
                                output += '写-';
                                for (const wk of nv.w_kBs) {
                                    let wmb = (Number(wk) / 1024).toFixed(2);
                                    output += `速度${wmb}MB/s`;
                                }
                                for (const wa of nv.w_awaits) { output += `, 延迟${wa}ms |`; }
                            }
                            for (const ut of nv.utils) { output += `负载${ut}%`; }
                        }
                        if (nv.Cycles.length > 0) {
                            output += '\n';
                            for (const cy of nv.Cycles) { output += `通电: ${esc(cy.replace(/ |,/gm, ''))}次`; }
                            if (nv.Shutdowns.length > 0) {
                                output += ', ';
                                for (const sd of nv.Shutdowns) { output += `不安全断电${esc(sd.replace(/ |,/gm, ''))}次`; break; }
                            }
                            if (nv.Hours.length > 0) {
                                output += ', ';
                                for (const hr of nv.Hours) { output += `累计${esc(hr.replace(/ |,/gm, ''))}小时`; }
                            }
                        }
                    }
                    return output.replace(/\n/g, '<br>');
                } else {
                    return `提示: 未安装 NVME 或 NVME 已直通虚拟机！`;
                }
            }
        },

NVJSEOF
}

# --- JS 片段(静态部分2): SATA 硬盘逐盘解析 ---
build_js_part2(){
    cat <<'JS2EOF'
        {
            itemId: 'hdd-temperatures',
            colspan: 2,
            printBar: false,
            title: gettext('SATA盘'),
            textField: 'hdd_temperatures',
            renderer: function(value) {
                const esc = (v) => Ext.String.htmlEncode(String(v ?? ''));
                if (!value || value.length === 0) {
                    return '提示: 未安装硬盘或硬盘控制器已直通';
                }
                var diskBlocks = value.split(/===(?=\/dev\/sd)/g);
                var outputs = [];
                for (var i = 0; i < diskBlocks.length; i++) {
                    var blockText = diskBlocks[i].trim();
                    if (!blockText) continue;
                    var devMatch = blockText.match(/^\/dev\/(sd[a-z]+)===/);
                    var devName = devMatch ? devMatch[1] : 'unknown';
                    var model = '', capacity = '', hours = '', temp = '';
                    var lines = blockText.split('\n');
                    for (var j = 0; j < lines.length; j++) {
                        var line = lines[j];
                        if (/Device Model:|Model Family:/i.test(line)) {
                            model = line.split(':')[1] ? line.split(':')[1].trim() : model;
                        } else if (/User Capacity:/i.test(line)) {
                            var capMatch = line.match(/\[([^\]]+)\]/);
                            capacity = capMatch ? capMatch[1] : (line.split(':')[1] || '').trim();
                        } else if (/Power_On_Hours/i.test(line)) {
                            var hoursMatch = line.match(/\s-\s+(\d+)/);
                            if (hoursMatch) hours = hoursMatch[1];
                        } else if (/Temperature/i.test(line)) {
                            var tempMatch = line.match(/^\s*(194|190)\s+.*?\s-\s+(\d+)/);
                            if (tempMatch && (tempMatch[1] === '194' || !temp)) {
                                temp = tempMatch[2];
                            }
                        }
                    }
                    if (!model) model = "未知型号 SATA 盘 (" + devName + ")";
                    var info = "<strong>[" + esc(devName.toUpperCase()) + "] " + esc(model) + "</strong><br>";
                    info += "容量: " + esc(capacity || '未知');
                    if (hours) info += " | 已通电: " + hours + "小时";
                    if (temp) info += " | 温度: <strong>" + temp + "°C</strong>";
                    else info += " | 温度: 未能获取";
                    outputs.push(info);
                }
                return outputs.length ? outputs.join('<br><br>') : '提示: 未能识别到有效SATA硬盘数据';
            }
        },

JS2EOF
}

# --- 安装依赖并探测传感器驱动 ---
remove_unsafe_setuid(){
    local b changed=0
    for b in /usr/sbin/nvme /usr/bin/nvme /usr/sbin/smartctl /usr/bin/smartctl \
             /usr/sbin/turbostat /usr/bin/turbostat /usr/sbin/linux-cpupower /usr/bin/cpupower; do
        [ -e "$b" ] || continue
        if [ -u "$b" ]; then
            chmod u-s "$b" || return 1
            warn "已撤销旧版脚本留下的高危 SUID 权限: $b"
            changed=1
        fi
    done
    [ "$changed" = "0" ] || log "removed unsafe setuid bits from hardware tools"
}

install_hw_collector(){
    replace_file "$HW_COLLECTOR" 0755 <<'COLLECTOR' || return 1
#!/usr/bin/env bash
set -o pipefail
export LC_ALL=C
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

run_dir=/run/pve-toolkit
mkdir -p "$run_dir"
chmod 0755 "$run_dir"

write_cache(){
    local name="$1" tmp
    tmp=$(mktemp "$run_dir/.${name}.XXXXXX") || return 1
    cat > "$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$run_dir/$name"
}

if command -v sensors >/dev/null 2>&1; then
    timeout 4 sensors 2>/dev/null | write_cache thermalstate
else
    : | write_cache thermalstate
fi

{
    grep 'cpu MHz' /proc/cpuinfo 2>/dev/null || true
    lscpu 2>/dev/null | grep 'MHz' || true
} | write_cache cpusensors

{
    for sysdisk in /sys/block/sd*; do
        [ -e "$sysdisk" ] || continue
        disk="/dev/${sysdisk##*/}"
        [ -b "$disk" ] || continue
        echo "===$disk==="
        timeout 5 smartctl -n standby -a "$disk" 2>/dev/null || true
    done
} | grep -E '===|Device Model|Model Family|User Capacity|Power_On_Hours|Temperature' \
  | write_cache hdd_temperatures

{
    cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null || true
    if command -v turbostat >/dev/null 2>&1; then
        timeout 3 turbostat -S -q -s PkgWatt -i 0.1 -n 1 -c package 2>/dev/null \
            | grep -v PkgWatt || true
    fi
} | write_cache cpupower

io_tmp=$(mktemp "$run_dir/.iostat.XXXXXX") || exit 1
trap 'rm -f "$io_tmp"' EXIT
if command -v iostat >/dev/null 2>&1; then
    timeout 4 iostat -d -x -k 1 1 > "$io_tmp" 2>/dev/null || true
fi
for old in "$run_dir"/nvme*_status; do [ ! -f "$old" ] || rm -f "$old"; done
for dev in /dev/nvme*; do
    [ -e "$dev" ] || continue
    base=${dev##*/}
    [[ "$base" =~ ^nvme([0-9]+)$ ]] || continue
    idx=${BASH_REMATCH[1]}
    {
        timeout 5 smartctl -a "$dev" 2>/dev/null \
            | grep -E '^(Model Number|Total NVM Capacity|Namespace [0-9]+ (Size|Capacity)|Temperature:|Available Spare:|Percentage Used:|Data Units|Power Cycles:|Power On Hours:|Unsafe Shutdowns:|Media and Data Integrity Errors:)' || true
        grep -E "^${base}n[0-9]+" "$io_tmp" || true
    } | write_cache "nvme${idx}_status"
done
COLLECTOR

    replace_file "$HW_SERVICE" 0644 <<SERVICE
[Unit]
Description=PVE Toolkit hardware telemetry collector
After=local-fs.target

[Service]
Type=oneshot
ExecStartPre=-/sbin/modprobe msr
ExecStart=${HW_COLLECTOR}
RuntimeDirectory=pve-toolkit
RuntimeDirectoryMode=0755
RuntimeDirectoryPreserve=yes
Nice=10
IOSchedulingClass=idle
TimeoutStartSec=300
NoNewPrivileges=yes
ProtectHome=yes
PrivateTmp=yes
SERVICE
    [ "$?" = "0" ] || return 1

    replace_file "$HW_TIMER" 0644 <<'TIMER'
[Unit]
Description=Refresh PVE Toolkit hardware telemetry

[Timer]
OnBootSec=10s
OnUnitActiveSec=30s
RandomizedDelaySec=3s
AccuracySec=5s
Unit=pve-toolkit-hw.service

[Install]
WantedBy=timers.target
TIMER
    [ "$?" = "0" ] || return 1

    systemctl daemon-reload || return 1
    systemctl enable --now pve-toolkit-hw.timer || return 1
    if ! systemctl start pve-toolkit-hw.service; then
        err "硬件信息采集失败，请查看: journalctl -u pve-toolkit-hw.service"
        return 1
    fi
    ok "硬件信息已改为 30 秒后台缓存，不再阻塞 PVE API"
}

display_install_deps(){
    info "检查硬件信息依赖..."
    local packages=(lm-sensors nvme-cli sysstat linux-cpupower smartmontools nodejs)
    local missing=() p
    for p in "${packages[@]}"; do
        dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        info "将安装: ${missing[*]}"
        apt_update_strict || return 1
        apt-get install -y "${missing[@]}" || return 1
    fi
    ok "依赖就绪"
    remove_unsafe_setuid || return 1
    if [ "$(uname -m)" = "x86_64" ]; then
        grep -q GenuineIntel /proc/cpuinfo && modprobe coretemp 2>/dev/null || true
        grep -q AuthenticAMD /proc/cpuinfo && modprobe k10temp 2>/dev/null || true
    fi
    sensors >/dev/null 2>&1 || warn "未读到传感器；可手动执行 sensors-detect 后重试"
}

display_apply(){
    clear_screen
    title "添加 CPU/硬盘 信息显示"
    local reapply=0 package_rc=0 snippet node_tmp js_tmp ln devc base idx rc=0
    [ -e "$NODES_PM" ] && [ -e "$PVE_MANAGER_JS" ] || {
        err "未找到 Nodes.pm / pvemanagerlib.js, 请确认 PVE 已完整安装"; return 1; }

    if grep -q "$TOOLKIT" "$NODES_PM" || grep -q "$TOOLKIT" "$PVE_MANAGER_JS"; then
        reapply=1
        warn "检测到已添加过信息显示，将在同一事务中还原基线并重新应用。"
    fi

    info "计划：安装缺失依赖、创建 30 秒采集计时器、修改两个 PVE 包文件并重启 Web/API 服务。"
    [ "$reapply" = "0" ] || info "若重装任一步失败，现有面板文件和计时器状态会一起回滚。"
    confirm "确认执行完整计划?" || return 0
    display_install_deps || return 1

    DISPLAY_TIMER_WAS_ACTIVE=0
    DISPLAY_TIMER_ENABLE_STATE=$(unit_enable_state pve-toolkit-hw.timer)
    case "$DISPLAY_TIMER_ENABLE_STATE" in
        linked|linked-runtime|alias)
            err "现有 pve-toolkit-hw.timer 为 ${DISPLAY_TIMER_ENABLE_STATE}，无法保证无损恢复，已中止。"
            return 1 ;;
    esac
    systemctl is-active pve-toolkit-hw.timer >/dev/null 2>&1 && DISPLAY_TIMER_WAS_ACTIVE=1
    begin_transaction display_apply
    if [ "$reapply" = "1" ]; then
        restore_original "$NODES_PM" || package_rc=1
        restore_original "$PVE_MANAGER_JS" || package_rc=1
        if [ "$package_rc" != "0" ]; then
            err "缺少可信的面板原始快照，无法保证原子重新应用。"
            info "请先使用『还原中心 -> 官方包重装』建立干净基线，再回来添加面板。"
            rc=1
        fi
    fi
    [ "$rc" != "0" ] || install_hw_collector || rc=1

    # 在临时副本上生成和校验，通过后才原子替换真实文件。
    if [ "$rc" = "0" ]; then
        snippet=$(mktemp) && node_tmp=$(mktemp "${NODES_PM}.pve-toolkit.XXXXXX") || rc=1
    fi
    if [ "$rc" = "0" ]; then
        build_perl_static > "$snippet"
        cp -a "$NODES_PM" "$node_tmp"
        ln=$(sed -n -e '/PVE::pvecfg::version_text/=' "$node_tmp" | head -n1)
        if [ -z "$ln" ]; then
            err "Nodes.pm 插入点定位失败"
            rc=1
        else
            ln=$((ln + 1))
            sed -i "${ln}r ${snippet}" "$node_tmp"
            perl -c "$node_tmp" >/dev/null 2>&1 || { err "Nodes.pm 语法校验失败"; rc=1; }
        fi
    fi

    if [ "$rc" = "0" ]; then
        : > "$snippet"
        build_js_part1 >> "$snippet"
        for devc in /dev/nvme*; do
            [ -e "$devc" ] || continue
            base=$(basename "$devc")
            [[ "$base" =~ ^nvme([0-9]+)$ ]] || continue
            idx=${BASH_REMATCH[1]}
            info "添加 NVMe 面板: $devc"
            build_js_nvme | sed "s/@NV@/${idx}/g" >> "$snippet"
        done
        build_js_part2 >> "$snippet"
        js_tmp=$(mktemp "${PVE_MANAGER_JS}.pve-toolkit.XXXXXX") || rc=1
    fi
    if [ "$rc" = "0" ]; then
        cp -a "$PVE_MANAGER_JS" "$js_tmp"
        ln=$(sed -n '/pveversion/,+10{/},/{=;q}}' "$js_tmp" | head -n1)
        if [ -z "$ln" ]; then
            err "pvemanagerlib.js 插入点定位失败"
            rc=1
        else
            sed -i "${ln}r ${snippet}" "$js_tmp"
            sed -i -r '/widget\.pveNodeStatus/,+5{s/^([[:space:]]*)height:[[:space:]]*[0-9]+,/\1minHeight: 350,/}' "$js_tmp"
            if ! command -v node >/dev/null 2>&1; then
                err "缺少 node JavaScript 解析器，拒绝安装未校验的前端代码"
                rc=1
            elif ! node --check "$js_tmp" >/dev/null 2>&1; then
                err "pvemanagerlib.js JavaScript 语法校验失败"
                rc=1
            fi
        fi
    fi

    if [ "$rc" = "0" ]; then
        backup_file "$NODES_PM" || rc=1
    fi
    if [ "$rc" = "0" ]; then
        chmod --reference="$NODES_PM" "$node_tmp" 2>/dev/null || true
        chown --reference="$NODES_PM" "$node_tmp" 2>/dev/null || true
        atomic_replace_path "$node_tmp" "$NODES_PM" || rc=1
    fi
    if [ "$rc" = "0" ]; then
        backup_file "$PVE_MANAGER_JS" || rc=1
    fi
    if [ "$rc" = "0" ]; then
        chmod --reference="$PVE_MANAGER_JS" "$js_tmp" 2>/dev/null || true
        chown --reference="$PVE_MANAGER_JS" "$js_tmp" 2>/dev/null || true
        atomic_replace_path "$js_tmp" "$PVE_MANAGER_JS" || rc=1
    fi
    [ -z "${snippet:-}" ] || rm -f "$snippet"
    [ -z "${node_tmp:-}" ] || rm -f "$node_tmp"
    [ -z "${js_tmp:-}" ] || rm -f "$js_tmp"

    if [ "$rc" = "0" ] && systemctl restart pveproxy pvedaemon; then
        commit_transaction
        ok "全部完成！刷新浏览器 (Ctrl+Shift+R) 即可看到效果"
        log "display mod applied with cached collector"
    else
        err "信息面板安装失败，正在回滚"
        if rollback_transaction; then
            warn "文件变更已回滚；已安装的 Debian 依赖包予以保留。"
        else
            err "自动回滚不完整，请立即使用『还原中心 -> 官方包重装』"
        fi
        return 1
    fi
    return 0
}

display_remove(){
    local quiet="${1:-}" had=0 rc=0 package_rc=0 cleanup_rc=0 f
    if grep -q "$TOOLKIT" "$NODES_PM" 2>/dev/null || grep -q "$TOOLKIT" "$PVE_MANAGER_JS" 2>/dev/null; then
        had=1
    fi
    [ -e "$HW_TIMER" ] || [ -e "$HW_SERVICE" ] || [ -e "$HW_COLLECTOR" ] && had=1
    if ! remove_unsafe_setuid; then
        err "旧版高危 SUID 清理失败，未继续移除面板"
        return 1
    fi
    if [ "$had" = "0" ]; then
        [ "$quiet" = "quiet" ] || ok "未添加过信息显示, 无需移除"
        return 0
    fi
    if [ "$quiet" != "quiet" ]; then
        info "将恢复面板修改前的两个 PVE 文件、移除后台采集器并重启 Web/API 服务。"
        confirm "确认移除硬件信息面板?" || return 0
    fi
    DISPLAY_TIMER_WAS_ACTIVE=0
    DISPLAY_TIMER_ENABLE_STATE=$(unit_enable_state pve-toolkit-hw.timer)
    case "$DISPLAY_TIMER_ENABLE_STATE" in
        linked|linked-runtime|alias)
            err "现有 pve-toolkit-hw.timer 为 ${DISPLAY_TIMER_ENABLE_STATE}，无法保证无损恢复，已中止。"
            return 1 ;;
    esac
    systemctl is-active pve-toolkit-hw.timer >/dev/null 2>&1 && DISPLAY_TIMER_WAS_ACTIVE=1
    begin_transaction display_remove
    systemctl disable --now pve-toolkit-hw.timer >/dev/null 2>&1 || true
    if grep -q "$TOOLKIT" "$NODES_PM" 2>/dev/null; then restore_original "$NODES_PM" || package_rc=1; fi
    if grep -q "$TOOLKIT" "$PVE_MANAGER_JS" 2>/dev/null; then restore_original "$PVE_MANAGER_JS" || package_rc=1; fi
    if [ "$package_rc" != "0" ]; then
        err "面板包文件缺少可信原始快照，无法只还原面板相关改动。"
        info "请使用『还原中心 -> 官方包重装』；该操作会明确还原对应软件包的全部文件。"
        rc=1
    fi
    for f in "$HW_TIMER" "$HW_SERVICE" "$HW_COLLECTOR"; do
        [ -e "$f" ] || continue
        restore_original "$f" \
            || { grep -qi 'pve-toolkit' "$f" 2>/dev/null && disable_file "$f"; } \
            || cleanup_rc=1
    done
    [ "$cleanup_rc" = "0" ] || rc=1
    if [ "$rc" = "0" ]; then
        systemctl daemon-reload || rc=1
        [ "$rc" != "0" ] || systemctl restart pveproxy pvedaemon || rc=1
    fi
    if [ "$rc" != "0" ]; then
        err "信息面板移除失败，正在恢复操作前状态"
        rollback_transaction || err "自动回滚不完整，请检查 $MANIFEST"
        return 1
    fi
    commit_transaction
    ok "已还原信息显示相关文件并移除后台采集器"
    log "display mod removed"
    return 0
}

# =============================================================================
#  Ceph 管理
# =============================================================================
ceph_menu(){
    clear_screen
    title "Ceph 管理"
    local act rc=0 ceph_release=""
    cat <<'EOF'
 1. 配置 Ceph no-subscription 源
 2. 查看 Ceph 状态/退役前检查（只读）
 3. 仅移除 Ceph 软件源（不删数据/配置/包）
 0. 返回
EOF
    read -r -t 60 -p " 请选择: " act || return 0
    case "$act" in
        1)
            choose_mirror || return 0
            ceph_release=$(ceph_codename) || return 1
            warn_ceph_cluster_scope
            info "检测到的 Ceph 大版本: $ceph_release"
            confirm "按上述版本配置软件源并立即验证?" || return 0
            begin_transaction sources
            ensure_pve_keyring && write_ceph_repo nosub "$MIR_CEPH_ROOT" || rc=1
            if [ "$rc" = "0" ] && apt_update_strict && verify_single_pve_repo; then
                commit_transaction
                ok "Ceph 源已配置并验证"
            else
                rollback_transaction
                err "Ceph 源配置失败，已回滚"
                return 1
            fi
            ;;
        2)
            title "Ceph 只读检查"
            if command -v ceph >/dev/null 2>&1; then
                ceph -s || warn "ceph -s 返回非零，请先修复集群"
                echo
                ceph versions 2>/dev/null || true
            else
                info "本节点未安装 ceph 命令"
            fi
            echo
            info "PVE 中的 Ceph/RBD/CephFS 存储引用:"
            pvesm status 2>/dev/null | awk 'NR == 1 || $2 ~ /^(rbd|cephfs)$/' | sed 's/^/    /'
            warn "已移除危险的『一键卸载』。Ceph 退役必须按官方流程逐 OSD/逐节点执行，不应在单节点删除 /etc/pve 集群配置。"
            ;;
        3)
            warn_ceph_cluster_scope
            confirm "仅移除 ceph.list/ceph.sources；Ceph 数据、配置和已安装包都保留。继续?" || return 0
            begin_transaction sources
            disable_file /etc/apt/sources.list.d/ceph.sources || rc=1
            disable_file /etc/apt/sources.list.d/ceph.list || rc=1
            if [ "$rc" = "0" ] && apt_update_strict && verify_single_pve_repo; then
                commit_transaction
                ok "Ceph 软件源已移除，未删除任何 Ceph 数据"
            else
                rollback_transaction
                return 1
            fi
            ;;
        0|"") return 0 ;;
        *) warn "无效选择: $act"; return 1 ;;
    esac
    return 0
}

# =============================================================================
#  旧内核清理
# =============================================================================
remove_old_kernels(){
    clear_screen
    title "清理旧内核"
    warn "只会列出拥有 /boot/vmlinuz-* 的真实内核包，并强制保留当前内核、pin 内核和最新两个备用内核。"
    local current pkg status image version line selected idx k pinned
    local -a entries=() sorted=() candidates=() kernels=() idxlist=()
    local -A protected=() seen=()
    current=$(uname -r)

    while IFS='|' read -r pkg status; do
        [ "$status" = "ii " ] || continue
        image=$(dpkg-query -L "$pkg" 2>/dev/null | grep -E '^/boot/vmlinuz-' | head -n1)
        [ -n "$image" ] || continue # 排除 proxmox-kernel-X.Y 系列 meta 包
        version=${image#/boot/vmlinuz-}
        entries+=("${version}|${pkg}")
    done < <(dpkg-query -W -f='${binary:Package}|${db:Status-Abbrev}\n' \
        'pve-kernel-[0-9]*' 'proxmox-kernel-[0-9]*' 2>/dev/null || true)

    if [ ${#entries[@]} -eq 0 ]; then
        warn "未从 dpkg 找到可识别的 PVE 内核镜像包"
        pause
        return 0
    fi

    mapfile -t sorted < <(printf '%s\n' "${entries[@]}" | sort -t'|' -k1,1V)
    protected["$current"]=1
    for pinned in /etc/kernel/proxmox-boot-pin /etc/kernel/next-boot-pin \
                  /etc/kernel/proxmox-boot-manual-kernels /etc/kernel/pve-efiboot-manual-kernels; do
        [ -r "$pinned" ] || continue
        while IFS= read -r version; do
            version=${version%%[[:space:]]*}
            [ -n "$version" ] && protected["$version"]=1
        done < "$pinned"
    done
    # Proxmox 自身会选中当前/上一内核系列的 fallback；直接保护工具列出的全部版本。
    if command -v proxmox-boot-tool >/dev/null 2>&1; then
        while IFS= read -r version; do
            [ -n "$version" ] && protected["$version"]=1
        done < <(proxmox-boot-tool kernel list 2>/dev/null \
            | sed -nE 's/^[[:space:]]*([0-9][0-9A-Za-z.+~-]*-pve)[[:space:]]*$/\1/p')
    fi

    # 从新到旧再保留两个非当前的备用内核。
    local keep=0 i
    for ((i=${#sorted[@]} - 1; i >= 0 && keep < 2; i--)); do
        version=${sorted[$i]%%|*}
        [ "$version" = "$current" ] && continue
        protected["$version"]=1
        keep=$((keep + 1))
    done
    for line in "${sorted[@]}"; do
        version=${line%%|*}; pkg=${line#*|}
        [ -n "${protected[$version]:-}" ] || candidates+=("$version|$pkg")
    done

    if [ ${#candidates[@]} -eq 0 ]; then
        ok "没有满足安全保留策略的可清理内核 (当前: ${current})"
        pause
        return 0
    fi
    info "当前运行内核: ${current}"
    info "可清理的旧内核:"
    for i in "${!candidates[@]}"; do
        version=${candidates[$i]%%|*}; pkg=${candidates[$i]#*|}
        printf '    %2d. %-28s %s\n' "$((i + 1))" "$version" "$pkg"
    done
    read -r -p " 输入要删除的序号(逗号分隔, 如 1,2; 直接回车取消): " selected
    [ -n "$selected" ] || { info "已取消"; pause; return 0; }

    IFS=',' read -r -a idxlist <<< "$selected"
    for idx in "${idxlist[@]}"; do
        idx=${idx//[[:space:]]/}
        [[ "$idx" =~ ^[0-9]+$ ]] || { warn "无效序号: $idx"; continue; }
        [ "$idx" -ge 1 ] && [ "$idx" -le ${#candidates[@]} ] || { warn "超出范围: $idx"; continue; }
        k=${candidates[$((idx - 1))]#*|}
        [ -n "${seen[$k]:-}" ] || { kernels+=("$k"); seen["$k"]=1; }
    done
    [ ${#kernels[@]} -gt 0 ] || { warn "无有效选择, 已取消"; pause; return 0; }

    title "APT 删除模拟"
    if ! apt-get -s purge "${kernels[@]}"; then
        err "APT 模拟失败，未执行任何删除"
        return 1
    fi
    confirm "确认按上方模拟结果删除?" || { info "已取消"; pause; return 0; }

    if ! apt-get purge -y "${kernels[@]}"; then
        err "内核删除失败，已停止；不会自动执行 autoremove"
        return 1
    fi
    update-grub || return 1
    if command -v proxmox-boot-tool >/dev/null 2>&1; then
        proxmox-boot-tool refresh || return 1
    fi
    ok "选定的旧内核已删除；未执行高风险的自动 autoremove"
    log "old kernels removed: ${kernels[*]}"
    pause
}

# =============================================================================
#  还原中心  ★
# =============================================================================

# 1) 官方源还原: 按当前 PVE/Debian 版本重建官方基线
restore_official_sources(){
    clear_screen
    title "官方软件源还原"
    info "适用场景: 之前跑过来路不明的脚本, 源文件被改乱/删除, 想回到官方原版。"
    echo
    info "将重建 Debian + PVE 仓库；Ceph 可选，不再对未使用 Ceph 的节点强行添加。"
    info "PVE9 使用 deb822；PVE7/8 使用传统 .list 与对应 release key。"
    local kind cephkind rc=0 default_kind="" current_label="无法确定"
    local -a current_ent=() current_nos=()
    mapfile -t current_ent < <(active_repo_files 'enterprise\.proxmox\.com/debian/pve|Components:[[:space:]]*pve-enterprise|[[:space:]]pve-enterprise([[:space:]]|$)' "$DEB_CODE")
    mapfile -t current_nos < <(active_repo_files 'Components:[[:space:]]*pve-no-subscription|[[:space:]]pve-no-subscription([[:space:]]|$)' "$DEB_CODE")
    if [ ${#current_ent[@]} -eq 1 ] && [ ${#current_nos[@]} -eq 0 ]; then default_kind=1; current_label="企业源"; fi
    if [ ${#current_ent[@]} -eq 0 ] && [ ${#current_nos[@]} -eq 1 ]; then default_kind=2; current_label="无订阅源"; fi
    echo
    info "当前 PVE 仓库类型: $current_label"
    read -r -t 60 -p " PVE 仓库: 1.企业源(需订阅) 2.无订阅源 0.取消 [默认保持当前]: " kind || return 0
    kind=${kind:-$default_kind}
    [ -n "$kind" ] || { err "当前仓库类型不唯一，请明确选择 1 或 2"; return 1; }
    case "$kind" in 1|2) ;; 0) return 0 ;; *) warn "无效选择"; return 1 ;; esac
    read -r -t 60 -p " Ceph 仓库: 0.保持不变 1.企业源 2.no-subscription [默认0]: " cephkind || return 0
    cephkind=${cephkind:-0}
    case "$cephkind" in 0|1|2) ;; *) warn "无效选择"; return 1 ;; esac
    [ "$cephkind" = "0" ] || warn_ceph_cluster_scope

    title "还原计划"
    [ "$kind" = "1" ] && info "PVE: 官方企业源" || info "PVE: 官方 no-subscription 源"
    info "Debian: 官方 base/updates/security (${DEB_CODE})"
    case "$cephkind" in 0) info "Ceph: 保持不变" ;; 1) info "Ceph: 官方企业源" ;; 2) info "Ceph: 官方 no-subscription 源" ;; esac
    info "其他第三方仓库保留；冲突的 PVE/Ceph 条目会精确禁用。"
    confirm "确认执行并在失败时自动回滚?" || return 0

    begin_transaction sources
    echo; info "[1/4] 验证 PVE 官方密钥..."
    ensure_pve_keyring || rc=1
    if [ "$rc" = "0" ]; then
        echo; info "[2/4] 重建 Debian 官方源..."
        write_debian_repos "https://deb.debian.org/debian" "https://security.debian.org/debian-security" || rc=1
    fi
    if [ "$rc" = "0" ]; then
        echo; info "[3/4] 重建 PVE 官方仓库..."
        if [ "$kind" = "1" ]; then
            write_pve_repo enterprise "https://enterprise.proxmox.com/debian/pve" || rc=1
        else
            write_pve_repo nosub "http://download.proxmox.com/debian/pve" || rc=1
        fi
    fi
    if [ "$rc" = "0" ] && [ "$cephkind" != "0" ]; then
        local ceph_release
        if ceph_release=$(ceph_codename); then
            info "按检测到的 $ceph_release 重建 Ceph 仓库..."
            if [ "$cephkind" = "1" ]; then
                write_ceph_repo enterprise "https://enterprise.proxmox.com/debian" || rc=1
            else
                write_ceph_repo nosub "http://download.proxmox.com/debian" || rc=1
            fi
        else
            rc=1
        fi
    fi
    if [ "$rc" = "0" ]; then
        echo; info "[4/4] 验证软件源..."
        apt_update_strict && verify_single_pve_repo && verify_debian_repos || rc=1
    fi
    if [ "$rc" = "0" ]; then
        commit_transaction
        ok "官方源基线已重建，apt 验证通过。"
        log "official sources restored pve_kind=$kind ceph_kind=$cephkind"
    else
        err "官方源重建或 apt 验证失败，正在回滚"
        if rollback_transaction; then
            warn "已回到本次操作前的源配置"
        else
            err "回滚不完整，备份位于 $BACKUP_FILES"
        fi
        return 1
    fi
}

# 2) 官方包重装: 一步还原所有被改的系统文件
restore_system_files(){
    clear_screen
    title "官方包重装还原系统文件"
    info "pve-manager 包含: Nodes.pm / pvemanagerlib.js / APLInfo.pm / pveceph.pm"
    info "proxmox-widget-toolkit 包含: proxmoxlib.js (订阅弹窗)"
    info "重装 = 官方原版文件直接覆盖, 比 sed 修补可靠 100%"
    confirm "重装 pve-manager + proxmox-widget-toolkit?" || return 0
    info "刷新源..."
    apt_update_strict || { err "apt-get update 失败，已中止重装"; return 1; }
    local cleanup_rc=0
    if reinstall_installed_packages pve-manager proxmox-widget-toolkit; then
        ok "系统文件已还原为官方原版!"
        systemctl disable --now pve-toolkit-hw.timer >/dev/null 2>&1 || true
        for f in "$HW_TIMER" "$HW_SERVICE" "$HW_COLLECTOR"; do
            if [ -e "$f" ]; then
                restore_original "$f" || { grep -qi 'pve-toolkit' "$f" 2>/dev/null && disable_file "$f"; } || cleanup_rc=1
            fi
        done
        remove_unsafe_setuid || cleanup_rc=1
        systemctl daemon-reload >/dev/null 2>&1 || cleanup_rc=1
        systemctl restart pveproxy pvedaemon || return 1
        if [ "$cleanup_rc" = "0" ]; then
            info "温度显示/订阅提示修改也已还原，后台采集器已移除。"
        else
            warn "PVE 包已还原，但部分采集器/SUID 清理失败，请运行残留清理。"
            return 1
        fi
        log "system files restored via package reinstall"
    else
        err "重装失败! 多半是软件源仍是坏的, 请先执行『官方源还原』"
        return 1
    fi
    return 0
}

# 3) 从本脚本备份回滚
restore_from_backup(){
    clear_screen
    title "从本脚本备份回滚"
    if [ ! -e "$MANIFEST" ]; then
        info "本脚本还没有做过任何修改, 无备份可回滚。"
        return 0
    fi
    echo " 备份记录 (每条取最新一份):"
    awk -F'|' '{print $2}' "$MANIFEST" | sort -u | nl -w 3 -s '. ' | sed 's/^/    /'
    echo
    info "输入要回滚的序号(逗号分隔), 或 a=尝试全部安全配置（不安全项会拒绝）, 直接回车取消:"
    local sel
    read -r -p " > " sel
    [ -n "$sel" ] || { info "已取消"; return 0; }

    local files rc=0 idx f2 f
    local need_apt=0 need_debian=0 need_systemd=0 need_grub=0 need_boot=0 need_initramfs=0 need_pve=0
    local -a all_files=() selected_files=() idxlist=()
    files=$(awk -F'|' '{print $2}' "$MANIFEST" | sort -u)
    mapfile -t all_files <<< "$files"
    if [ "$sel" = "a" ]; then
        selected_files=("${all_files[@]}")
    else
        IFS=',' read -r -a idxlist <<< "$sel"
        for idx in "${idxlist[@]}"; do
            if [[ "$idx" =~ ^[[:space:]]*[0-9]+[[:space:]]*$ ]]; then
                idx=${idx//[[:space:]]/}
                if [ "$idx" -ge 1 ] && [ "$idx" -le ${#all_files[@]} ]; then
                    selected_files+=("${all_files[$((idx - 1))]}")
                else
                    warn "超出范围: $idx"; rc=1
                fi
            else
                warn "无效序号: $idx"
                rc=1
            fi
        done
    fi
    [ "$rc" = "0" ] && [ ${#selected_files[@]} -gt 0 ] || return 1

    for f in "${selected_files[@]}"; do
        case "$f" in
            /usr/share/perl5/PVE/*|/usr/share/pve-manager/*|/usr/share/javascript/proxmox-widget-toolkit/*)
                err "选择中包含软件包所有文件，不允许手动原样回滚: $f"
                info "请用『官方包重装』，或重新只选安全的配置文件。"
                return 1 ;;
            /etc/systemd/system/*)
                err "选择中包含 systemd unit，单纯恢复文件无法恢复 enable/active 状态: $f"
                info "请使用对应功能的『移除/恢复』操作。"
                return 1 ;;
            /var/lib/pve-toolkit/*|/usr/local/lib/pve-toolkit/*|/etc/modules-load.d/pve-toolkit-*)
                err "选择中包含必须与功能成组管理的内部状态/采集器文件: $f"
                info "请使用直通、CPU 电源模式或硬件面板的对应移除/恢复功能。"
                return 1 ;;
        esac
    done

    title "回滚预览"
    printf '    %s\n' "${selected_files[@]}"
    warn "软件包所有的 /usr/share 文件不允许手动原样回滚，会引导使用官方包重装。"
    confirm "将以单个事务回滚上述文件，并执行相应后置验证。继续?" || return 0

    begin_transaction restore
    for f in "${selected_files[@]}"; do
        case "$f" in
            /etc/apt/*|/usr/share/keyrings/proxmox-*) need_apt=1 ;;
            /etc/systemd/system/*|/etc/modules-load.d/*) need_systemd=1 ;;
        esac
        case "$f" in /etc/apt/sources.list*) need_debian=1 ;; esac
        case "$f" in /etc/default/grub) need_grub=1 ;; esac
        case "$f" in /etc/kernel/cmdline) need_boot=1 ;; esac
        case "$f" in /etc/modules|/etc/modprobe.d/*|/etc/modules-load.d/*) need_initramfs=1 ;; esac
        case "$f" in
            /usr/share/perl5/PVE/*|/usr/share/pve-manager/*|/usr/share/javascript/proxmox-widget-toolkit/*) need_pve=1 ;;
        esac
        restore_latest "$f" || { rc=1; break; }
    done
    if [ "$rc" = "0" ] && [ "$need_apt" = "1" ]; then
        apt_update_strict && verify_single_pve_repo || rc=1
        if [ "$rc" = "0" ] && [ "$need_debian" = "1" ]; then verify_debian_repos || rc=1; fi
    fi
    if [ "$rc" = "0" ] && [ "$need_systemd" = "1" ]; then systemctl daemon-reload || rc=1; fi
    if [ "$rc" = "0" ] && [ "$need_grub" = "1" ]; then update-grub || rc=1; fi
    if [ "$rc" = "0" ] && [ "$need_boot" = "1" ]; then proxmox-boot-tool refresh || rc=1; fi
    if [ "$rc" = "0" ] && [ "$need_initramfs" = "1" ]; then update-initramfs -u || rc=1; fi
    if [ "$rc" = "0" ] && [ "$need_pve" = "1" ]; then systemctl restart pveproxy pvedaemon || rc=1; fi

    if [ "$rc" = "0" ]; then
        commit_transaction
        ok "选定备份已回滚"
        log "restored from backup selection=$sel"
    else
        err "回滚或后置验证失败，正在恢复本次回滚前的状态"
        rollback_transaction || err "自动撤销不完整，请检查 $MANIFEST"
        [ "$need_apt" = "0" ] || apt_update_strict >/dev/null 2>&1 || true
        [ "$need_systemd" = "0" ] || systemctl daemon-reload >/dev/null 2>&1 || true
        [ "$need_grub" = "0" ] || update-grub >/dev/null 2>&1 || true
        [ "$need_boot" = "0" ] || proxmox-boot-tool refresh >/dev/null 2>&1 || true
        [ "$need_initramfs" = "0" ] || update-initramfs -u >/dev/null 2>&1 || true
        [ "$need_pve" = "0" ] || systemctl restart pveproxy pvedaemon >/dev/null 2>&1 || true
    fi
    return "$rc"
}

# 4) 清理常见脚本残留
cleanup_leftovers(){
    clear_screen
    title "清理常见脚本残留"
    local found=0 tmp need_initramfs=0 rc=0 f

    remove_unsafe_setuid || return 1

    # 不自动改别的脚本所有的 cron，只做提示。
    if crontab -l 2>/dev/null | grep -q 'CPU Power Mode'; then
        warn "检测到非本工具管理的 CPU Power Mode cron，为避免误删仅提示；请用 crontab -e 确认。"
    fi

    begin_transaction boot
    if [ -e /etc/modules-load.d/turbostat-msr.conf ] && confirm "删除 /etc/modules-load.d/turbostat-msr.conf? (turbostat 功耗显示依赖它)"; then
        disable_file /etc/modules-load.d/turbostat-msr.conf || rc=1
        found=1
    fi
    if grep -qsE '^(vfio|vfio_iommu_type1|vfio_pci|vfio_virqfd|kvmgt)$' /etc/modules \
        && confirm "从 /etc/modules 移除旧脚本写入的 vfio/kvmgt 独立行?"; then
        tmp=$(mktemp /etc/modules.pve-toolkit.XXXXXX) || { rollback_transaction || true; return 1; }
        if ! sed '/^vfio$/d; /^vfio_iommu_type1$/d; /^vfio_pci$/d; /^vfio_virqfd$/d; /^kvmgt$/d' \
            /etc/modules > "$tmp"; then
            rm -f "$tmp"
            err "读取/转换 /etc/modules 失败，未修改原文件"
            rc=1
        elif backup_file /etc/modules; then
            chmod --reference=/etc/modules "$tmp" 2>/dev/null || chmod 0644 "$tmp"
            chown --reference=/etc/modules "$tmp" 2>/dev/null || true
            if atomic_replace_path "$tmp" /etc/modules; then
                warn "已移除直通模块配置"
                found=1
                need_initramfs=1
            else
                rm -f "$tmp"
                rc=1
            fi
        else
            rm -f "$tmp"
            rc=1
        fi
    fi
    if [ -e /etc/modprobe.d/pve-blacklist.conf ] && confirm "删除 /etc/modprobe.d/pve-blacklist.conf (驱动屏蔽)?"; then
        disable_file /etc/modprobe.d/pve-blacklist.conf || rc=1
        found=1; need_initramfs=1
    fi
    if [ -e /etc/modprobe.d/vfio.conf ] && confirm "删除 /etc/modprobe.d/vfio.conf (设备绑定)?"; then
        disable_file /etc/modprobe.d/vfio.conf || rc=1
        found=1; need_initramfs=1
    fi
    if [ "$rc" = "0" ] && { [ "$need_initramfs" = "0" ] || update-initramfs -u; }; then
        commit_transaction
    else
        rollback_transaction || err "残留清理回滚不完整"
        return 1
    fi

    if [ -e /etc/systemd/system/pve-governor.service ] && confirm "移除 CPU 电源模式自持服务?"; then
        gov_restore || return 1
        found=1
    fi
    if { [ -e "$HW_TIMER" ] || [ -e "$HW_SERVICE" ] || [ -e "$HW_COLLECTOR" ]; } \
        && ! grep -q "$TOOLKIT" "$NODES_PM" 2>/dev/null \
        && confirm "检测到孤立的硬件采集器，移除?"; then
        DISPLAY_TIMER_WAS_ACTIVE=0
        DISPLAY_TIMER_ENABLE_STATE=$(unit_enable_state pve-toolkit-hw.timer)
        case "$DISPLAY_TIMER_ENABLE_STATE" in
            linked|linked-runtime|alias)
                err "pve-toolkit-hw.timer 为 ${DISPLAY_TIMER_ENABLE_STATE}，无法保证无损清理。"
                return 1 ;;
        esac
        systemctl is-active pve-toolkit-hw.timer >/dev/null 2>&1 && DISPLAY_TIMER_WAS_ACTIVE=1
        begin_transaction display_remove
        systemctl disable --now pve-toolkit-hw.timer >/dev/null 2>&1 || true
        for f in "$HW_TIMER" "$HW_SERVICE" "$HW_COLLECTOR"; do
            [ -e "$f" ] || continue
            restore_original "$f" || { grep -qi 'pve-toolkit' "$f" 2>/dev/null && disable_file "$f"; } || rc=1
        done
        systemctl daemon-reload >/dev/null 2>&1 || rc=1
        if [ "$rc" = "0" ]; then
            commit_transaction
            found=1
        else
            rollback_transaction || err "采集器清理回滚不完整"
            return 1
        fi
    fi

    if [ "$found" = "0" ]; then ok "未发现常见残留, 系统很干净!"; fi
    [ "$found" = "0" ] || log "leftovers cleaned"
    return 0
}

restore_menu(){
    local session_rc=0
    while :; do
        clear_screen
        cat <<MENUEOF

   ${C_R}还原中心${C_N}  —— 修复被各种脚本改坏的 PVE
   ------------------------------------------------
    1. 官方软件源基线 (重建 Debian/PVE，Ceph 可选，保留第三方源)
    2. 官方包重装还原系统文件 (订阅弹窗/温度显示等全部还原)
    3. 从本脚本的备份回滚单个/全部文件
    4. 清理常见脚本残留 (SUID/直通/governor等)
    0. 返回
   ------------------------------------------------
   ${C_Y}推荐顺序: 先 1 修好源, 再 2 还原系统文件${C_N}
MENUEOF
        local c
        read -r -t 60 -p " 请选择 [默认0]: " c || return "$session_rc"
        c=${c:-0}
        case "$c" in
            1) restore_official_sources || session_rc=1; pause ;;
            2) restore_system_files || session_rc=1; pause ;;
            3) restore_from_backup || session_rc=1; pause ;;
            4) cleanup_leftovers || session_rc=1; pause ;;
            0) return "$session_rc" ;;
            *) warn "无效选择: $c"; pause ;;
        esac
    done
}

# =============================================================================
#  系统体检
# =============================================================================
active_repo_files(){
    # 仅把二进制仓库 (deb / Types: deb) 视为可用更新通道；可选的第二个
    # 参数要求 suite 精确匹配当前 Debian codename。
    local pattern="$1" expected_suite="${2:-}" pattern_lc f
    pattern_lc=$(printf '%s' "$pattern" | tr '[:upper:]' '[:lower:]')
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
        [ -r "$f" ] || continue
        if [[ "$f" == *.sources ]]; then
            awk -v RS='' -v file="$f" -v pattern="$pattern_lc" -v expected="$expected_suite" '
                {
                    n=split($0, lines, "\n"); effective=""; binary=0; suite_ok=1; suite=""; suite_count=0
                    for (i=1; i<=n; i++) {
                        if (lines[i] ~ /^[[:space:]]*#/) continue
                        effective=effective "\n" lines[i]
                        field=tolower(lines[i])
                        if (field ~ /^[[:space:]]*types:/) {
                            sub(/^[[:space:]]*types:[[:space:]]*/, "", field)
                            count=split(field, values, /[[:space:]]+/)
                            for (j=1; j<=count; j++) if (values[j] == "deb") binary=1
                        }
                        field=tolower(lines[i])
                        if (field ~ /^[[:space:]]*suites:/) {
                            sub(/^[[:space:]]*suites:[[:space:]]*/, "", field)
                            count=split(field, values, /[[:space:]]+/)
                            for (j=1; j<=count; j++) {
                                if (values[j] == "") continue
                                suite_count++
                                suite=suite (suite == "" ? "" : ",") values[j]
                                if (expected != "" && values[j] != expected) suite_ok=0
                            }
                        }
                    }
                    lower=tolower(effective)
                    if (binary && suite_count > 0 && suite_ok && lower !~ /enabled:[[:space:]]*no/ && lower ~ pattern) {
                        print file "#stanza" NR "[suite=" suite "]"
                    }
                }
            ' "$f"
        else
            awk -v file="$f" -v pattern="$pattern" -v expected="$expected_suite" '
                /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
                $1 != "deb" { next }
                $0 ~ pattern {
                    i=2
                    if ($i ~ /^\[/) { while (i <= NF && $i !~ /\]$/) i++; i++ }
                    suite=$(i+1)
                    if (expected == "" || suite == expected) print file "#line" NR "[suite=" suite "]"
                }
            ' "$f"
        fi
    done
}

health_check(){
    clear_screen
    title "PVE 系统体检"
    info "环境: PVE ${PVE_FULL:-?} | Debian ${DEB_CODE:-?} | 内核 $(uname -r)"
    local warnings=0 failures=0
    local -a ent_files=() nos_files=() test_files=() ceph_files=()
    local -a all_ent_files=() all_nos_files=() all_test_files=() all_ceph_files=()
    local f out rc state node_mod=0 js_mod=0 cnt=0 n=0 suid_found=0 manifest_tx manifest_pve manifest_hash manifest_origin actual_hash
    local pve_repo_invalid=0 legacy_manifest=0
    hc_warn(){ warnings=$((warnings + 1)); warn "$*"; }
    hc_fail(){ failures=$((failures + 1)); err "$*"; }

    if [ "$PVE_VER" -le 8 ]; then
        hc_warn "PVE ${PVE_VER} 已结束上游常规支持，建议迁移到 PVE 9"
    fi

    echo; title "软件源状态"
    mapfile -t all_ent_files < <(active_repo_files 'enterprise\.proxmox\.com/debian/pve|Components:[[:space:]]*pve-enterprise|[[:space:]]pve-enterprise([[:space:]]|$)')
    mapfile -t all_nos_files < <(active_repo_files 'Components:[[:space:]]*pve-no-subscription|[[:space:]]pve-no-subscription([[:space:]]|$)')
    mapfile -t all_test_files < <(active_repo_files 'Components:[[:space:]]*(pve-test|pvetest)|[[:space:]](pve-test|pvetest)([[:space:]]|$)')
    mapfile -t all_ceph_files < <(active_repo_files 'ceph-(pacific|quincy|reef|squid|tentacle)')
    mapfile -t ent_files < <(active_repo_files 'enterprise\.proxmox\.com/debian/pve|Components:[[:space:]]*pve-enterprise|[[:space:]]pve-enterprise([[:space:]]|$)' "$DEB_CODE")
    mapfile -t nos_files < <(active_repo_files 'Components:[[:space:]]*pve-no-subscription|[[:space:]]pve-no-subscription([[:space:]]|$)' "$DEB_CODE")
    mapfile -t test_files < <(active_repo_files 'Components:[[:space:]]*(pve-test|pvetest)|[[:space:]](pve-test|pvetest)([[:space:]]|$)' "$DEB_CODE")
    mapfile -t ceph_files < <(active_repo_files 'ceph-(pacific|quincy|reef|squid|tentacle)' "$DEB_CODE")
    if [ ${#all_ent_files[@]} -ne ${#ent_files[@]} ] \
        || [ ${#all_nos_files[@]} -ne ${#nos_files[@]} ] \
        || [ ${#all_test_files[@]} -ne ${#test_files[@]} ]; then
        hc_fail "PVE 仓库含多 suite 或与 ${DEB_CODE} 不匹配的条目: ${all_ent_files[*]} ${all_nos_files[*]} ${all_test_files[*]}"
        pve_repo_invalid=1
    fi
    if [ ${#all_ceph_files[@]} -ne ${#ceph_files[@]} ]; then
        hc_fail "Ceph 仓库含多 suite 或与 ${DEB_CODE} 不匹配的条目: ${all_ceph_files[*]}"
    fi
    if [ ${#ent_files[@]} -eq 0 ] && [ ${#nos_files[@]} -eq 0 ]; then
        hc_fail "未发现已启用的 PVE 仓库，无法获取 PVE 更新"
        pve_repo_invalid=1
    else
        [ ${#ent_files[@]} -eq 0 ] || info "PVE 企业源: ${ent_files[*]}"
        [ ${#nos_files[@]} -eq 0 ] || info "PVE 无订阅源: ${nos_files[*]}"
    fi
    [ ${#ent_files[@]} -eq 0 ] || [ ${#nos_files[@]} -eq 0 ] \
        || hc_warn "PVE 企业源与无订阅源同时启用，应二选一"
    [ ${#ent_files[@]} -le 1 ] || hc_warn "检测到多个 PVE 企业源文件: ${ent_files[*]}"
    [ ${#nos_files[@]} -le 1 ] || hc_warn "检测到多个 PVE 无订阅源文件: ${nos_files[*]}"
    if [ ${#test_files[@]} -ne 0 ]; then
        hc_fail "PVE 测试仓库正在启用: ${test_files[*]}"
        pve_repo_invalid=1
    fi
    [ ${#ceph_files[@]} -eq 0 ] || info "Ceph 源: ${ceph_files[*]}"
    if [ "$pve_repo_invalid" = "0" ] && [ ${#test_files[@]} -eq 0 ] && { \
        { [ ${#ent_files[@]} -eq 1 ] && [ ${#nos_files[@]} -eq 0 ]; } \
        || { [ ${#ent_files[@]} -eq 0 ] && [ ${#nos_files[@]} -eq 1 ]; }; }; then
        ok "PVE 二进制稳定仓库唯一且 suite=${DEB_CODE}"
    elif [ "$pve_repo_invalid" = "0" ]; then
        hc_fail "PVE 二进制稳定仓库必须且只能启用一个"
    fi

    if apt-get check >/dev/null 2>&1; then
        ok "APT 配置可解析，dpkg 依赖状态正常"
    else
        hc_fail "apt-get check 失败，存在源语法或包依赖问题"
    fi
    if verify_debian_repos; then
        ok "Debian base/updates/security 各有一份且 suite 与 ${DEB_CODE} 匹配"
    else
        hc_fail "Debian 基础源存在缺失、重复或跨版本冲突"
    fi

    echo; title "系统文件完整性 (dpkg 校验)"
    if ! dpkg-query -W pve-manager proxmox-widget-toolkit >/dev/null 2>&1; then
        hc_fail "pve-manager 或 proxmox-widget-toolkit 未完整安装"
    else
        out=$(dpkg -V pve-manager proxmox-widget-toolkit 2>&1); rc=$?
        if [ "$rc" -gt 1 ]; then
            hc_fail "dpkg 校验执行失败: $out"
        elif [ -n "$out" ]; then
            hc_warn "PVE 包文件与官方版本不一致（本工具的面板/订阅修改也会出现于此）:"
            printf '%s\n' "$out" | sed 's/^/    /'
        else
            ok "pve-manager / proxmox-widget-toolkit 与已安装包校验一致"
        fi
    fi

    echo; title "安全权限"
    for f in /usr/sbin/nvme /usr/bin/nvme /usr/sbin/smartctl /usr/bin/smartctl \
             /usr/sbin/turbostat /usr/bin/turbostat /usr/sbin/linux-cpupower /usr/bin/cpupower; do
        if [ -e "$f" ] && [ -u "$f" ]; then
            hc_fail "检测到高危 SUID: $f（请运行还原中心 -> 残留清理）"
            suid_found=1
        fi
    done
    [ "$suid_found" = "1" ] || ok "未发现本工具旧版遗留的硬件工具 SUID"

    echo; title "Web 自定义状态"
    grep -q "$TOOLKIT" "$NODES_PM" 2>/dev/null && node_mod=1
    grep -q "$TOOLKIT" "$PVE_MANAGER_JS" 2>/dev/null && js_mod=1
    if [ "$node_mod" != "$js_mod" ]; then
        hc_fail "硬件信息面板只安装了一半 (Nodes.pm=$node_mod, JS=$js_mod)"
    elif [ "$node_mod" = "1" ]; then
        if systemctl is-enabled pve-toolkit-hw.timer >/dev/null 2>&1 \
            && systemctl is-active pve-toolkit-hw.timer >/dev/null 2>&1; then
            ok "硬件信息面板与后台缓存计时器已启用"
        else
            hc_warn "硬件面板已安装，但 pve-toolkit-hw.timer 未正常运行"
        fi
    else
        info "硬件信息面板: 未安装"
    fi
    if grep -qE 'if[[:space:]]*\([[:space:]]*false[[:space:]]*\)' "$PROXMOXLIB_JS" 2>/dev/null; then
        info "订阅提示: 已修改"
    else
        info "订阅提示: 官方状态"
    fi

    echo; title "IOMMU / 直通"
    n=$(find /sys/kernel/iommu_groups -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    if [ "$n" -gt 0 ]; then
        ok "IOMMU 已启用，${n} 个分组"
    elif grep -qE '(^| )(intel_iommu=on|amd_iommu=on|iommu=pt)( |$)' /proc/cmdline 2>/dev/null; then
        hc_warn "内核参数包含 IOMMU，但没有 IOMMU 分组；请检查 BIOS 或重启"
    else
        info "IOMMU: 未启用"
    fi

    echo; title "CPU 电源模式"
    info "当前: $(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null || echo '未知')"
    systemctl is-enabled pve-governor.service >/dev/null 2>&1 \
        && info "自持服务: 已启用" || info "自持服务: 未启用"

    echo; title "内核与备份"
    while IFS= read -r f; do
        dpkg-query -L "$f" 2>/dev/null | grep -qE '^/boot/vmlinuz-' && cnt=$((cnt + 1))
    done < <(dpkg-query -W -f='${binary:Package}\n' 'pve-kernel-[0-9]*' 'proxmox-kernel-[0-9]*' 2>/dev/null || true)
    info "已安装可引导 PVE 内核 ${cnt} 个 (当前: $(uname -r))"
    if [ -e "$MANIFEST" ]; then
        while IFS='|' read -r _ f out state manifest_tx manifest_pve manifest_hash manifest_origin; do
            state=${state:-present}
            if [ "$state" = "present" ]; then
                if [ ! -e "$out" ] && [ ! -L "$out" ]; then
                    hc_fail "备份索引指向丢失文件: $f -> $out"
                    continue
                fi
                case "$manifest_hash" in
                    file:*|link:*) actual_hash=$(snapshot_hash "$out" 2>/dev/null || true) ;;
                    [0-9a-f][0-9a-f]*)
                        if [ -L "$out" ]; then actual_hash="unsafe-legacy-link"; else actual_hash=$(sha256sum "$out" 2>/dev/null | awk '{print $1}'); fi ;;
                    *) legacy_manifest=1; continue ;;
                esac
                [ "$actual_hash" = "$manifest_hash" ] \
                    || hc_fail "备份已损坏或类型不符: $f -> $out"
            fi
        done < "$MANIFEST"
        [ "$legacy_manifest" = "0" ] || hc_warn "存在旧版无类型化 SHA-256 的备份，只建议用作人工参考"
        info "备份记录: $(wc -l < "$MANIFEST") 条，位于 $BACKUP_ROOT"
        info "备份占用: $(du -sh "$BACKUP_ROOT" 2>/dev/null | awk '{print $1}') | 分区可用: $(df -h "$BACKUP_ROOT" 2>/dev/null | awk 'NR == 2 {print $4}')"
        info "快照不会静默自动删除，请定期检查容量。"
    else
        info "本工具尚无备份记录"
    fi

    echo
    title "体检结果"
    if [ "$failures" -gt 0 ]; then
        err "${failures} 项失败，${warnings} 项警告"
        log "health check failures=$failures warnings=$warnings"
        return 2
    elif [ "$warnings" -gt 0 ]; then
        warn "0 项失败，${warnings} 项警告"
        log "health check failures=0 warnings=$warnings"
        return 1
    else
        ok "0 项失败，0 项警告"
        log "health check healthy"
        return 0
    fi
}

# =============================================================================
#  主菜单
# =============================================================================
usage(){
    cat <<USGEOF
 PVE Toolkit v${VERSION} — Proxmox VE 一键优化/还原
 用法:
   bash pve.sh              交互主菜单
   bash pve.sh --status     非交互系统体检 (0=正常, 1=警告, 2=失败)
   bash pve.sh --restore    直达还原中心
   bash pve.sh --version    显示版本
USGEOF
}

main_menu(){
    while :; do
        clear_screen
        cat <<MENUEOF

   ${C_Y}╔════════════════════════════════════════════╗${C_N}
   ${C_Y}║${C_N}     PVE Toolkit v${VERSION} 一键优化/还原       ${C_Y}║${C_N}
   ${C_Y}╚════════════════════════════════════════════╝${C_N}
    环境: PVE ${PVE_FULL:-?} | Debian ${DEB_CODE:-?} (${DEB_VER})

    1. 安全优化 (换源+验证+失败回滚，Ceph/CT/订阅可选)
    2. 软件源管理 (单独换 Debian/PVE/Ceph/CT 源)
    3. 订阅弹窗 (移除/还原)
    4. CPU/硬盘信息显示 (温度/频率/功耗/健康)
    5. 硬件直通 (Intel/AMD 自动识别)
    6. CPU 电源模式 (开机自持)
    7. Ceph 管理 (源/只读退役检查)
    8. 旧内核清理 (保护当前/pin/备用内核)
   ------------------------------------------------
    R. ${C_R}还原中心${C_N} ★ 修复被其他脚本改坏的 PVE
    S. 系统体检 (源冲突/文件完整性/直通状态)
    0. 退出
MENUEOF
        local c
        read -r -t 120 -p " 请选择 [默认0]: " c || return 0
        c=${c:-0}
        case "$c" in
            1) one_key_optimize; pause ;;
            2) source_menu; pause ;;
            3)
                clear_screen; title "订阅提示"
                local a; read -r -t 60 -p " 1.移除 2.还原 0.返回 [默认0]: " a || a=0
                a=${a:-0}
                case "$a" in
                    1)
                        begin_transaction nag
                        if remove_nag; then commit_transaction; else rollback_transaction || true; fi
                        ;;
                    2) restore_nag ;;
                    0) ;;
                    *) warn "无效选择: $a" ;;
                esac
                pause ;;
            4)
                clear_screen; title "CPU/硬盘信息显示"
                local a2; read -r -t 60 -p " 1.添加 2.移除 0.返回 [默认0]: " a2 || a2=0
                a2=${a2:-0}
                case "$a2" in
                    1) display_apply || true; pause ;;
                    2) display_remove || true; pause ;;
                    0) ;;
                    *) warn "无效选择: $a2"; pause ;;
                esac
                ;;
            5) passthrough_menu ;;
            6) cpu_power_menu ;;
            7) ceph_menu || true; pause ;;
            8) remove_old_kernels ;;
            r|R) restore_menu || true ;;
            s|S) health_check || true; pause ;;
            0) return 0 ;;
            *) warn "无效选择: $c"; pause ;;
        esac
    done
}

# =============================================================================
#  入口
# =============================================================================
handle_signal(){
    trap - INT TERM HUP
    printf '\n' >&2
    err "收到中断信号"
    if [ "$TRANSACTION_ACTIVE" = "1" ]; then
        if [ "$TRANSACTION_KIND" = "governor" ] && [ -r "$GOV_IMMEDIATE_STATE" ]; then
            restore_governors_file "$GOV_IMMEDIATE_STATE" >/dev/null 2>&1 || true
        fi
        rollback_transaction || err "中断后自动回滚不完整，请查看 $MANIFEST"
    fi
    [ -z "$GOV_IMMEDIATE_STATE" ] || rm -f "$GOV_IMMEDIATE_STATE"
    exit 130
}

if [ "${PVE_TOOLKIT_LIB_ONLY:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

trap handle_signal INT TERM HUP

if [ "$#" -gt 1 ]; then
    err "参数过多"
    usage
    exit 2
fi

case "${1:-}" in
    -h|--help|help)  usage; exit 0 ;;
    -V|--version)    printf '%s\n' "$VERSION"; exit 0 ;;
    --status|status)
        NONINTERACTIVE=1
        require_env
        health_check
        exit $? ;;
    --restore)
        [ -t 0 ] && [ -t 1 ] || { err "--restore 需要交互式终端"; exit 2; }
        require_env
        acquire_lock
        restore_menu
        exit $? ;;
    "") ;;
    *) err "未知参数: $1"; usage; exit 2 ;;
esac

[ -t 0 ] && [ -t 1 ] || { err "交互菜单需要 TTY；自动体检请用 --status"; exit 2; }
require_env
acquire_lock
main_menu
