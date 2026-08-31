#!/usr/bin/env bash
# =============================================================================
#  PVE Toolkit — Proxmox VE 一键优化 / 一键还原 脚本
# =============================================================================
#  兼容: PVE 7 / 8 / 9 (Debian bullseye / bookworm / trixie)
#
#  功能:
#    - 一键优化: 换国内源(官方/中科大/清华) + 关企业源 + 去订阅弹窗 + CT模板源
#    - 智能换源: 自动适配 deb822(.sources) 与传统(.list) 两种格式, PVE7/8/9 通吃
#    - 摘要信息: CPU温度/频率/功耗 + 核显温度 + NVMe/SATA硬盘健康 动态显示
#        * AMD (Tdie/Tctl/k10temp) 与 Intel 通吃, 核心数量不限(4个一行)
#        * NVMe 硬盘数量不限(动态探测), SATA 盘逐盘解析 SMART
#    - 硬件直通: Intel/AMD 自动识别, 开启/关闭/状态查看
#    - CPU 电源模式: 切换 governor, systemd 开机自持 (不再用脆弱的 cron)
#    - Ceph: 添加 no-subscription 源(quincy/squid 自动匹配) / 一键卸载
#    - 旧内核清理: 交互式选择, 安全排除当前运行内核
#    - 还原中心: 官方源还原 / 官方包重装 / 本脚本备份回滚 / 残留清理
#    - 系统体检: dpkg 校验系统文件是否被改动 + 软件源冲突检查
#
#  还原中心说明:
#    网上各种 PVE 脚本质量参差, 改坏软件源后 apt 直接瘫痪。本脚本内置:
#      1) 官方源还原 —— 按 Proxmox 官方 Wiki 的原始定义重建全部源文件
#         (PVE9: deb822 格式 pve-enterprise.sources / proxmox.sources / ceph.sources;
#          PVE7/8: 传统 .list 格式; Debian 源同样按版本重建)
#      2) 官方包重装 —— `apt-get install --reinstall pve-manager proxmox-widget-toolkit`
#         可将被改过的 Nodes.pm / pvemanagerlib.js / proxmoxlib.js / APLInfo.pm /
#         pveceph.pm 一步还原为官方原版 (最可靠的还原方式)
#      3) 本脚本所有修改前的原文件, 均备份于 /var/backups/pve-toolkit/files/
#         并记录在 manifest.log 中, 可精确回滚
#
#
#  用法:
#    bash pve.sh              # 进入主菜单
#    bash pve.sh --status     # 只做系统体检
#    bash pve.sh --restore    # 直达还原中心
# =============================================================================

VERSION="1.0.0"

# ---------- 全局常量 ----------
TOOLKIT="pve-toolkit"
BACKUP_ROOT="/var/backups/pve-toolkit"
BACKUP_FILES="$BACKUP_ROOT/files"
BACKUP_DISABLED="$BACKUP_ROOT/disabled"
MANIFEST="$BACKUP_ROOT/manifest.log"
LOG_FILE="/var/log/pve-toolkit.log"

NODES_PM="/usr/share/perl5/PVE/API2/Nodes.pm"
PVE_MANAGER_JS="/usr/share/pve-manager/js/pvemanagerlib.js"
PROXMOXLIB_JS="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
APLINFO_PM="/usr/share/perl5/PVE/APLInfo.pm"
PVECEPH_PM="/usr/share/perl5/PVE/CLI/pveceph.pm"

# 镜像变量(由 choose_mirror 设置)
MIR_DEBIAN="" ; MIR_SEC="" ; MIR_PVE="" ; MIR_CEPH_ROOT=""

# 环境变量(由 detect_env 设置)
PVE_VER="" ; PVE_FULL="" ; DEB_CODE="" ; DEB_VER=""

# ---------- 输出与交互 ----------
C_R=$'\033[31;1m'; C_G=$'\033[32;1m'; C_Y=$'\033[33;1m'
C_B=$'\033[34;1m'; C_C=$'\033[36;1m'; C_N=$'\033[0m'

ok()   { printf " %b[ OK ]%b %s\n"  "$C_G" "$C_N" "$*"; }
warn() { printf " %b[!!] %b %s\n"  "$C_Y" "$C_N" "$*"; }
err()  { printf " %b[FAIL]%b %s\n" "$C_R" "$C_N" "$*"; }
info() { printf " %b[..] %b %s\n"  "$C_C" "$C_N" "$*"; }
title(){ printf "\n %b========  %s  ========%b\n" "$C_B" "$*" "$C_N"; }

pause(){ read -r -n1 -s -t 30 -p " 按任意键继续..." _; printf "\n"; }
log(){ echo "$(date '+%F %T') | $*" >> "$LOG_FILE" 2>/dev/null; }

confirm(){
    local a; read -r -p " ${1:-确认执行?} [y/N]: " a
    [[ "$a" =~ ^[Yy]$ ]]
}

ask(){
    local a; read -r -p " ${1}: " a
    printf '%s' "$a"
}

# =============================================================================
#  环境检测
# =============================================================================
require_env(){
    if ! command -v pveversion >/dev/null 2>&1; then
        err "未检测到 Proxmox VE (pveversion 不存在)。"
        err "本脚本只能在 PVE 宿主机上以 root 运行!"
        exit 1
    fi
    if [ "$(id -u)" != "0" ]; then
        err "请使用 root 用户运行本脚本!"
        exit 1
    fi
    detect_env
}

detect_env(){
    PVE_FULL=$(pveversion 2>/dev/null | awk -F'/' '{print $2}')
    PVE_VER=${PVE_FULL%%.*}
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

# Ceph 大版本跟随 PVE: 9->squid, 8/7->quincy
ceph_codename(){
    case "$PVE_VER" in
        9) echo "ceph-squid" ;;
        *) echo "ceph-quincy" ;;
    esac
}

# =============================================================================
#  备份 / 回滚框架
#    所有被修改的文件, 先按原绝对路径存入 /var/backups/pve-toolkit/files/
#    manifest.log 记录 "时间戳|原路径|备份路径", 回滚时取最新一份
# =============================================================================
backup_file(){
    local f="$1" dest
    [ -e "$f" ] || { warn "备份目标不存在, 跳过: $f"; return 1; }
    dest="${BACKUP_FILES}${f}"
    if [ -e "$dest" ] && cmp -s "$f" "$dest"; then
        return 0
    fi
    mkdir -p "$(dirname "$dest")"
    cp -a "$f" "$dest" || { err "备份失败: $f"; return 1; }
    echo "$(date +%s)|$f|$dest" >> "$MANIFEST"
    log "backup $f -> $dest"
    ok "已备份: $f"
}

restore_latest(){
    local f="$1" latest="" ts p d
    [ -e "$MANIFEST" ] || return 1
    while IFS='|' read -r ts p d; do
        if [ "$p" = "$f" ] && [ -e "$d" ]; then latest="$d"; fi
    done < "$MANIFEST"
    [ -n "$latest" ] || { warn "没有 $f 的备份记录"; return 1; }
    # 回滚前把当前状态也备份一份, 保证回滚可撤销
    backup_file "$f"
    cp -a "$latest" "$f"
    log "restore $f <- $latest"
    ok "已回滚: $f"
}

restart_pve_web(){
    systemctl restart pveproxy >/dev/null 2>&1 && ok "已重启 pveproxy (Web控制台)"
}

# =============================================================================
#  PVE 密钥保障
#    PVE9: /usr/share/keyrings/proxmox-archive-keyring.gpg (deb822 Signed-By)
#    PVE8: 同上 (8.1+ deb822), 兜底 /etc/apt/trusted.gpg.d
#    PVE7: /etc/apt/trusted.gpg.d/proxmox-release-bullseye.gpg
# =============================================================================
ensure_pve_keyring(){
    local key7="/etc/apt/trusted.gpg.d/proxmox-release-${DEB_CODE}.gpg"
    local key9="/usr/share/keyrings/proxmox-archive-keyring.gpg"
    if [ "$PVE_VER" -ge 8 ]; then
        if [ -e "$key9" ]; then
            ok "Proxmox 密钥已存在"
            return 0
        fi
        # 优先用包管理器装 (官方就是这发的), 失败再手动下载
        if apt-get install -y proxmox-archive-keyring >/dev/null 2>&1 && [ -e "$key9" ]; then
            ok "归档密钥通过 apt 安装完成"
            return 0
        fi
        info "下载 Proxmox 归档密钥..."
        if wget -q --timeout=8 --tries=1 \
             "https://enterprise.proxmox.com/debian/proxmox-archive-keyring-${DEB_CODE}.gpg" \
             -O "$key9" 2>/dev/null; then
            ok "归档密钥安装完成: $key9"
            return 0
        fi
        err "密钥下载失败, 请检查网络后重试!"
        return 1
    fi
    # PVE7 传统 trusted.gpg.d
    if [ -e "$key7" ]; then ok "Proxmox 密钥已存在"; return 0; fi
    info "下载 Proxmox 发行密钥..."
    if wget -q --timeout=8 --tries=1 \
         "https://mirrors.ustc.edu.cn/proxmox/debian/proxmox-release-${DEB_CODE}.gpg" \
         -O "$key7" 2>/dev/null; then
        ok "密钥安装完成: $key7"
    else
        err "密钥下载失败, 请检查网络后重试!"
        return 1
    fi
}

# =============================================================================
#  官方源写入函数 (换源与还原共用, 内容由参数决定)
# =============================================================================

# 写 Debian 源  $1=基础URI $2=安全URI
write_debian_repos(){
    local base="$1" sec="$2" comp
    mkdir -p /etc/apt/sources.list.d "$BACKUP_DISABLED"
    case "$DEB_CODE" in
        trixie|bookworm) comp="main contrib non-free non-free-firmware" ;;
        *)               comp="main contrib non-free" ;;
    esac

    if [ "$DEB_VER" = "13" ]; then
        # Debian 13 / PVE9: 官方默认 deb822 格式, sources.list 只留注释
        [ -e /etc/apt/sources.list.d/debian.sources ] && backup_file /etc/apt/sources.list.d/debian.sources
        backup_file /etc/apt/sources.list
        mkdir -p /etc/apt/sources.list.d
        cat > /etc/apt/sources.list.d/debian.sources <<DEB822EOF
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
        printf '# 仓库定义已迁移至 debian.sources (由 %s 管理)\n' "$TOOLKIT" > /etc/apt/sources.list
    else
        # Debian 11/12: 传统一行式 sources.list
        backup_file /etc/apt/sources.list
        [ -e /etc/apt/sources.list.d/debian.sources ] && {
            backup_file /etc/apt/sources.list.d/debian.sources
            mv /etc/apt/sources.list.d/debian.sources "$BACKUP_DISABLED/debian.sources.bak"
        }
        cat > /etc/apt/sources.list <<LISTEOF
deb ${base} ${DEB_CODE} ${comp}
deb ${base} ${DEB_CODE}-updates ${comp}
deb ${sec} ${DEB_CODE}-security ${comp}
LISTEOF
    fi
    ok "Debian 源写入完成 (${DEB_CODE})"
}

# 写 PVE 仓库  $1=enterprise|nosub  $2=基础URI
write_pve_repo(){
    local kind="$1" base="$2" comp file
    mkdir -p /etc/apt/sources.list.d "$BACKUP_DISABLED"
    if [ "$kind" = "enterprise" ]; then
        comp="pve-enterprise"
        file="/etc/apt/sources.list.d/pve-enterprise"
    else
        comp="pve-no-subscription"
        file="/etc/apt/sources.list.d/pve-no-subscription"
    fi

    if [ "$PVE_VER" -ge 8 ]; then
        cat > "${file}.sources" <<PVE822EOF
Types: deb
URIs: ${base}
Suites: ${DEB_CODE}
Components: ${comp}
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
PVE822EOF
        # 清掉同名旧格式与官方无订阅文件, 避免重复定义
        [ "${file}.list" != "${file}.sources" ] && [ -e "${file}.list" ] && {
            backup_file "${file}.list"; mv "${file}.list" "$BACKUP_DISABLED/$(basename "$file").list.bak"; }
    else
        cat > "${file}.list" <<PVE7EOF
deb ${base} ${DEB_CODE} ${comp}
PVE7EOF
        [ -e "${file}.sources" ] && {
            backup_file "${file}.sources"; mv "${file}.sources" "$BACKUP_DISABLED/$(basename "$file").sources.bak"; }
    fi
    ok "PVE 仓库写入完成: $(basename "$file") (${comp})"
}

# 移除官方 PVE9 无订阅文件名(proxmox.sources)与其他脚本常见残留
clean_pve_repo_conflicts(){
    local f
    for f in /etc/apt/sources.list.d/proxmox.sources \
             /etc/apt/sources.list.d/pve-install-repo.list ; do
        if [ -e "$f" ]; then
            backup_file "$f"
            mv "$f" "$BACKUP_DISABLED/$(basename "$f").bak"
            warn "已移除冲突源文件: $(basename "$f")"
        fi
    done
}

# 写 Ceph 仓库  $1=enterprise|nosub  $2=基础URI
write_ceph_repo(){
    local kind="$1" base="$2" comp cc file
    mkdir -p /etc/apt/sources.list.d "$BACKUP_DISABLED"
    cc=$(ceph_codename)
    if [ "$kind" = "enterprise" ]; then comp="enterprise"; else comp="no-subscription"; fi
    file="/etc/apt/sources.list.d/ceph"

    if [ "$PVE_VER" -ge 8 ]; then
        cat > "${file}.sources" <<CEPH822EOF
Types: deb
URIs: ${base}/${cc}
Suites: ${DEB_CODE}
Components: ${comp}
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
CEPH822EOF
        [ -e "${file}.list" ] && {
            backup_file "${file}.list"; mv "${file}.list" "$BACKUP_DISABLED/ceph.list.bak"; }
    else
        cat > "${file}.list" <<CEPH7EOF
deb ${base}/${cc} ${DEB_CODE} ${comp}
CEPH7EOF
        [ -e "${file}.sources" ] && {
            backup_file "${file}.sources"; mv "${file}.sources" "$BACKUP_DISABLED/ceph.sources.bak"; }
    fi
    ok "Ceph 仓库写入完成: ${cc} (${comp})"
}

# 关闭企业源 (移动到备份目录, 可在还原中心找回)
disable_enterprise_repos(){
    local f p found=0
    for f in pve-enterprise.sources pve-enterprise.list ceph.sources ceph.list ; do
        p="/etc/apt/sources.list.d/$f"
        if [ -e "$p" ] && grep -qE 'enterprise' "$p" 2>/dev/null; then
            backup_file "$p"
            mkdir -p "$BACKUP_DISABLED"
            mv "$p" "$BACKUP_DISABLED/$f.bak"
            warn "已禁用企业源: $f"
            found=1
        fi
    done
    # 传统 sources.list 里若写死了企业源也一并注释
    if grep -q '^deb.*enterprise\.proxmox\.com' /etc/apt/sources.list 2>/dev/null; then
        backup_file /etc/apt/sources.list
        sed -i 's#^deb\(.*enterprise\.proxmox\.com.*\)# deb\1#' /etc/apt/sources.list
        warn "已注释 sources.list 中的企业源"
        found=1
    fi
    [ "$found" = "0" ] && info "未发现企业源, 跳过"
}

# 选择镜像站
choose_mirror(){
    while :; do
        clear
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
        read -r -t 60 -p " 请选择 [默认1]: " m || m=1
        m=${m:-1}
        case "$m" in
            1)
                MIR_DEBIAN="https://mirrors.ustc.edu.cn/debian"
                MIR_SEC="https://mirrors.ustc.edu.cn/debian-security"
                MIR_PVE="https://mirrors.ustc.edu.cn/proxmox/debian"
                MIR_CEPH_ROOT="https://mirrors.ustc.edu.cn/proxmox/debian"
                return 0 ;;
            2)
                MIR_DEBIAN="https://mirrors.tuna.tsinghua.edu.cn/debian"
                MIR_SEC="https://mirrors.tuna.tsinghua.edu.cn/debian-security"
                MIR_PVE="https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian"
                MIR_CEPH_ROOT="https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian"
                return 0 ;;
            3)
                MIR_DEBIAN="http://deb.debian.org/debian"
                MIR_SEC="http://security.debian.org/debian-security"
                MIR_PVE="http://download.proxmox.com/debian"
                MIR_CEPH_ROOT="http://download.proxmox.com/debian"
                return 0 ;;
            0) return 1 ;;
            *) ;;
        esac
    done
}

# CT 模板源 (APLInfo.pm): 把 download.proxmox.com 指到镜像
switch_ct_source(){
    local root="$1"
    [ -e "$APLINFO_PM" ] || { warn "未找到 APLInfo.pm, 跳过 CT 模板源"; return 1; }
    backup_file "$APLINFO_PM"
    sed -i "s|http://download.proxmox.com|${root}|g; s|https://download.proxmox.com|${root}|g" "$APLINFO_PM"
    info "刷新 CT 模板列表..."
    pveam update >/dev/null 2>&1 && ok "CT 模板源已切换并刷新"
}

# =============================================================================
#  一键优化
# =============================================================================
one_key_optimize(){
    clear
    title "一键优化 PVE"
    info "当前环境: PVE ${PVE_FULL:-?} (Debian ${DEB_CODE:-?})"
    choose_mirror || return 0
    mkdir -p /etc/apt/sources.list.d "$BACKUP_DISABLED"

    echo; title "1/6 更换 Debian 系统源"
    write_debian_repos "$MIR_DEBIAN" "$MIR_SEC"

    echo; title "2/6 更换 PVE 无订阅源"
    clean_pve_repo_conflicts
    write_pve_repo nosub "$MIR_PVE"

    if confirm "是否同时更换 Ceph 源为 no-subscription? (不用 Ceph 可选 n)"; then
        echo; title "3/6 更换 Ceph 源"
        write_ceph_repo nosub "$MIR_CEPH_ROOT"
    fi

    echo; title "4/6 关闭企业源"
    disable_enterprise_repos

    echo; title "5/6 保障 PVE 密钥"
    ensure_pve_keyring

    echo; title "6/6 更换 CT 模板源"
    case "$MIR_PVE" in
        *ustc*)  switch_ct_source "https://mirrors.ustc.edu.cn/proxmox" ;;
        *tuna*)  switch_ct_source "https://mirrors.tuna.tsinghua.edu.cn/proxmox" ;;
        *)       switch_ct_source "http://download.proxmox.com" ;;
    esac

    echo; title "移除订阅弹窗"
    remove_nag

    echo
    ok "一键优化完成! 原文件备份于 $BACKUP_FILES"
    info "更新系统请手动执行(脚本不自动升级, 避免打断生产环境):"
    info "  apt-get update && apt-get dist-upgrade -y"
    log "one-key optimize done"
}

# 手动换源菜单
source_menu(){
    choose_mirror || return 0
    clear
    title "软件源管理"
    local act
    read -r -t 60 -p " 1.只换Debian源 2.只换PVE源 3.只换Ceph源 4.只换CT模板源 5.关闭企业源 [默认1]: " act || act=1
    act=${act:-1}
    case "$act" in
        1) write_debian_repos "$MIR_DEBIAN" "$MIR_SEC" ;;
        2) clean_pve_repo_conflicts; write_pve_repo nosub "$MIR_PVE" ;;
        3) write_ceph_repo nosub "$MIR_CEPH_ROOT" ;;
        4) case "$MIR_PVE" in
               *ustc*) switch_ct_source "https://mirrors.ustc.edu.cn/proxmox" ;;
               *tuna*) switch_ct_source "https://mirrors.tuna.tsinghua.edu.cn/proxmox" ;;
               *)      switch_ct_source "http://download.proxmox.com" ;;
           esac ;;
        5) disable_enterprise_repos ;;
    esac
    if confirm "立即执行 apt-get update 验证?"; then
        apt-get update && ok "apt 源工作正常!" || err "apt update 失败, 请查看上方报错"
    fi
}

# =============================================================================
#  订阅弹窗
# =============================================================================
remove_nag(){
    [ -e "$PROXMOXLIB_JS" ] || { err "未找到 proxmoxlib.js"; return 1; }
    if grep -q 'if(false)' "$PROXMOXLIB_JS"; then
        ok "订阅弹窗此前已移除, 跳过"
        return 0
    fi
    backup_file "$PROXMOXLIB_JS"
    info "正在移除无有效订阅弹窗..."
    sed -r -i "/\/nodes\/localhost\/subscription/,+30 {
        /^\s+if\s*\(/ {
            :loop
            N
            /\s*\)\s*\{/!b loop
            s/(if\s*\([[:space:]]*res\s*===\s*null\s*(\|\|\s*res\s*===\s*undefined\s*)?(\|\|\s*!res\s*)?(\|\|\s*res\.data\.status\.toLowerCase\(\)\s*!==\s*['\'']active['\'']\s*)?[[:space:]]*\)\s*\{)/if(false){/
        }
    }" "$PROXMOXLIB_JS"
    if grep -q 'if(false)' "$PROXMOXLIB_JS"; then
        ok "订阅弹窗已移除 (兼容多种代码形态)"
    else
        warn "自动替换未命中, 可能是未见过的新版布局; 原文件未损坏。"
        warn "可在还原中心执行『官方包重装』后重试, 或手动修改。"
    fi
    restart_pve_web
}

restore_nag(){
    info "重装 proxmox-widget-toolkit 以还原订阅弹窗..."
    apt-get install --reinstall -y proxmox-widget-toolkit \
        && ok "已还原为官方原版" || err "重装失败, 请先修复软件源(还原中心选项1)"
    restart_pve_web
}

# =============================================================================
#  硬件直通
# =============================================================================
pt_status(){
    title "硬件直通状态"
    if dmesg 2>/dev/null | grep -qE 'DMAR|IOMMU'; then
        ok "IOMMU 已在内核中启用"
        dmesg 2>/dev/null | grep -E 'DMAR|IOMMU' | head -n 3 | sed 's/^/    /'
    else
        warn "dmesg 中未发现 IOMMU 信息 (硬件不支持或未开启 BIOS VT-d/AMD-Vi)"
    fi
    local n
    n=$(find /sys/kernel/iommu_groups -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    if [ "${n:-0}" -gt 0 ]; then
        ok "检测到 ${n} 个 IOMMU 分组"
    else
        warn "未检测到 IOMMU 分组"
    fi
    grep -q '^vfio$' /etc/modules 2>/dev/null \
        && ok "vfio 模块已配置开机加载" || warn "vfio 模块未配置"
}

pt_enable(){
    clear
    title "开启硬件直通"
    if ! dmesg 2>/dev/null | grep -qE 'DMAR|IOMMU'; then
        err "BIOS 未开启 VT-d / AMD-Vi (或硬件不支持), 请先到 BIOS 开启!"
        return 1
    fi
    local params
    if grep -q 'GenuineIntel' /proc/cpuinfo; then
        params="intel_iommu=on iommu=pt"
        info "检测到 Intel 平台: 使用 intel_iommu=on iommu=pt"
    else
        params="iommu=pt"
        info "检测到 AMD 平台: AMD IOMMU 默认开启, 追加 iommu=pt"
    fi

    backup_file /etc/default/grub
    if grep -qE '(intel_iommu=on|iommu=pt)' /etc/default/grub; then
        warn "GRUB 已含直通参数, 跳过"
    else
        sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1 ${params}\"/" /etc/default/grub
        update-grub >/dev/null 2>&1
        ok "GRUB 内核参数已追加"
    fi

    info "写入 vfio 内核模块 (/etc/modules)..."
    local m
    for m in vfio vfio_iommu_type1 vfio_pci vfio_virqfd; do
        grep -q "^${m}$" /etc/modules || echo "$m" >> /etc/modules
    done
    ok "完成"

    if confirm "是否屏蔽声卡/核显驱动(blacklist, 核显完整直通需要)?"; then
        cat > /etc/modprobe.d/pve-blacklist.conf <<BLEOF
blacklist snd_hda_intel
blacklist snd_hda_codec_hdmi
blacklist i915
blacklist amdgpu
BLEOF
        ok "已写入 /etc/modprobe.d/pve-blacklist.conf"
    fi

    info "参考 - 本机 PCI 设备 (VGA):"
    lspci -nn 2>/dev/null | grep -i vga | sed 's/^/    /'
    local ids
    ids=$(ask "要绑定到 vfio-pci 的设备ID (形如 8086:1234, 多个逗号分隔; 留空跳过)")
    if [ -n "$ids" ]; then
        echo "options vfio-pci ids=${ids}" > /etc/modprobe.d/vfio.conf
        ok "已写入 /etc/modprobe.d/vfio.conf"
    else
        echo "# options vfio-pci ids=XXXX:YYYY" > /etc/modprobe.d/vfio.conf
        info "未填写设备ID, 已生成空白模板 /etc/modprobe.d/vfio.conf"
    fi

    update-initramfs -u >/dev/null 2>&1
    ok "initramfs 已更新, 请重启系统生效!"
    log "passthrough enabled"
}

pt_disable(){
    clear
    title "关闭硬件直通"
    backup_file /etc/default/grub
    sed -i 's/ intel_iommu=on//g; s/ iommu=pt//g' /etc/default/grub
    update-grub >/dev/null 2>&1
    ok "GRUB 内核参数已移除"
    sed -i '/^vfio$/d; /^vfio_iommu_type1$/d; /^vfio_pci$/d; /^vfio_virqfd$/d; /^kvmgt$/d' /etc/modules
    ok "已清理 /etc/modules 中的 vfio 相关行"
    if [ -e /etc/modprobe.d/pve-blacklist.conf ] && confirm "删除驱动屏蔽列表 pve-blacklist.conf?"; then
        rm -f /etc/modprobe.d/pve-blacklist.conf
    fi
    if [ -e /etc/modprobe.d/vfio.conf ] && confirm "删除 vfio.conf?"; then
        rm -f /etc/modprobe.d/vfio.conf
    fi
    update-initramfs -u >/dev/null 2>&1
    ok "initramfs 已更新, 请重启系统生效!"
    log "passthrough disabled"
}

passthrough_menu(){
    while :; do
        clear
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
        read -r -t 60 -p " 请选择 [默认0]: " c || c=0
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

gov_set(){
    echo "${GOVERNOR}" | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null 2>&1
    local cur
    cur=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
    ok "当前 CPU 模式: ${cur}"

    cat > /etc/systemd/system/pve-governor.service <<UNIT
[Unit]
Description=Set CPU governor to ${GOVERNOR} (${TOOLKIT})
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo ${GOVERNOR} | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null'

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable pve-governor.service >/dev/null 2>&1
    ok "已创建开机自持服务 pve-governor.service (重启后依然生效)"
    log "governor set to ${GOVERNOR}"
}

gov_restore(){
    systemctl disable --now pve-governor.service >/dev/null 2>&1
    rm -f /etc/systemd/system/pve-governor.service
    systemctl daemon-reload
    echo "performance" | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null 2>&1
    # 顺带清理其他脚本常写的 @reboot cron 残留
    if crontab -l 2>/dev/null | grep -q 'CPU Power Mode'; then
        crontab -l 2>/dev/null | grep -v '@reboot.*CPU Power Mode' | crontab -
        warn "已清理其他脚本遗留的 @reboot 电源模式计划任务"
    fi
    ok "已恢复 performance 并移除自持服务"
}

cpu_power_menu(){
    local governors
    governors=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null)
    [ -n "$governors" ] || { err "本机 CPU 无可切换的 governor (可能是 intel_pstate/intel_amx 或虚拟机)"; pause; return 0; }
    while :; do
        clear
        cat <<MENUEOF

   ${C_Y}设置 CPU 电源模式${C_N}
   ------------------------------------------------
    1. conservative (保守)     2. ondemand (按需)
    3. powersave (节能)        4. performance (性能)
    5. schedutil (负载)

    6. 恢复系统默认 (performance 并移除自持服务)
    0. 返回
   ------------------------------------------------
    部分新型 CPU 走 intel_pstate/amd-pstate 驱动, 仅 performance/powersave,
    属正常现象, 响应更智能。
    本机支持: ${governors}
MENUEOF
        local c
        read -r -t 60 -p " 请选择 [默认0]: " c || c=0
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

# --- Perl 片段(静态部分): 写入 Nodes.pm, 每次 API 调用时采集数据 ---
build_perl_static(){
    cat <<PERLEOF
# ${TOOLKIT}
        \$res->{thermalstate} = \`sensors\`;
        \$res->{cpusensors} = \`cat /proc/cpuinfo | grep MHz && lscpu | grep MHz\`;

        \$res->{hdd_temperatures} = \`for disk in /dev/sd[a-z] /dev/sd[a-z][a-z]; do if [ -b \\\$disk ]; then echo "===\\\$disk==="; smartctl -a \\\$disk; fi; done | grep -E "===|Device Model|Model Family|User Capacity|Power_On_Hours|Temperature"\`;

        my \$powermode = \`cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor && turbostat -S -q -s PkgWatt -i 0.1 -n 1 -c package | grep -v PkgWatt\`;
        \$res->{cpupower} = \$powermode;

PERLEOF
}

# --- Perl 片段(NVMe 模板): @NV@=序号 @DEV@=设备路径 @DEVB@=iostat名 ---
build_perl_nvme(){
    cat <<NVPMEOF
        my \$nvme@NV@_temperatures = \`smartctl -a @DEV@ | grep -E "Model Number|(?=Total|Namespace)[^:]+Capacity|Temperature:|Available Spare:|Percentage|Data Unit|Power Cycles|Power On Hours|Unsafe Shutdowns|Integrity Errors"\`;
        my \$nvme@NV@_io = \`iostat -d -x -k 1 1 | grep -E "^@DEVB@"\`;
        \$res->{nvme@NV@_status} = \$nvme@NV@_temperatures . \$nvme@NV@_io;

NVPMEOF
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
                  const w0 = value.split('\n')[0].split(' ')[0];
                  const w1 = value.split('\n')[1] ? value.split('\n')[1].split(' ')[0] : '';
                  return `CPU电源模式: <strong>${w0}</strong> | CPU功耗: <strong>${w1} W</strong> `
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
                    value = value.replace(/Â/g, '');
                    let data = [];
                    let nvmeNumber = -1;
                    let nvmes = value.matchAll(/(^(?:Model|Total|Temperature:|Available Spare:|Percentage|Data|Power|Unsafe|Integrity Errors|nvme)[\s\S]*)+/gm);
                    for (const nvme of nvmes) {
                        if (/Model Number:/.test(nvme[1])) {
                            nvmeNumber++;
                            data[nvmeNumber] = {
                                Models: [], Integrity_Errors: [], Capacitys: [], Temperatures: [],
                                Available_Spares: [], Useds: [], Reads: [], Writtens: [],
                                Cycles: [], Hours: [], Shutdowns: [], States: [],
                                r_kBs: [], r_awaits: [], w_kBs: [], w_awaits: [], utils: []
                            };
                        }
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
                            output += `<strong>${nv.Models[0]}</strong>`;
                            if (nv.Integrity_Errors.length > 0) {
                                for (const ie of nv.Integrity_Errors) {
                                    if (ie != 0) {
                                        output += `(`;
                                        output += `0E: ${ie}-故障！`;
                                        if (nv.Available_Spares.length > 0) {
                                            output += ', ';
                                            for (const as of nv.Available_Spares) { output += `备用空间: ${as}`; }
                                        }
                                        output += `)`;
                                    }
                                }
                            }
                            output += '<br>';
                        }
                        if (nv.Capacitys.length > 0) {
                            for (const cap of nv.Capacitys) { output += `容量: ${cap.replace(/ |,/gm, '')}`; }
                        }
                        if (nv.Useds.length > 0) {
                            output += ' | ';
                            for (const used of nv.Useds) {
                                output += `寿命: <strong>${100-Number(used)}%</strong>`;
                                if (nv.Reads.length > 0) {
                                    output += '(';
                                    for (const rd of nv.Reads) { output += `已读${rd.replace(/ |,/gm, '')}`; output += ')'; }
                                }
                                if (nv.Writtens.length > 0) {
                                    output = output.slice(0, -1);
                                    output += ', ';
                                    for (const wr of nv.Writtens) { output += `已写${wr.replace(/ |,/gm, '')}`; }
                                    output += ')';
                                }
                            }
                        }
                        if (nv.Temperatures.length > 0) {
                            output += ' | ';
                            for (const tp of nv.Temperatures) { output += `温度: <strong>${tp}°C</strong>`; }
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
                            for (const cy of nv.Cycles) { output += `通电: ${cy.replace(/ |,/gm, '')}次`; }
                            if (nv.Shutdowns.length > 0) {
                                output += ', ';
                                for (const sd of nv.Shutdowns) { output += `不安全断电${sd.replace(/ |,/gm, '')}次`; break; }
                            }
                            if (nv.Hours.length > 0) {
                                output += ', ';
                                for (const hr of nv.Hours) { output += `累计${hr.replace(/ |,/gm, '')}小时`; }
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
                    var info = "<strong>[" + devName.toUpperCase() + "] " + model + "</strong><br>";
                    info += "容量: " + (capacity || '未知');
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
display_install_deps(){
    info "刷新软件源并安装依赖..."
    apt-get update -qq
    local packages=(lm-sensors nvme-cli sysstat linux-cpupower smartmontools)
    local missing=0 p
    for p in "${packages[@]}"; do
        dpkg -s "$p" >/dev/null 2>&1 || { missing=1; break; }
    done
    if [ "$missing" = "1" ]; then
        apt-get install -y "${packages[@]}" >/dev/null || apt-get install -y "${packages[@]}"
    fi
    ok "依赖就绪"

    # turbostat 需要 msr 模块
    modprobe msr 2>/dev/null
    echo "msr" > /etc/modules-load.d/turbostat-msr.conf

    # 给 Web 端(www-data)调用铺路
    local b
    for b in /usr/sbin/nvme /usr/sbin/smartctl /usr/sbin/turbostat; do
        [ -e "$b" ] && chmod +s "$b" 2>/dev/null
    done
    [ -e /usr/sbin/linux-cpupower ] && chmod +s /usr/sbin/linux-cpupower 2>/dev/null

    # sensors-detect 自动探测芯片驱动并持久化
    info "探测传感器驱动..."
    local drivers drv
    drivers=$(sensors-detect --auto 2>/dev/null | sed -n '/Chip drivers/,/cut here/p' | sed '/Chip /d; /cut/d')
    if [ -n "$drivers" ]; then
        for drv in $drivers; do
            modprobe "$drv" 2>/dev/null
            grep -q "^${drv}$" /etc/modules || echo "$drv" >> /etc/modules
        done
        ok "传感器驱动已加载: $(echo $drivers | tr '\n' ' ')"
    else
        warn "未探测到传感器驱动 (虚拟机/部分整机), 温度可能无法显示"
    fi
}

display_apply(){
    clear
    title "添加 CPU/硬盘 信息显示"
    [ -e "$NODES_PM" ] && [ -e "$PVE_MANAGER_JS" ] || {
        err "未找到 Nodes.pm / pvemanagerlib.js, 请确认 PVE 已完整安装"; pause; return 1; }

    if grep -q "$TOOLKIT" "$NODES_PM" || grep -q "$TOOLKIT" "$PVE_MANAGER_JS"; then
        warn "检测到已添加过信息显示!"
        if confirm "先还原官方文件再重新添加? (推荐)"; then
            display_remove quiet || return 1
        else
            return 1
        fi
    fi

    display_install_deps

    echo; info "备份系统文件 (按版本标记)..."
    backup_file "$NODES_PM"
    backup_file "$PVE_MANAGER_JS"

    # ---- 生成并插入 Nodes.pm 片段 ----
    local tmpf
    tmpf=$(mktemp)
    {
        build_perl_static
        # 动态探测所有 NVMe 控制器, 不限数量
        local devc idx devbase
        for devc in /dev/nvme?; do
            [ -e "$devc" ] || continue
            idx=$(basename "$devc" | sed 's/^nvme//')
            devbase=$(basename "$devc")
            ok "检测到 NVMe 控制器: $devc"
            build_perl_nvme | sed "s/@NV@/${idx}/g; s/@DEV@/${devc}/g; s/@DEVB@/${devbase}/g"
        done
    } > "$tmpf"

    local ln
    ln=$(sed -n -e '/PVE::pvecfg::version_text/=' "$NODES_PM" | head -n1)
    [ -n "$ln" ] || { err "Nodes.pm 插入点定位失败, 已中止 (文件未改动)"; rm -f "$tmpf"; return 1; }
    ln=$((ln + 1))
    sed -i "${ln}r ${tmpf}" "$NODES_PM"
    rm -f "$tmpf"

    # Perl 语法校验, 失败立即回滚
    if ! perl -c "$NODES_PM" >/dev/null 2>&1; then
        err "Nodes.pm 语法校验失败, 已自动回滚!"
        cp -a "${BACKUP_FILES}${NODES_PM}" "$NODES_PM"
        return 1
    fi
    ok "Nodes.pm 修改完成 (perl -c 校验通过)"

    # ---- 生成并插入 pvemanagerlib.js 片段 ----
    tmpf=$(mktemp)
    {
        build_js_part1
        local devc idx
        for devc in /dev/nvme?; do
            [ -e "$devc" ] || continue
            idx=$(basename "$devc" | sed 's/^nvme//')
            ok "添加 NVMe 面板: $devc"
            build_js_nvme | sed "s/@NV@/${idx}/g"
        done
        build_js_part2
    } > "$tmpf"

    ln=$(sed -n '/pveversion/,+10{/},/{=;q}}' "$PVE_MANAGER_JS" | head -n1)
    [ -n "$ln" ] || { err "pvemanagerlib.js 插入点定位失败, 已中止"; rm -f "$tmpf"; return 1; }
    sed -i "${ln}r ${tmpf}" "$PVE_MANAGER_JS"
    rm -f "$tmpf"
    ok "pvemanagerlib.js 修改完成"

    # ---- 面板高度自适应: height -> minHeight, 内容多高面板多高 ----
    if ! grep -q 'minHeight: 350' "$PVE_MANAGER_JS"; then
        sed -i -r '/widget\.pveNodeStatus/,+5{s/^([[:space:]]*)height:[[:space:]]*[0-9]+,/\1minHeight: 350,/}' "$PVE_MANAGER_JS"
        ok "节点状态面板已改为自适应高度 (minHeight: 350)"
    fi
    # 摘要字段右对齐, 视觉更整齐
    ln=$(sed -n -e '/widget.pveDcGuests/=' "$PVE_MANAGER_JS")
    [ -n "$ln" ] && sed -i "$((ln + 10))a\\ textAlign: 'right'," "$PVE_MANAGER_JS"
    ln=$(sed -n -e '/widget.pveNodeStatus/=' "$PVE_MANAGER_JS")
    [ -n "$ln" ] && sed -i "$((ln + 10))a\\ textAlign: 'right'," "$PVE_MANAGER_JS"

    systemctl restart pveproxy pvedaemon >/dev/null 2>&1
    ok "全部完成! 刷新浏览器 (Ctrl+Shift+R) 即可看到效果"
    log "display mod applied"
    pause
}

display_remove(){
    # $1 = quiet (由重装流程调用时不弹确认)
    local had=0
    if grep -q "$TOOLKIT" "$NODES_PM" 2>/dev/null || grep -q "$TOOLKIT" "$PVE_MANAGER_JS" 2>/dev/null; then
        had=1
    fi
    if [ "$had" = "0" ]; then
        [ "$1" = "quiet" ] || ok "未添加过信息显示, 无需移除"
        return 0
    fi
    if restore_latest "$NODES_PM" && restore_latest "$PVE_MANAGER_JS"; then
        systemctl restart pveproxy pvedaemon >/dev/null 2>&1
        ok "已从备份还原信息显示相关文件"
    else
        warn "没有可用备份, 改用官方包重装还原..."
        apt-get install --reinstall -y pve-manager >/dev/null 2>&1 \
            && ok "pve-manager 已重装还原" || err "重装失败, 请检查软件源"
        systemctl restart pveproxy pvedaemon >/dev/null 2>&1
    fi
    log "display mod removed"
    [ "$1" = "quiet" ] || pause
    return 0
}

# =============================================================================
#  Ceph 管理
# =============================================================================
ceph_menu(){
    clear
    title "Ceph 管理"
    local act
    read -r -t 60 -p " 1.添加Ceph no-subscription源 2.一键卸载Ceph [默认1]: " act || act=1
    act=${act:-1}
    case "$act" in
        1)
            choose_mirror || return 0
            write_ceph_repo nosub "$MIR_CEPH_ROOT"
            sed -i "s|http://download.proxmox.com|$(dirname "$MIR_CEPH_ROOT")|g" "$PVECEPH_PM" 2>/dev/null
            apt-get update
            ;;
        2)
            warn "将彻底卸载 Ceph 并删除所有 Ceph 数据/配置, 不可恢复!"
            confirm "确认卸载 Ceph?" || return 0
            systemctl stop ceph-mon.target ceph-mgr.target ceph-mds.target ceph-osd.target 2>/dev/null
            rm -rf /etc/systemd/system/ceph* 2>/dev/null
            command -v killall >/dev/null 2>&1 && killall -9 ceph-mon ceph-mgr ceph-mds ceph-osd 2>/dev/null
            rm -rf /var/lib/ceph 2>/dev/null
            pveceph purge 2>/dev/null
            apt-get purge -y ceph-mon ceph-osd ceph-mgr ceph-mds ceph-base ceph-mgr-modules-core 2>/dev/null
            rm -rf /etc/ceph /etc/pve/ceph.conf /etc/pve/priv/ceph.* /var/log/ceph /etc/pve/ceph 2>/dev/null
            if [ -e /etc/apt/sources.list.d/ceph.sources ]; then
                backup_file /etc/apt/sources.list.d/ceph.sources
                mv /etc/apt/sources.list.d/ceph.sources "$BACKUP_DISABLED/ceph.sources.bak"
            fi
            [ -e /etc/apt/sources.list.d/ceph.list ] && {
                backup_file /etc/apt/sources.list.d/ceph.list
                mv /etc/apt/sources.list.d/ceph.list "$BACKUP_DISABLED/ceph.list.bak"
            }
            ok "Ceph 已卸载"
            log "ceph removed"
            ;;
    esac
    pause
}

# =============================================================================
#  旧内核清理
# =============================================================================
remove_old_kernels(){
    clear
    title "清理旧内核"
    warn "此操作有一定风险: 请确保当前内核运行正常, 且保留至少一个备用内核!"
    local current available
    current=$(uname -r)
    available=$(dpkg --list 2>/dev/null | awk '/^ii/{print $2}' \
        | grep -E '^pve-kernel-[0-9]+(\.[0-9]+)*-[0-9]+-pve$' \
        | grep -v "^${current}$" | sort -V)
    if [ -z "$available" ]; then
        ok "未检测到可清理的旧内核 (当前: ${current})"
        pause
        return 0
    fi
    info "当前运行内核: ${current}"
    info "可清理的旧内核:"
    echo "$available" | nl -w 3 -s '. ' | sed 's/^/    /'
    local selected
    read -r -p " 输入要删除的序号(逗号分隔, 如 1,2; 直接回车取消): " selected
    [ -n "$selected" ] || { info "已取消"; pause; return 0; }

    local kernels=() idx k
    IFS=',' read -r -a idxlist <<< "$selected"
    for idx in "${idxlist[@]}"; do
        k=$(echo "$available" | sed -n "${idx//[[:space:]]/}p")
        [ -n "$k" ] && kernels+=("$k")
    done
    [ ${#kernels[@]} -gt 0 ] || { warn "无有效选择, 已取消"; pause; return 0; }

    echo "待删除内核:"
    printf '    %s\n' "${kernels[@]}"
    confirm "确认删除以上内核?" || { info "已取消"; pause; return 0; }

    local k2
    for k2 in "${kernels[@]}"; do
        if apt-get purge -y "$k2" >/dev/null 2>&1; then
            ok "已删除: $k2"
        else
            err "删除失败(依赖问题?): $k2"
        fi
    done
    apt-get autoremove -y >/dev/null 2>&1
    update-grub >/dev/null 2>&1
    command -v proxmox-boot-tool >/dev/null 2>&1 && proxmox-boot-tool refresh >/dev/null 2>&1
    ok "清理完成, GRUB 已更新"
    log "old kernels removed: ${kernels[*]}"
    pause
}

# =============================================================================
#  还原中心  ★
# =============================================================================

# 1) 官方源还原: 严格按 Proxmox 官方 Wiki 重建全部源文件
restore_official_sources(){
    clear
    title "官方软件源还原"
    info "适用场景: 之前跑过来路不明的脚本, 源文件被改乱/删除, 想回到官方原版。"
    echo
    info "将重建: Debian源 + PVE仓库 + Ceph仓库 (官方原始内容)"
    info "PVE9  使用 deb822 格式: pve-enterprise.sources / proxmox.sources / ceph.sources"
    info "PVE7/8 使用传统格式: pve-enterprise.list / pve-no-subscription.list / ceph.list"
    echo
    confirm "开始还原官方源?" || return 0

    local kind
    read -r -t 60 -p " PVE 仓库用哪种? 1.企业源(官方默认,需订阅) 2.无订阅源(社区版) [默认2]: " kind || kind=2
    kind=${kind:-2}
    local cephkind
    read -r -t 60 -p " Ceph 仓库用哪种? 1.企业源(官方默认) 2.no-subscription [默认2]: " cephkind || cephkind=2
    cephkind=${cephkind:-2}

    mkdir -p /etc/apt/sources.list.d "$BACKUP_DISABLED"

    echo; info "[1/5] 重建 Debian 官方源..."
    write_debian_repos "http://deb.debian.org/debian" "http://security.debian.org/debian-security"

    echo; info "[2/5] 重建 PVE 官方仓库..."
    if [ "$kind" = "1" ]; then
        write_pve_repo enterprise "https://enterprise.proxmox.com/debian/pve"
        # 企业源模式下, 无订阅源全部清走 (官方默认状态)
        local f
        for f in /etc/apt/sources.list.d/pve-no-subscription.list \
                 /etc/apt/sources.list.d/pve-no-subscription.sources \
                 /etc/apt/sources.list.d/proxmox.sources ; do
            [ -e "$f" ] && { backup_file "$f"; mv "$f" "$BACKUP_DISABLED/$(basename "$f").bak"; warn "已移除无订阅源: $(basename "$f")"; }
        done
    else
        clean_pve_repo_conflicts
        if [ "$PVE_VER" = "9" ]; then
            # PVE9 官方无订阅源文件名为 proxmox.sources
            cat > /etc/apt/sources.list.d/proxmox.sources <<OFFNOSUB
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: ${DEB_CODE}
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
OFFNOSUB
            ok "官方无订阅源写入完成: proxmox.sources"
        else
            write_pve_repo nosub "http://download.proxmox.com/debian/pve"
        fi
    fi

    echo; info "[3/5] 重建 Ceph 官方仓库..."
    if [ "$cephkind" = "1" ]; then
        write_ceph_repo enterprise "https://enterprise.proxmox.com/debian"
    else
        write_ceph_repo nosub "http://download.proxmox.com/debian"
    fi

    echo; info "[4/5] 保障 PVE 密钥..."
    ensure_pve_keyring

    echo; info "[5/5] 验证软件源..."
    if apt-get update; then
        ok "官方源还原成功, apt 工作正常!"
    else
        err "apt update 仍失败, 请把上方报错截图反馈"
    fi
    log "official sources restored"
}

# 2) 官方包重装: 一步还原所有被改的系统文件
restore_system_files(){
    clear
    title "官方包重装还原系统文件"
    info "pve-manager 包含: Nodes.pm / pvemanagerlib.js / APLInfo.pm / pveceph.pm"
    info "proxmox-widget-toolkit 包含: proxmoxlib.js (订阅弹窗)"
    info "重装 = 官方原版文件直接覆盖, 比 sed 修补可靠 100%"
    confirm "重装 pve-manager + proxmox-widget-toolkit?" || return 0
    info "刷新源..."
    apt-get update
    if apt-get install --reinstall -y pve-manager proxmox-widget-toolkit; then
        ok "系统文件已还原为官方原版!"
        systemctl restart pveproxy pvedaemon >/dev/null 2>&1
        info "提示: 温度显示等功能也被还原, 需要的话请重新执行添加。"
    else
        err "重装失败! 多半是软件源仍是坏的, 请先执行『官方源还原』"
    fi
    log "system files restored via reinstall"
    pause
}

# 3) 从本脚本备份回滚
restore_from_backup(){
    clear
    title "从本脚本备份回滚"
    if [ ! -e "$MANIFEST" ]; then
        info "本脚本还没有做过任何修改, 无备份可回滚。"
        pause
        return 0
    fi
    echo " 备份记录 (每条取最新一份):"
    awk -F'|' '{print $2}' "$MANIFEST" | sort -u | nl -w 3 -s '. ' | sed 's/^/    /'
    echo
    info "输入要回滚的序号(逗号分隔), 或 a=全部回滚, 直接回车取消:"
    local sel
    read -r -p " > " sel
    [ -n "$sel" ] || { info "已取消"; pause; return 0; }

    local files
    files=$(awk -F'|' '{print $2}' "$MANIFEST" | sort -u)
    if [ "$sel" = "a" ]; then
        local f
        while IFS= read -r f; do restore_latest "$f"; done <<< "$files"
    else
        local idxlist idx f2
        IFS=',' read -r -a idxlist <<< "$sel"
        for idx in "${idxlist[@]}"; do
            f2=$(echo "$files" | sed -n "${idx//[[:space:]]/}p")
            [ -n "$f2" ] && restore_latest "$f2"
        done
    fi
    restart_pve_web
    log "restored from backup: $sel"
    pause
}

# 4) 清理常见脚本残留
cleanup_leftovers(){
    clear
    title "清理常见脚本残留"
    local found=0

    # 其他脚本爱写的 @reboot 电源模式 cron
    if crontab -l 2>/dev/null | grep -q 'CPU Power Mode'; then
        crontab -l 2>/dev/null | grep -v '@reboot.*CPU Power Mode' | crontab -
        warn "已清理 @reboot CPU电源模式计划任务"
        found=1
    fi
    # 本脚本及同类脚本写入的模块
    if [ -e /etc/modules-load.d/turbostat-msr.conf ] && confirm "删除 /etc/modules-load.d/turbostat-msr.conf? (turbostat 功耗显示依赖它)"; then
        rm -f /etc/modules-load.d/turbostat-msr.conf; found=1
    fi
    if grep -qE '^(vfio|kvmgt)$' /etc/modules && confirm "从 /etc/modules 移除 vfio/kvmgt 直通模块?"; then
        sed -i '/^vfio$/d; /^vfio_iommu_type1$/d; /^vfio_pci$/d; /^vfio_virqfd$/d; /^kvmgt$/d' /etc/modules
        warn "已移除直通模块配置"
        found=1
    fi
    if [ -e /etc/modprobe.d/pve-blacklist.conf ] && confirm "删除 /etc/modprobe.d/pve-blacklist.conf (驱动屏蔽)?"; then
        rm -f /etc/modprobe.d/pve-blacklist.conf; found=1
    fi
    if [ -e /etc/modprobe.d/vfio.conf ] && confirm "删除 /etc/modprobe.d/vfio.conf (设备绑定)?"; then
        rm -f /etc/modprobe.d/vfio.conf; found=1
    fi
    if [ -e /etc/systemd/system/pve-governor.service ] && confirm "移除 CPU 电源模式自持服务?"; then
        systemctl disable --now pve-governor.service >/dev/null 2>&1
        rm -f /etc/systemd/system/pve-governor.service
        systemctl daemon-reload
        found=1
    fi

    [ "$found" = "0" ] && ok "未发现常见残留, 系统很干净!"
    log "leftovers cleaned"
    pause
}

restore_menu(){
    while :; do
        clear
        cat <<MENUEOF

   ${C_R}还原中心${C_N}  —— 修复被各种脚本改坏的 PVE
   ------------------------------------------------
    1. 官方软件源还原 (按官方Wiki重建全部源, 最常用)
    2. 官方包重装还原系统文件 (订阅弹窗/温度显示等全部还原)
    3. 从本脚本的备份回滚单个/全部文件
    4. 清理常见脚本残留 (cron/直通/governor等)
    0. 返回
   ------------------------------------------------
   ${C_Y}推荐顺序: 先 1 修好源, 再 2 还原系统文件${C_N}
MENUEOF
        local c
        read -r -t 60 -p " 请选择 [默认0]: " c || c=0
        c=${c:-0}
        case "$c" in
            1) restore_official_sources; pause ;;
            2) restore_system_files ;;
            3) restore_from_backup ;;
            4) cleanup_leftovers ;;
            0) return 0 ;;
            *) ;;
        esac
    done
}

# =============================================================================
#  系统体检
# =============================================================================
health_check(){
    clear
    title "PVE 系统体检"
    info "环境: PVE ${PVE_FULL:-?} | Debian ${DEB_CODE:-?} | 内核 $(uname -r)"

    echo; title "软件源状态"
    local f active=()
    for f in /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/pve-enterprise.list; do
        [ -e "$f" ] && active+=("PVE企业源($(basename $f))")
    done
    for f in /etc/apt/sources.list.d/proxmox.sources /etc/apt/sources.list.d/pve-no-subscription.sources /etc/apt/sources.list.d/pve-no-subscription.list; do
        [ -e "$f" ] && active+=("PVE无订阅源($(basename $f))")
    done
    for f in /etc/apt/sources.list.d/ceph.sources /etc/apt/sources.list.d/ceph.list; do
        [ -e "$f" ] && active+=("Ceph源($(basename $f))")
    done
    if [ ${#active[@]} -gt 0 ]; then
        info "已配置: ${active[*]}"
        local ent=0 nos=0 ceph_e=0 ceph_n=0
        grep -qsE 'enterprise' /etc/apt/sources.list.d/pve-enterprise.* 2>/dev/null && ent=1
        grep -qsE 'no-subscription' /etc/apt/sources.list.d/pve-no-subscription.* /etc/apt/sources.list.d/proxmox.sources 2>/dev/null && nos=1
        grep -qsE 'enterprise' /etc/apt/sources.list.d/ceph.* 2>/dev/null && ceph_e=1
        grep -qsE 'no-subscription' /etc/apt/sources.list.d/ceph.* 2>/dev/null && ceph_n=1
        [ $ent -eq 1 ] && [ $nos -eq 1 ] && warn "PVE 企业源与无订阅源同时启用 (会有重复更新提示, 建议二选一)"
        [ $ceph_e -eq 1 ] && [ $ceph_n -eq 1 ] && warn "Ceph 企业源与 no-subscription 同时启用"
        [ $ent -eq 0 ] && [ $nos -eq 0 ] && warn "未发现任何已启用的 PVE 仓库! (apt 将无法升级 PVE)"
    else
        warn "sources.list.d 中未发现 PVE/Ceph 源, 检查 /etc/apt/sources.list"
    fi
    # Debian 源重复定义检测
    if grep -qs '^deb ' /etc/apt/sources.list && [ -e /etc/apt/sources.list.d/debian.sources ]; then
        warn "sources.list 与 debian.sources 同时定义了 Debian 源 (重复)"
    fi

    echo; title "系统文件完整性 (dpkg 校验)"
    local out
    out=$(dpkg -V pve-manager proxmox-widget-toolkit 2>/dev/null)
    if [ -z "$out" ]; then
        ok "pve-manager / proxmox-widget-toolkit 与官方一致, 未被修改"
    else
        warn "以下系统文件与官方版本不一致:"
        echo "$out" | sed 's/^/    /'
        info "(若添加过温度显示/去订阅, 出现上述记录属正常; 想还原用『官方包重装』)"
    fi

    echo; title "订阅弹窗"
    if grep -q 'void({' "$PROXMOXLIB_JS" 2>/dev/null || grep -q 'if(false)' "$PROXMOXLIB_JS" 2>/dev/null; then
        info "订阅弹窗: 已移除"
    else
        info "订阅弹窗: 官方原版 (未移除)"
    fi

    echo; title "信息显示功能"
    if grep -q "$TOOLKIT" "$NODES_PM" 2>/dev/null; then
        info "CPU/硬盘信息显示: 已添加"
    else
        info "CPU/硬盘信息显示: 未添加"
    fi

    echo; title "IOMMU / 直通"
    if dmesg 2>/dev/null | grep -qE 'DMAR|IOMMU'; then
        local n; n=$(find /sys/kernel/iommu_groups -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
        ok "IOMMU 已启用, ${n} 个分组"
    else
        warn "IOMMU 未启用或硬件不支持"
    fi

    echo; title "CPU 电源模式"
    info "当前: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo '未知')"
    systemctl is-enabled pve-governor.service >/dev/null 2>&1 \
        && info "自持服务: 已启用" || info "自持服务: 未启用"

    echo; title "旧内核"
    local cnt
    cnt=$(dpkg --list 2>/dev/null | awk '/^ii/{print $2}' | grep -cE '^pve-kernel-[0-9]+(\.[0-9]+)*-[0-9]+-pve$')
    info "已安装 PVE 内核 ${cnt} 个 (当前: $(uname -r))"
    echo
    log "health check done"
    pause
}

# =============================================================================
#  主菜单
# =============================================================================
usage(){
    cat <<USGEOF
 PVE Toolkit v${VERSION} — Proxmox VE 一键优化/还原
 用法:
   bash pve.sh              交互主菜单
   bash pve.sh --status     系统体检
   bash pve.sh --restore    直达还原中心
USGEOF
}

main_menu(){
    while :; do
        clear
        cat <<MENUEOF

   ${C_Y}╔════════════════════════════════════════════╗${C_N}
   ${C_Y}║${C_N}     PVE Toolkit v${VERSION} 一键优化/还原       ${C_Y}║${C_N}
   ${C_Y}╚════════════════════════════════════════════╝${C_N}
    环境: PVE ${PVE_FULL:-?} | Debian ${DEB_CODE:-?} (${DEB_VER})

    1. 一键优化 (换源+关企业源+去订阅+CT模板源)
    2. 软件源管理 (单独换 Debian/PVE/Ceph/CT 源)
    3. 订阅弹窗 (移除/还原)
    4. CPU/硬盘信息显示 (温度/频率/功耗/健康)
    5. 硬件直通 (Intel/AMD 自动识别)
    6. CPU 电源模式 (开机自持)
    7. Ceph 管理 (添加源/一键卸载)
    8. 旧内核清理 (交互式, 谨慎)
   ------------------------------------------------
    R. ${C_R}还原中心${C_N} ★ 修复被其他脚本改坏的 PVE
    S. 系统体检 (源冲突/文件完整性/直通状态)
    0. 退出
MENUEOF
        local c
        read -r -t 120 -p " 请选择 [默认0]: " c || c=0
        c=${c:-0}
        case "$c" in
            1) one_key_optimize; pause ;;
            2) source_menu; pause ;;
            3)
                clear; title "订阅弹窗"
                local a; read -r -t 60 -p " 1.移除订阅弹窗 2.还原订阅弹窗 [默认1]: " a || a=1
                a=${a:-1}
                [ "$a" = "2" ] && restore_nag || remove_nag
                pause ;;
            4)
                clear; title "CPU/硬盘信息显示"
                local a2; read -r -t 60 -p " 1.添加 2.移除 [默认1]: " a2 || a2=1
                a2=${a2:-1}
                [ "$a2" = "2" ] && display_remove || display_apply
                ;;
            5) passthrough_menu ;;
            6) cpu_power_menu ;;
            7) ceph_menu ;;
            8) remove_old_kernels ;;
            r|R) restore_menu ;;
            s|S) health_check ;;
            0) clear; exit 0 ;;
            *) ;;
        esac
    done
}

# =============================================================================
#  入口
# =============================================================================
case "${1:-}" in
    -h|--help|help)  usage; exit 0 ;;
    --status|status) require_env; health_check; exit 0 ;;
    --restore)       require_env; restore_menu; exit 0 ;;
esac

require_env
main_menu
