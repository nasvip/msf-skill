# 部署形态判定

MSF 同一份后端代码支持多种部署形态，**路径、可用能力、升级方式完全不同**。动手前必须先判定，否则会拿到假故障（例如在 Docker 里执行 `nft list table inet msf` 得到空结果，然后误判成"规则丢失"）。

## 判定顺序

优先走 API，不依赖聊天里问用户：

```bash
# 1) 版本与可达性（免认证）
curl -s http://<host>:7777/api/v1/version

# 2) 运行时与权限（免认证）
curl -s http://<host>:7777/api/v1/setup/privilege

# 3) 系统信息与网络接口（免认证）
curl -s http://<host>:7777/api/v1/setup/system-info
curl -s http://<host>:7777/api/v1/setup/network-interfaces
```

`/api/v1/setup/privilege` 返回形如：

```json
{
  "is_root": true,
  "uid": 0,
  "runtime": {
    "docker": false,
    "docker_network_mode": "",
    "macos": false
  },
  "message": "MosDNS 53 port and TUN/nftables require root on Linux"
}
```

`is_root: false` 说明当前 MSF 进程没有 root —— 53 端口、TUN、nftables 都不可能生效，这是硬性前置条件。

## 判定矩阵

| 形态 | 判定标志 | 数据目录 | nftables | `msf update` | 升级方式 |
|---|---|---|---|---|---|
| **Linux systemd** | 无 docker/macos 标志；存在 `msf.service` | `/opt/msf` | 可用 | 支持 | `sudo msf update` |
| **Docker TUN** | `runtime.docker = true`；或 `/.dockerenv`；或 cgroup 含 docker/containerd/podman/kubepods | 容器内 `/opt/msf`（宿主机映射目录） | **不可用** | **禁用** | 拉新镜像 |
| **Unraid PLG** | PLG 插件托管 | `/opt/msf` | 可用 | 走插件管理器 | 插件管理器 |
| **fnOS FPK** | 存在 `/etc/fnos-release`、`/etc/feiniu-release`、`/usr/local/fnos` 或 `/var/packages/msf`；环境变量 `MSF_RUNTIME=fnos/fpk` | `/opt/msf` | 可用 | **禁用** | 飞牛应用中心 / FPK |
| **macOS** | `runtime.macos = true`；环境变量 `MSF_RUNTIME=macos` | — | **不可用** | — | App 内 |

环境变量 `MSF_RUNTIME` 的取值会覆盖自动探测：`docker` / `container` 强制按容器处理，其他非空值强制关闭容器判定。

## 各形态的实际影响

### Docker TUN

- 只用 Mihomo **TUN**，不写宿主机 nftables，也不建 policy routing
- 两种网络：`host-tun`（共用宿主网络命名空间）、`macvlan-tun`（容器有独立 LAN IPv4，旁路由网关场景推荐）
- 需要 `/dev/net/tun` + `CAP_NET_ADMIN` + `CAP_NET_RAW`，缺任一项初始化预检会拒绝继续
- **诊断时不要执行任何 `nft` / `ip rule` 检查**：这些在容器里没有意义，空结果不是故障
- `msf update` 与 WebUI 自更新被禁用，升级必须走 Docker / Compose

### macOS

- TUN only，未签名 Beta
- 53 端口、utun、DNS 与转发表更需 root LaunchDaemon
- 不要按 Linux 的 systemd / nft 思路排查

### fnOS / Unraid

- 组件升级走插件管理器，直接跑 `msf update` 会被拒绝或造成状态不一致
- 数据目录仍是 `/opt/msf`，但重启服务要经插件而非裸 `systemctl`

## 数据目录随部署方式变化（不要一律按 `/opt/msf`）

| 部署方式 | 数据目录 |
|---|---|
| Linux tarball / systemd | `/opt/msf` |
| **fnOS FPK** | `/var/apps/msf/var` |
| **Unraid PLG** | `/mnt/user/appdata/msf` |
| Docker Compose（宿主机侧） | 默认 `./msf-data` |
| Docker（容器内） | `/opt/msf` |
| **macOS root LaunchDaemon** | `/Library/Application Support/MSF` |
| 源码本地非 root 运行 | 通常 `./data`，取决于 `-c` / `--config` |

先确定 `$DATA`，再拼子路径。下面以 `$DATA=/opt/msf` 为例。

### 目录结构

```
$DATA/
├── configs/mosdns/          MosDNS 配置（含 sub_config、rule、gen）
├── configs/mihomo/          Mihomo 配置（含 user_configs、proxy_providers）
├── configs/network/         network.yaml、network.nft、history
├── configs/cloudflare-redirect/
├── data/binaries/           受管组件二进制（mosdns / mihomo / zashboard）
├── logs/                    msf.log / mosdns.log / mihomo.out.log
├── database/msf.db          SQLite
└── backups/
```

| 项目 | 路径 |
|---|---|
| 主程序（systemd 安装） | `/usr/local/bin/msf` |
| 数据库 | `$DATA/database/msf.db` |
| 服务配置 | `$DATA/configs/app.yaml` |
| Mihomo 运行时配置 | `$DATA/configs/mihomo/config.yaml` |
| Mihomo 用户配置 | `$DATA/configs/mihomo/user_configs/*.yaml` |
| 订阅缓存 | `$DATA/configs/mihomo/proxy_providers/*.yaml` |
| MosDNS 主配置 | `$DATA/configs/mosdns/config.yaml` |
| MosDNS 子配置 | `$DATA/configs/mosdns/sub_config/*.yaml` |
| MosDNS 开关 | `$DATA/configs/mosdns/rule/switch*.txt` |
| 网络配置 | `$DATA/configs/network/network.yaml` |
| 生成的 nft 脚本 | `$DATA/configs/network/network.nft` |

macOS 在 TUN 接管期间额外保存 `configs/network/darwin-state.json`（原始 DNS 与 `net.inet.ip.forwarding`），停止时按快照恢复。

## 端口分配

完整链路与各端口的角色见 [`integration.md`](integration.md)。速查：

### 对外（LAN 可达）

| 端口 | 归属 | 用途 |
|---|---|---|
| `7777` | MSF | WebUI / REST API |
| `53` | MosDNS | DNS 入口 |
| `9099` | MosDNS | API / 审计缓冲 |
| `7890` `7891` `7892` | Mihomo | HTTP / SOCKS5 / Mixed |
| `9090` | Mihomo | external-controller |
| `6666` | Mihomo | fake-IP DNS |

### 内部（本机回环）

| 端口 | 归属 | 用途 |
|---|---|---|
| `2222` | MosDNS | 内部国内 DNS |
| `3333` | MosDNS | 内部国外 DNS（带过期缓存） |
| `4444` | MosDNS | 国外 DNS + ECS（节点解析） |
| `8888` | MosDNS | 代理核 `default-nameserver` / `proxy-server-nameserver` |
| `7778` | MosDNS | 节点域名解析（含 5 ms 回退） |
| `7877` | Mihomo | Redirect（TCP 透明） |
| `7896` | Mihomo | TProxy（UDP 透明） |
| `1053` | Mihomo | 国内 fake-IP（默认关闭） |

辅助入口：`66`（requery）、`77`（stash）、`99`（clashmi）、`11101`（sing-box）。

`7877` / `7896` 在 Linux **TUN 模式默认不启用**；**Docker 形态不写 nftables**。

## 快速自检

```bash
# systemd 形态
systemctl show msf -p NRestarts -p ActiveState -p SubState
cat /proc/$(pgrep -f 'msf serve' | head -1)/limits | grep 'open files'

# 容器形态
cat /.dockerenv >/dev/null 2>&1 && echo "in container"
env | grep -E '^MSF_(RUNTIME|DOCKER_NETWORK_MODE)'

# 通用：进程与监听
msf status
ss -tulpn | grep -E ':(53|7777|7890|7891|7892|7877|7896|8888|9090|9099)\b'
```
