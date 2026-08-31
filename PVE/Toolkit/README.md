# PVE Toolkit

面向 Proxmox VE 宿主机的交互式维护工具。当前版本为 `1.1.0`，以 PVE 9 为主要支持目标；PVE 7/8 仅保留遗留兼容，两者都已结束上游常规支持。

## 使用

建议先下载并检查脚本，再以 `root` 执行：

```bash
wget https://raw.githubusercontent.com/27Aaron/Tools/main/PVE/Toolkit/pve.sh -O pve.sh
less pve.sh
bash pve.sh
```

常用入口：

```bash
bash pve.sh --status
bash pve.sh --restore
bash pve.sh --version
```

`--status` 不读取输入，退出码为：`0` 正常、`1` 有警告、`2` 有失败。`--restore` 会在会话中记住失败操作，正常退出时返回 `1`；环境或参数错误返回 `2`。交互菜单和还原中心必须在 TTY 中运行。

## 主要功能

- 软件源：官方、中科大、清华镜像；PVE 9 使用 deb822，PVE 7/8 使用传统 `.list`；Debian 安全更新保持官方源。
- 安全换源：先创建独立快照，写入后强制运行 `apt-get update`；失败自动按相反顺序回滚。
- 硬件面板：CPU 温度/频率/功耗、NVMe/SATA SMART 信息。数据由 systemd 每 30 秒采集到 `/run/pve-toolkit`，PVE API 只读缓存，不同步轮询磁盘。
- 硬件直通：识别 GRUB 与 systemd-boot，支持 x86_64 Intel/AMD；不会自动屏蔽全部显卡/声卡驱动，也不会按型号绑定所有同款 PCI 设备。
- CPU governor：保存每个 policy 的修改前值，并通过 systemd 持久化；『恢复』会还原原值，而不是猜测 `performance`。
- Ceph：跟随已安装或唯一启用的 Ceph 大版本配置仓库，支持 Pacific/Quincy/Reef/Squid/Tentacle；提供只读退役检查，不提供危险的『一键删除集群数据』。
- 旧内核：识别 `pve-kernel-*` 与 `proxmox-kernel-*-signed`，保护当前、pin、Proxmox 自动选择及至少两个备用内核；删除前展示 APT 模拟结果。
- 还原中心：官方源基线、官方包重装、逐文件快照回滚、旧版 SUID/直通/governor 残留清理。

## 安全设计

每次文件变更都会生成独立、不可覆盖的快照：

- 快照：`/var/backups/pve-toolkit/files/`
- 索引：`/var/backups/pve-toolkit/manifest.log`
- 日志：`/var/log/pve-toolkit.log`

索引同时记录文件原本是否存在、事务 ID、PVE 版本、接管边界与类型化 SHA-256；普通文件和相对/悬空符号链接分别校验，因此脚本新建的文件也能正确回滚，损坏快照不会被使用。快照前还会保证分区剩余至少 512 MiB 或 5% 空间。源配置、直通和硬件面板采用事务式变更；收到 `INT`、`TERM` 或 `HUP` 时会尝试回滚尚未提交的事务。脚本还使用 `flock` 防止两个维护会话同时修改宿主机。

1.0.0 曾给 `nvme`、`smartctl`、`turbostat` 等工具添加 SUID。1.1.0 已完全移除此做法，并会在体检或残留清理中发现/撤销旧权限。`pvedaemon` 本身以 root 运行，不需要 SUID。

## 兼容性

| PVE | Debian | 仓库格式 | 默认 Ceph（仅在无现有线索时） | 状态 |
| --- | --- | --- | --- | --- |
| 9.2+ | 13 / trixie | deb822 | Tentacle | 主要支持 |
| 9.0–9.1 | 13 / trixie | deb822 | Squid | 支持 |
| 8.4 | 12 / bookworm | `.list` | Squid | 遗留兼容，已 EOL |
| 8.1–8.3 | 12 / bookworm | `.list` | Reef | 遗留兼容，已 EOL |
| 8.0 | 12 / bookworm | `.list` | Quincy | 遗留兼容，已 EOL |
| 7.3+ | 11 / bullseye | `.list` | Quincy | 遗留兼容，已 EOL |
| 7.0–7.2 | 11 / bullseye | `.list` | Pacific | 遗留兼容，已 EOL |

检测到已安装 Ceph 或已有唯一启用的 Ceph 仓库时，脚本始终跟随该版本；检测到混合大版本会停止，不会猜测或降级。

## 重要限制

- 修改 PVE 包文件的『订阅提示』和『硬件面板』会被对应软件包升级覆盖；升级后请先运行 `--status`，再决定是否重新应用。
- 硬件面板会安装 `lm-sensors`、`nvme-cli`、`sysstat`、`linux-cpupower`、`smartmontools`、`nodejs`（用于提交前校验前端 JavaScript）。移除面板不会自动卸载这些通用依赖包。
- PVE 9.2 支持 arm64，但自动直通配置仅支持 x86_64；arm64 上不会写入猜测的 IOMMU 参数。turbostat 功耗值也仅在支持的 x86 平台可用。
- Ceph 退役是集群级操作。必须按 Proxmox 官方流程逐 OSD、逐节点执行，不能在某个节点直接删除 `/etc/pve` 或 `/var/lib/ceph`。软件源修改也只作用于当前节点；多节点集群需要逐节点保持同一 Ceph 大版本。
- no-subscription 仓库更新更快、验证强度低于企业仓库；生产集群优先使用有效订阅的企业仓库。
- 本工具不会自动执行系统 `dist-upgrade`，也不会自动执行 `apt autoremove`。

## 本地验证

仓库内提供不接触真实 PVE 配置的函数级测试：

```bash
bash PVE/Toolkit/tests/test_pve.sh
```

测试覆盖版本化备份/回滚、哈希篡改拒绝、相对符号链接原子恢复、接管边界/旧 governor 迁移、事务逆序回滚、systemd runtime enable 状态、Ceph 默认映射、生成的 Perl/JavaScript、采集器单元，以及关键破坏性命令的静态守卫。

## 参考

- [Proxmox VE Administration Guide](https://pve.proxmox.com/pve-docs/pve-admin-guide.pdf)
- [USTC Proxmox 镜像帮助](https://mirrors.ustc.edu.cn/help/proxmox.html)
- [TUNA Proxmox 镜像帮助](https://mirrors.tuna.tsinghua.edu.cn/help/proxmox/)

在生产节点执行任何宿主机修改前，仍应准备可验证的 VM/CT 备份，并确保有 IPMI、iKVM 或物理控制台等独立恢复通道。
