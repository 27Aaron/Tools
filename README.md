# Tools

个人工具与配置收集。

## 目录结构

按 `分类/工具名/` 组织，每个工具目录内附 README 说明用法：

```
Tools/
├── Network/           # 网络
│   └── BBR/           # BBR 拥塞控制 (sysctl.conf)
└── PVE/               # Proxmox VE
    └── Toolkit/       # pve.sh 一键优化/还原脚本
```

## 约定

- 新增脚本放到 `<分类>/<工具名>/` 下，分类不存在就新建目录
- 每个工具目录放一个 README.md：一两句说明 + 一键使用命令
- 一键命令统一走 raw 链接，方便 curl/wget 直接执行
