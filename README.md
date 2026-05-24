# TCP 深度调优工具集

> GitHub: [1731134683x/tcp-tune](https://github.com/1731134683x/tcp-tune)

BBRv3 内核安装 + TCP 深度调优 + 自定义模板 + AI 提示词生成，专为 Ubuntu/Debian VPS 设计。

## 脚本一览

| 脚本 | 功能 | 独立运行 |
|------|------|----------|
| `tcp-full.sh` | **全流程**：BBRv3 内核 + TCP 调优 + 自定义模板 + AI 提示词 | 是 |
| `install-bbrv3.sh` | 仅安装 BBRv3 内核 (byJoey/Actions-bbr-v3) | 是 |
| `tcp-tune.sh` | 仅 TCP 调优 (基于当前内核) | 是 |

## 快速开始

```bash
# 一键下载并运行全流程脚本
curl -sSL https://raw.githubusercontent.com/1731134683x/tcp-tune/main/tcp-full.sh | sudo bash

# 或者单独下载某个脚本
wget https://raw.githubusercontent.com/1731134683x/tcp-tune/main/tcp-full.sh
wget https://raw.githubusercontent.com/1731134683x/tcp-tune/main/install-bbrv3.sh
wget https://raw.githubusercontent.com/1731134683x/tcp-tune/main/tcp-tune.sh

# 赋予权限后运行
chmod +x *.sh
sudo bash tcp-full.sh           # 全流程
sudo bash install-bbrv3.sh      # 仅安装内核
sudo bash tcp-tune.sh           # 仅 TCP 调优

# 参数
sudo bash tcp-full.sh --skip-kernel               # 跳过内核安装
sudo bash tcp-full.sh --tag x86_64-7.0.3          # 指定 BBRv3 版本
```

## 工作流程 (tcp-full.sh)

```
Phase 1: BBRv3 内核安装
  ├── 架构检测 (x86_64 → amd64 / aarch64 → arm64)
  ├── 检查当前内核是否已是 BBRv3
  ├── GitHub API → jq/grep 解析 → 直接构造 URL (三重保底)
  ├── 下载 .deb (排除 2GB dbg 调试包)
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

## AI 提示词

运行 `tcp-full.sh` 调优完成后会询问是否生成 `/root/tcp-ai-prompt.txt`：

```bash
# 查看提示词
cat /root/tcp-ai-prompt.txt

# 复制全文 → 粘贴到 DeepSeek / ChatGPT 等 AI 对话框
# AI 会根据你的 VPS 规格返回更精细的调参脚本
```

提示词中已预填当前 VPS 的完整参数（CPU、内存、带宽、延迟、BDP、全部 sysctl 值），
AI 拿到后会给出每项参数的推荐值和选择理由，甚至提供激进/保守两套方案。

## 配置文件

| 文件 | 路径 |
|------|------|
| sysctl 调优 | `/etc/sysctl.d/zzz-tcp-tune.conf` |
| 资源限制 | `/etc/security/limits.d/zzz-tcp-tune-limits.conf` |
| 模块加载 | `/etc/modules-load.d/tcp-tune.conf` |
| 自定义模板 | `/root/tcp-custom-template.sh` |
| AI 提示词 | `/root/tcp-ai-prompt.txt` |

## 内核来源

BBRv3 预编译内核来自 [byJoey/Actions-bbr-v3](https://github.com/byJoey/Actions-bbr-v3)，GitHub Actions 自动编译：

- `x86_64` → `_amd64.deb`，最新版本 `x86_64-7.0.5`
- `arm64` → `_arm64.deb`，最新版本 `arm64-7.0.3`

每 release 含 3-4 个 .deb：headers、image、libc-dev（+ 可选的 dbg 调试包，自动略过）。

## 验证

```bash
# 内核版本 (重启后)
uname -r | grep bbrv3

# 拥塞控制
sysctl net.ipv4.tcp_congestion_control

# 队列算法
sysctl net.core.default_qdisc

# 预期输出: bbr + fq
```

## 兼容性

- Ubuntu 18.04+ / Debian 10+
- x86_64 / arm64
- 需 root 权限
