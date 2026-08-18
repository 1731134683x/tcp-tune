# TCP 深度调优工具集

> GitHub: [1731134683x/tcp-tune](https://github.com/1731134683x/tcp-tune)

BBRv3 内核安装 + TCP 深度调优 + 自定义模板 + AI 提示词生成，专为 Ubuntu/Debian VPS 设计。

## 脚本一览

| 脚本 | 功能 | 独立运行 |
|------|------|----------|
| `tcp-full.sh` | **全流程**：BBRv3 内核 + TCP 调优 + 自定义模板 + AI 提示词 | 是 |
| `install-bbrv3.sh` | 仅安装 BBRv3 内核 (双上游: byJoey / XDflight) | 是 |
| `tcp-tune.sh` | 仅 TCP 调优 (基于当前内核) | 是 |

## 快速开始

```bash
# 一键下载并运行全流程脚本
curl -fsSL https://raw.githubusercontent.com/1731134683x/tcp-tune/main/tcp-full.sh | sudo bash

# If a local copy was saved with Windows CRLF line endings, fix it before running
sed -i 's/\r$//' tcp-full.sh && sudo bash tcp-full.sh

# 或者单独下载某个脚本
wget https://raw.githubusercontent.com/1731134683x/tcp-tune/main/tcp-full.sh
wget https://raw.githubusercontent.com/1731134683x/tcp-tune/main/install-bbrv3.sh
wget https://raw.githubusercontent.com/1731134683x/tcp-tune/main/tcp-tune.sh

# 赋予权限后运行
chmod +x *.sh
sudo bash tcp-full.sh           # 交互选择上游 + 全流程
sudo bash install-bbrv3.sh      # 交互选择上游 + 安装内核
sudo bash tcp-tune.sh           # 仅 TCP 调优

# 参数
sudo bash tcp-full.sh --source xdflight           # 指定 XDflight 上游
sudo bash tcp-full.sh --source byjoey             # 指定 byJoey 上游
sudo bash tcp-full.sh --skip-kernel               # 跳过内核安装
sudo bash tcp-full.sh --tag x86_64-7.0.3          # 指定 BBRv3 版本
sudo bash install-bbrv3.sh --source xdflight      # 安装内核 (XDflight 上游)
```

> **Line endings:** Shell scripts in this repository use Linux LF line endings. If Linux prints `$'\r': command not found`, the downloaded file is an old CRLF copy or was converted by a Windows editor. Run the `sed -i 's/\r$//'` command above, then retry.

## 工作流程 (tcp-full.sh)

```
Phase 1: BBRv3 内核安装
  ├── 交互选择上游 (byJoey / XDflight)，或 --source 指定
  ├── 架构检测 (x86_64 → amd64 / aarch64 → arm64)
  ├── 检查当前内核是否已是 BBRv3
  ├── GitHub API → jq/grep 解析 → 直接构造 URL (三重保底)
  ├── 下载 .deb (byJoey 排除 2GB dbg 调试包)
  └── dpkg 安装 + GRUB 更新

Phase 2: VPS 检测与 TCP 调优
  ├── CPU 核心 + 内存取整 (向上取整到 GB)
  ├── 用户输入带宽 (Mbps)
  ├── 双栈延迟测试 (IPv4 + IPv6)
  ├── 选择延迟基准 (IPv4/IPv6/取最大值)
  ├── BDP 计算 → 缓冲区 + 全参数自动生成
  └── 写入配置 + 扫除冲突 + 应用生效

Phase 3: 报告 + 自定义模板 + AI 提示词
  ├── 终端输出完整报告
  ├── 生成 /root/tcp-custom-template.sh (可编辑再运行)
  └── 询问是否生成 /root/tcp-ai-prompt.txt (粘贴到 DeepSeek/ChatGPT)
```

## 调优策略

### 内存分档

| 内存 | somaxconn | netdev_backlog | file-max | nofile |
|------|-----------|----------------|----------|--------|
| ≤1G | 1024 | 2048 | 512K | 32768 |
| 2G | 2048 | 4096 | 1M | 65535 |
| 3-4G | 4096 | 8192 | 1M | 65535 |
| 5-8G | 8192 | 16384 | 2M | 131072 |
| >8G | 16384 | 32768 | 4M | 262144 |

### 延迟分档

| 延迟 | fin_timeout | keepalive_time | keepalive_intvl | keepalive_probes |
|------|-------------|----------------|-----------------|------------------|
| <50ms | 10 | 300 | 10 | 3 |
| 50-150ms | 15 | 600 | 15 | 3 |
| >150ms | 20 | 900 | 30 | 5 |

### 缓冲区

- `BDP = 带宽(bps) × RTT(s) / 8`
- 目标缓冲 = BDP × 2，受内存上限约束（每G约 20MB）
- 最小值 4MB

## 自定义模板

运行 `tcp-full.sh` 后生成 `/root/tcp-custom-template.sh`：

```bash
# 编辑 #@ 标记的参数
vim /root/tcp-custom-template.sh

# 重新应用自定义配置
sudo bash /root/tcp-custom-template.sh
```

模板中的参数已根据你的 VPS 规格预填，改完直接运行即可覆盖调优。

## 系统保护基线

脚本会将以下默认保护参数写入并回读验证 `/etc/sysctl.d/zzz-tcp-tune.conf`：

```ini
# 内核崩溃后 10 秒自动重启
kernel.panic = 10

# 尽量降低 Swap 使用倾向
vm.swappiness = 1

# 允许启发式内存超卖
vm.overcommit_memory = 1
```

## AI 提示词

运行 `tcp-full.sh` 调优完成后会询问是否生成 `/root/tcp-ai-prompt.txt`：

```bash
# 查看提示词
cat /root/tcp-ai-prompt.txt

# 复制全文 → 粘贴到 DeepSeek / ChatGPT 等 AI 对话框
# AI 会根据你的 VPS 规格返回更精细的调参脚本
```

提示词中已预填当前 VPS 的完整参数（CPU、内存、带宽、延迟、BDP、全部 sysctl 值），
AI 拿到后会给出每项参数的推荐值和选择理由。

提示词会按实际内存档位注入对应的调优原则，不再一刀切套用 1G 小内存规则：

| 内存档位 | 调优原则 |
|---------|---------|
| ≤1G | 保守：缓冲 = BDP 并四舍五入，喂饱带宽同时防 OOM |
| 2G | 激进：缓冲 = BDP×2，按并发连接数核算内存预算 |
| 3~4G | 缓冲放开但留冗余，约 8% 内存上限约束 |
| 5~8G | 内存不再是瓶颈，512MB 硬上限 + 高并发是主题 |
| >8G | 512MB 是唯一缓冲上限，队列/积压可满配 |

## 调优前环境检测

应用调优之前，脚本会先执行环境检测，帮助避免多次调优后文件堆积、参数互相覆盖：

1. **运行时环境快照**：当前 qdisc、拥塞控制、rmem/wmem_max、somaxconn、ulimit -n、内存总量/可用
2. **盘点已存在的调优文件**：扫描 `/etc/sysctl.d`、`/etc/security/limits.d`、`/etc/modules-load.d`，标注来源（本工具 / AI·模板生成 / BBRv3 安装器 / 其他）与修改时间
3. **冲突提醒**：存在多个 `zz*` 前缀 sysctl 文件时列出生效顺序（字典序最后的生效），提示清理旧文件
4. **本次写入地址**：应用前明确列出本次将写入/更新的全部文件路径

每次应用后，文件地址会追加记录到 `/root/tcp-tune-file-log.txt`，方便追溯每次调优动了哪些文件。检测到残留旧文件时，脚本会直接输出可复制的清理命令（可选打包备份 + `rm -f` 一行删除），本工具自身管理的 `zzz-tcp-tune.conf` 等文件无需手动删除，每次运行会覆盖。

## 配置文件

| 文件 | 路径 |
|------|------|
| sysctl 调优 | `/etc/sysctl.d/zzz-tcp-tune.conf` |
| 资源限制 | `/etc/security/limits.d/zzz-tcp-tune-limits.conf` |
| 模块加载 | `/etc/modules-load.d/tcp-tune.conf` |
| systemd 覆盖 | `/etc/systemd/system/xray.service.d/99-tcp-tune.conf` |
| 调优记录日志 | `/root/tcp-tune-file-log.txt` |
| 自定义模板 | `/root/tcp-custom-template.sh`（生成的 sysctl 覆盖文件为 `/etc/sysctl.d/zzzz-tcp-custom.conf`） |
| AI 提示词 | `/root/tcp-ai-prompt.txt` |

## 内核来源

支持两个预编译 BBRv3 上游，通过 `--source` 参数切换：

### byJoey (默认: `--source byjoey`)

来自 [byJoey/Actions-bbr-v3](https://github.com/byJoey/Actions-bbr-v3)，GitHub Actions 自动编译：

- `x86_64` → `_amd64.deb`，最新 `x86_64-7.0.5`
- `arm64` → `_arm64.deb`，最新 `arm64-7.0.3`

### XDflight (`--source xdflight`)

来自 [XDflight/bbr3-debs](https://github.com/XDflight/bbr3-debs)，更频繁更新：

- `amd64` → 最新 `linux-7.0.8-bbr3-amd64`
- `arm64` → 最新 `linux-7.0.8-bbr3-arm64`
- 无 dbg 调试包，每 release 固定 3 个 .deb

每 release 含 3 个 .deb：headers、image、libc-dev（byJoey 另有 dbg 包自动略过）。

## 验证

```bash
# 内核版本 (重启后)
uname -r | grep bbrv3

# 拥塞控制
sysctl net.ipv4.tcp_congestion_control

# 队列算法
sysctl net.core.default_qdisc

# 预期输出: bbr + fq 或 fq_codel（取决于内核可用队列算法）
```

## 兼容性

- Ubuntu 18.04+ / Debian 10+
- x86_64 / arm64
- 需 root 权限
