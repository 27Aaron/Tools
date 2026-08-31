## PVE Toolkit

Proxmox VE 一键优化 / 一键还原脚本，兼容 PVE 7 / 8 / 9。

```
wget https://raw.githubusercontent.com/27Aaron/Tools/main/PVE/Toolkit/pve.sh -O pve.sh && bash pve.sh
```

- 功能：换源（官方/中科大/清华，自动适配 deb822 与传统格式）、去订阅弹窗、CPU 温度/频率/功耗与 NVMe/SATA 硬盘健康显示、硬件直通、CPU 电源模式、Ceph 管理、旧内核清理
- 还原中心：官方源还原 / 官方包重装 / 备份回滚 / 残留清理，用于修复被其他脚本改坏的 PVE
- 体检：`bash pve.sh --status`；还原中心：`bash pve.sh --restore`
- ⚠️ 修改 PVE 存在风险，请自行备份重要数据；仅限 PVE 宿主机 root 运行
