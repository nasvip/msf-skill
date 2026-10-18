# MSF / MosDNS / Mihomo 三方关系

> 本文中 `$DATA` 指 MSF 数据目录：systemd 为 `/opt/msf`，fnOS 为 `/var/apps/msf/var`，Unraid 为 `/mnt/user/appdata/msf`，macOS 为 `/Library/Application Support/MSF`。

这三者不是并列的三个软件，而是**编排者 + DNS 大脑 + 代理执行器**的分工。搞不清这层关系，几乎所有"上不了网"的判断都会跑偏。

---

## 一、各自的职责

| 组件 | 角色 | 实际在干什么 |
|---|---|---|
| **MSF** | 编排器 | 生成 MosDNS/Mihomo/nftables 配置、拉起与守护进程、提供 WebUI/API、管理订阅与组件、记录审计 |
| **MosDNS** | DNS 分流大脑 | 独占 `:53` 面对客户端；判断域名归国内还是国外；国内返回**真实 IP**，国外向 Mihomo 索取 **fake-IP** |
| **Mihomo** | 代理执行器 | 生成 fake-IP（`:6666`）、按规则分流、负责真实的出站与节点 |

**关键认知**：MSF 自己不转发任何流量，也不解析任何域名。它只是把两份配置写对、把进程看住、把内核规则装好。所以"MSF 面板正常"不等于"网络正常"——三个环节任何一个断了都会表现为"上不了网"。

---

## 二、完整链路

### 2.1 DNS 阶段（客户端查域名）

```
客户端 ──:53──> MosDNS  sequence_6666
                   │
                   ├─ 本地 TLD(.lan/.local)        → reject 0
                   ├─ 命中黑名单 / 无地址记忆       → reject 0
                   ├─ 指定客户端直连（client_ip）   → sequence_local（真实 IP）
                   ├─ 缓存命中                     → 直接返回
                   │
                   ├─ 域名在中国清单 ──> sequence_local
                   │     └─ forward(并发 3) ──> 223.5.5.5 / 119.29.29.29 / 阿里 DoH
                   │            └─> 真实国内 IP
                   │
                   └─ 域名不在清单 ──> sequence_fakeip
                         └─ nocnfake ──udp 127.0.0.1:6666──> Mihomo
                                └─> fake-IP（默认 28.x.x.x）
```

两条**例外**要记住：

- 若 `switch9 = A`（国内域名实 IP 模式），国内域名也可能被转成 fake-IP 走代理
- 若域名命中 `fake-ip-filter`，则向国外真实解析（3333）拿真实 IP，不进 fake-IP

### 2.2 流量阶段（客户端连目标）

```
客户端 ── 连 28.x.x.x
   │
   ▼
主路由 —— 静态路由 28.0.0.0/8 → MSF 主机 —— 否则流量根本到不了 MSF
   │
   ▼
nftables (table inet msf)
   ├─ TCP 入站（iifname eth0）  → redirect :7877   （全部进 Mihomo）
   ├─ TCP 目标为 fake-ip        → redirect :7877
   ├─ TCP 目标是外部 DNS        → redirect :7877
   ├─ UDP 目标是外部 DNS        → tproxy :7896
   │     └─ 除：NTP 123、53、国内 UDP 集、游戏 UDP 端口
   └─ 其它 UDP                  → mark 1 + tproxy :7896
   │
   ▼
Mihomo（Route 规则 + 流量嗅探）
   ├─ sniffer 从 TLS/HTTP/QUIC 还原真实域名
   ├─ 按规则匹配 → DIRECT 或某个代理组
   └─ 需要目标真实 IP 时 ──> MosDNS :3333 ──> 国外真实解析
```

**注意两点**：

1. **国内 TCP 也会进 Mihomo**。nft 对入站 TCP 是"全量 redirect"，并不区分国内国外。分流发生在 Mihomo 的规则层（`全局直连` 等组）。所以 Mihomo 规则写错会直接表现为"国内网站也打不开"。
2. **DNS 的 UDP 不被劫持**（`udp dport 53 accept`）。这是有意的——`:53` 留给 MosDNS 独占。若客户端绕过 DNS 直接向 `8.8.8.8:53` 发 UDP，报文会原样过去，不会进 MosDNS。

---

## 三、端口全景

分清"对外"与"内部"，否则排查时会去连一个只监听本地的端口。

### 对外（LAN 可达）

| 端口 | 归属 | 用途 |
|---|---|---|
| `7777` | MSF | WebUI / REST API |
| `53` | MosDNS | DNS 入口（UDP/TCP） |
| `9099` | MosDNS | 统计 / API / 审计缓冲 |
| `7890` `7891` `7892` | Mihomo | HTTP / SOCKS5 / Mixed |
| `9090` | Mihomo | external-controller（zashboard） |
| `6666` | Mihomo | fake-IP DNS（也供 MosDNS 内部调用） |

### 内部（仅本机回环，排查时不要从外部连）

| 端口 | 归属 | 用途 |
|---|---|---|
| `2222` | MosDNS | 内部国内 DNS（`sequence_local`） |
| `3333` | MosDNS | 内部国外 DNS（`sequence_google`，带过期缓存） |
| `4444` | MosDNS | 国外 DNS + ECS（节点解析用） |
| `8888` | MosDNS | `sequence_local`：代理核的 `default-nameserver` / `proxy-server-nameserver` |
| `7778` | MosDNS | 节点域名解析（5 ms 内不可用则回退国内解析） |
| `7877` | Mihomo | Redirect（TCP 透明代理） |
| `7896` | Mihomo | TProxy（UDP 透明代理） |
| `1053` | Mihomo | 国内 fake-IP（`cnfake`，默认关闭） |

### 辅助入口（非主链路）

| 端口 | 归属 | 用途 |
|---|---|---|
| `66` | MosDNS | requery：刷新分流与缓存 |
| `77` | MosDNS | stash 回家 |
| `99` | MosDNS | clashmi 回家 |
| `11101` | MosDNS | sing-box 回家（原规划 111，为避免与 rpcbind 冲突改为 11101） |

`7877` / `7896` 在 **Linux TUN 模式默认不启用**；Docker 形态根本不写 nftables。

---

## 四、配置里那些"不能改"的常量

模板中明确标注了不能动的项，改了会直接断链：

| 项 | 值 | 为什么 |
|---|---|---|
| Mihomo `dns.listen` | `0.0.0.0:6666` | MosDNS 的 `nocnfake` 上游硬编码指向它 |
| Mihomo `dns.enhanced-mode` | `fake-ip` | 整套分流依赖 fake-IP |
| Mihomo `dns.fake-ip-range` | `28.0.0.1/8` | 必须与主路由静态路由一致 |
| MosDNS `api.http` | `0.0.0.0:9099` | 与 WebUI 绑定 |
| `sub_config` 的 `include` 顺序 | 固定 | 后者依赖前者定义的 tag |

而 `network.yaml` 与 Mihomo 的对应关系必须**成对一致**：

```
network.yaml: tproxy_port: 7896   ←→  mihomo: tproxy-port: 7896
network.yaml: listen_port: 7877   ←→  mihomo: redir-port: 7877
network.yaml: mark: 1             ←→  mihomo: routing-mark: 1
```

任一对不齐 → 流量进得来出不去，症状是"DNS 正常但网页一直转圈"。

---

## 五、MosDNS 的开关（switch）

`configs/mosdns/rule/switch*.txt` 是**单字符状态文件**（`A` / `B`），由 WebUI 改写，MosDNS 通过 `switchN` 插件读取。**不要手工编辑**，用 WebUI 或 `POST /plugins/switchN/post`。

| 开关 | `A` | `B` | 说明 |
|---|---|---|---|
| `switch1` | 启用 | 不启用 | 屏蔽黑名单 + 无解析结果的 A/AAAA |
| `switch2` | 启用 | 不启用 | 只有 `client_ip.txt` 内的客户端走代理 |
| `switch12` | 启用 | 不启用 | 只有 `client_ip.txt` 内的客户端**不**走代理 |
| `switch3` | 泄露版 | 不泄露版 | 影响采用 `cache_all` 还是 `cache_all_noleak` |
| `switch4` | 打开 | 关闭 | 过期缓存（1） |
| `switch13` | 打开 | 关闭 | 过期缓存（2，前端缓存层） |
| `switch5` | 阻止 | 放行 | SOA / PTR / HTTPS(65) 查询 |
| `switch6` | 阻止 | 放行 | AAAA 查询（关 IPv6 时通常为 `A`） |
| `switch7` | 打开 | 关闭 | AdGuard 去广告 |
| `switch8` | 打开 | 关闭 | Prefer IPv4 |
| `switch10` | 打开 | 关闭 | Prefer IPv6 |
| `switch9` | realip | fakeip | 国内域名是否也走 fake-IP |
| `switch11` | 使用 | 不使用 | 阿里私有 DoH |
| `switch14` | 使用 | 不使用 | 运营商 DNS |
| `switch15` | 使用 | 不使用 | 其它 DNS |

`switch4` 与 `switch13` 都关掉会让"过期缓存"完全失效，弱网下解析明显变慢。注释里建议 `switch4` 保持打开。

---

## 六、MosDNS 上游的真实行为

这点极易误判，值得单独说。

国内上游由 `forward` 插件（fork 增强版）承担，参数是：

```yaml
- tag: domestic
  type: forward
  args:
    concurrent: 3          # ← 关键
    upstreams: [...]
```

`concurrent: 3` 的含义是**每次查询从上游池中随机挑最多 3 个并发**，**不是"向全部上游发一遍"**。

推论（很实用）：

- 池子里有 5 个还是 8 个，单次查询都只发 3 个请求
- 上游越多 → 单次延迟的方差越大，但不增加单次请求数
- "并发太多把 socket 打爆"是**错误结论**；`connection ctx canceled` 主要来自客户端放弃

三个上游组的默认并发：

| 组 | 并发 | 默认上游 |
|---|---|---|
| `domestic` | 3 | 223.5.5.5 / 119.29.29.29 / 阿里 DoH |
| `foreign` | 2 | 1.1.1.1 DoH / 8.8.8.8 DoH |
| `nocnfake` / `cnfake` | 1 | 127.0.0.1:6666 / 127.0.0.1:1053 |

### 一个必须知道的坑：`aliapi` 会被静默丢弃

WebUI 的上游列表里可能还留着 `protocol: aliapi`（阿里私享 DoH）的条目。当前版本的 `forward` 插件**不支持 aliapi**，生成配置时会**直接剔除**，且不报错。

所以：**在 WebUI 里看到某条上游是"启用"的，不代表它真的在工作。** 判断方法看生成后的配置：

```bash
grep -A8 'tag: domestic' $DATA/configs/mosdns/sub_config/forward_local.yaml
```

只认 `udp://` / `tcp://` / `tls://` / `https://` 前缀。

---

## 七、游戏 UDP 与 60 秒断连

MSF 的 nft 里有一个专门的集合：

```
set game_udp_bypass { type inet_service; elements = { <端口> } }
...
udp dport @game_udp_bypass return
```

原因写在代码注释里：Mihomo 的 UDP 隧道有固定的 **60 秒空闲超时**，国内游戏 UDP 若经过 Mihomo，会表现为**每隔 30–40 秒周期性断连**。国内游戏本来就是直连，因此在**内核层直接放行**，不进 Mihomo。

对应设置项：`network.game_udp_bypass_ports`（默认 `22101,22102`）。

**排查线索**：用户报"游戏每隔半分钟掉一次线"时，先看这个端口列表有没有覆盖该游戏的 UDP 端口。

同理，`china_udp_ipv4/ipv6` 集合（国内 UDP 目标）也在内核层 `return`，不进 Mihomo。

---

## 八、启动与自愈

```
systemd: msf.service  (User=root, LimitNOFILE=1048576)
  └─ msf serve ──> supervisor（unix socket，不占 TCP 端口）
        ├─ mosdns
        └─ mihomo
```

**关键设计**：`msf.service` 的 `ExecStopPost` 会在**任何退出路径**（含 SIGKILL、崩溃）清理：

```
nft delete table inet msf
ip rule del fwmark 1 table 100
ip route del local 0.0.0.0/0 dev lo table 100
```

为什么重要：MSF 停掉后 `7877`/`7896` 就没人监听了，残留的 redirect 规则会把**所有经过网关的 TCP** 打进黑洞。清理后流量回落到直连，至少还能上网。

**排查线索**：如果 MSF 崩溃后整个 LAN 断网，说明这段清理没生效——查 `systemctl cat msf` 是否还有 `ExecStopPost`。

另一条：MSF 配置校验失败时**仍会把面板拉起来**（否则会变成 systemd 崩溃循环且没有修复入口）。所以看到 `startup-issues` 应该去 WebUI 修配置，而不是反复重启。

---

## 九、常见"看起来坏了其实是设计"

| 现象 | 真实原因 |
|---|---|
| `nslookup -type=AAAA google.com` 没有 answer | `switch6 = A`，主动拦 AAAA。**预期行为** |
| `.lan` / `.local` 域名解析失败 | 故意 `reject 0`，搜索域查询永不上游 |
| Docker 环境 `nft list table inet msf` 为空 | Docker 用 TUN，不写 nftables。**不是故障** |
| 只有部分设备走代理 | `switch2` / `switch12` + `client_ip.txt` 在按客户端分流 |
| 国内网站也经过 Mihomo | nft 对入站 TCP 全量 redirect，分流在 Mihomo 规则层 |
| mosdns 日志大量 `connection ctx canceled` | 客户端并发后主动关闭；看 `elapsed` 是否只有几毫秒即可确认 |
| WebUI 里启用的上游没生效 | 可能是 `aliapi`，被静默剔除 |
| 游戏每 30–40 秒掉线 | 该游戏 UDP 端口未加入 `game_udp_bypass_ports` |
| 改了 `config.yaml` 又变回去 | 它是运行时副本，会被重新生成覆盖 |

---

## 十、自检顺序

按依赖顺序查，从上往下，第一个失败的就是根因：

```bash
# 1) MSF 编排层
msf status
curl -s http://<host>:7777/api/v1/version

# 2) 进程与监听
ss -tulpn | grep -E ':(53|7777|6666|8888|3333|2222|7877|7896)\b'

# 3) 内核层
cat /proc/sys/net/ipv4/ip_forward
nft list table inet msf          # 仅 nft 模式
ip rule show | grep 'fwmark 0x1'

# 4) DNS 层
nslookup www.baidu.com <host>    # 期望真实国内 IP
nslookup www.google.com <host>   # 期望 fake-IP 段

# 5) 代理层
curl -s -o /dev/null -w '%{http_code}\n' -x http://<host>:7890 https://www.gstatic.com/generate_204
```

第 4 步出现"真实 IP 却不是国内的"或"fake-IP 段不对"，问题在 MosDNS；第 5 步失败而第 4 步正常，问题在 Mihomo 或节点。
