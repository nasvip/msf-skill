# 配置体检

> 本文中 `$DATA` 指 MSF 数据目录：systemd 为 `/opt/msf`，fnOS 为 `/var/apps/msf/var`，Unraid 为 `/mnt/user/appdata/msf`，macOS 为 `/Library/Application Support/MSF`。

目的：判断一套 MSF 配置是否正常、有没有明显可优化项。**输出结论和建议，不擅自修改。**

阈值都带有场景假设（家庭 / 小型局域网、1–2GB 内存）。偏离阈值不等于错误，需结合实际规模判断，并在结论里写明"需现场核实"。

---

## 1. 资源与内核

```bash
free -m
df -h "$DATA"
cat /proc/$(pgrep -f 'msf serve' | head -1)/limits | grep 'open files'
cat /proc/sys/net/ipv4/ip_forward
nproc
```

| 项 | 正常 | 异常含义 |
|---|---|---|
| `open files` | 等于 `LimitNOFILE`（默认 1048576） | 1024 说明不是 systemd 启动，高并发下会 EMFILE |
| `ip_forward` | `1` | `0` 则透明代理必然失效 |
| `$DATA` 剩余 | `> 15%` | 低于则需处理日志轮转 |
| 内存占用 | MosDNS + Mihomo 合计低于总量 50% | 持续接近上限 → 缓存参数过大或内存泄漏 |

**检查 systemd 兜底**：`msf.service` 应有 `ExecStopPost` 在崩溃/被 kill 时清理 nft 与策略路由，否则 MSF 一停，全 LAN 会黑洞。缺失是严重配置缺陷。

```bash
systemctl cat msf | grep -A3 ExecStopPost
```

## 2. MosDNS

### 上游池

```bash
GET /api/v1/mosdns/system/upstream-overrides
# 或直接看生成结果（更真实）
grep -A10 'tag: domestic' $DATA/configs/mosdns/sub_config/forward_local.yaml
```

**先理解 `concurrent` 再谈"上游过多"**：

```yaml
- tag: domestic
  type: forward
  args:
    concurrent: 3        # 每次查询随机挑最多 3 个并发，不是向全部上游各发一遍
    upstreams: [...]
```

所以上游池从 3 个扩到 8 个，**单次查询的请求数仍是 3**，只是随机分布更广、延迟方差更大。把它说成"每个域名发 N 次请求"是错的。

| 组 | 默认并发 | 说明 |
|---|---|---|
| `domestic` | 3 | 国内真实解析 |
| `foreign` | 2 | 国外真实解析 |
| `nocnfake` / `cnfake` | 1 | 向 Mihomo 要 fake-IP |

**真正该查的是"启用的条目是否真的生效"**：`protocol: aliapi`（阿里私享 DoH）在当前 `forward` 插件下**会被静默剔除**，WebUI 里看起来还在，实际不参与解析。

```bash
# 生成结果里只应出现 udp:// tcp:// tls:// https:// 前缀
grep -E 'addr:|tag:' $DATA/configs/mosdns/sub_config/forward_local.yaml
```

建议：国内保留 2–3 个**不同供应商**的 UDP（如 `223.5.5.5` + `119.29.29.29`）再加一个 DoH 兜底即可；运营商 DNS 能拿到就近 CDN，值得保留。国外保留 2 个 DoH。

### 缓存与开关

```bash
GET /api/v1/mosdns/system/cache
GET /api/v1/mosdns/system/feature-switches
GET /api/v1/mosdns/system/switches
```

- `size` 常见默认 `20000000`（2000 万条）。家庭场景活跃域名几千到几万，1GB 内存的机器上属潜在风险，建议 `200000`~`500000`
- `lazy_cache_ttl` 不宜过长（默认 86400 秒合理）；过长的 stale 缓存会把错误的分流结果长期复活
- `switch4`（过期缓存 1）注释建议保持打开；`switch4` + `switch13` 都关掉会让弱网解析明显变慢

开关完整含义见 [`integration.md`](integration.md) 第五节。

## 3. Mihomo

```bash
GET /api/v1/mihomo/config
```

| 项 | 关注点 |
|---|---|
| `tproxy-port` / `redir-port` | 与 `network.yaml` 的 `tproxy_port` / `listen_port` 必须一致 |
| `routing-mark` | 与 `network.yaml` 的 `mark` 一致，否则策略路由断裂 |
| `dns.listen` | 应为 `0.0.0.0:6666`，**不能改**——MosDNS 的 `nocnfake` 上游指向它 |
| `dns.fake-ip-range` | 应与主路由静态路由网段一致（默认 `28.0.0.1/8`，模板标注不可改） |
| `dns.nameserver` | 应为 MosDNS 的**国外**解析端口 `127.0.0.1:3333`（不是 8888） |
| `dns.proxy-server-nameserver` | 应为 `127.0.0.1:8888`（国内真实解析，供节点域名） |
| `dns.default-nameserver` | 应为 `127.0.0.1:8888`（bootstrap 解析） |
| `dns.fake-ip-filter` | 模板默认含 `"*"` 与 `+.lan`。语义随版本可能不同，**改前先验证**，不要照搬外部教程 |
| `external-controller` | 若监听 `0.0.0.0:9090`，**必须**有 `secret`，否则局域网任意主机可控 |
| `sniffer` | `override-destination: true` + `force-domain: "+.*"` 用于还原真实域名；`skip-domain` 已排除 Mijia / `+.push.apple.com` |
| `tun.enable` | Linux nft 模式应为 `false`；Linux TUN 与 macOS 为 `true` |
| `log-level` | 生产建议 `warning`；`info` 会显著增加日志量 |

**三个 nameserver 指向哪个端口是最容易写错的一处**，图省事全填 `8888` 会导致国外域名解析不到真实 IP（`8888` 是 `sequence_local`，只做国内解析）。

### 参数一致性检查（最容易被忽略）

```bash
grep -E 'tproxy_port|listen_port|mark' $DATA/configs/network/network.yaml
grep -E 'tproxy-port|redir-port|routing-mark' $DATA/configs/mihomo/config.yaml
```

两边不一致 → 流量进得来出不去，症状是"DNS 正常但网页一直转圈"。

## 4. 网络安全

### 已知高风险项：MosDNS `:9099` 默认无认证

MosDNS 的 API 监听 `0.0.0.0:9099`（模板注释写明"跟 web ui 绑定，不要修改此端口"），**该监听器不带任何认证**。

实测（从同一局域网的其它主机、不带任何凭据）：

```
GET http://<host>:9099/api/v2/audit/stats   → 200
```

同一监听器还挂着这些写接口：

```
POST /plugins/switch1..switch15/post   改 MosDNS 开关
POST /plugins/blocklist/post          改黑名单
POST /plugins/client_ip/post          改按客户端分流名单
POST /api/v1/system/restart           重启 MosDNS
```

**后果**：局域网内任何设备都可以读取全部 DNS 查询记录（等同于看到每台设备访问了哪些域名），也可以修改分流开关与名单。

**缓解**（按推荐顺序）：

1. 宿主防火墙只放行本机与 MSF 所在主机：
   ```bash
   iptables -I INPUT -p tcp --dport 9099 ! -s 127.0.0.1 -j DROP
   # 或 nft:  nft add rule inet filter input tcp dport 9099 ip saddr != 127.0.0.1 drop
   ```
2. 把 9099 限制在专用管理 VLAN / VPN 内
3. 不要把 `:7777` 与 `:9099` 一起暴露到公网

对照参考：Mihomo 的 `:9090` 因为配了 `secret`，未认证请求返回 `401`；`:9099` 没有这一层。体检时把这条列为**高优先级**，并明确告知用户"这是模板默认行为，不是配置写错"。

### 其它检查项

| 检查 | 期望 |
|---|---|
| `external-controller` 是否暴露 `0.0.0.0` | 若暴露，必须有强 `secret`（返回 401 即为正常） |
| MosDNS `:9099` 暴露范围 | 应仅限本机或管理网段（见上） |
| Mihomo `dns.listen` `0.0.0.0:6666` | 模板默认对 LAN 开放；若不需要外部使用，可在防火墙上限制 |
| `allow-lan` | 需要局域网设备用时为 `true`，否则应为 `false` |
| WebUI `:7777` 是否暴露公网 | 不应暴露；仅在 LAN 或经 VPN |
| 管理员密码强度 | 至少 8 位，非默认 |
| API 令牌 | 是否用了 `admin` 作用域做日常自动化（应改 `operate`） |
| SSH | 是否允许密码登录 root（建议改密钥 + 限制来源） |

## 5. 日志

| 检查 | 期望 |
|---|---|
| `/etc/logrotate.d/` 是否有 MSF 相关条目 | 应有，否则小磁盘会满 |
| 日志目录总大小 | 不应持续线性增长 |
| `msf.log` 中 `level=error` | 不应有稳定复现的错误 |

参考 logrotate 片段见 `logs.md`。

## 6. 已知上游问题（需对照版本）

| 问题 | 影响 | 现状 |
|---|---|---|
| `proxy-providers` 的 `health-check.url` 硬编码 | 改配置文件会被服务重启后覆盖回默认地址 | 上游 Issue #22，未修复前不要改运行时副本 |
| `config.yaml` 是运行时副本 | 直接编辑会被重新生成覆盖 | 应改 user_configs 或走 WebUI |

**体检报告里必须区分**「用户配置有问题」和「上游设计如此」，后者不该让用户反复尝试。

---

## 输出格式建议

按这个结构给结论，不要堆 JSON：

```
整体：正常 / 有风险 / 异常
├─ 正常项：xxx、xxx
├─ 风险项
│   ├─ [高] 说明 + 依据 + 建议
│   └─ [低] 说明 + 依据 + 建议
└─ 需现场核实项：xxx（阈值依赖规模，我无法从配置判断）
```

每条风险都要给出**依据**（哪个字段、什么值、为什么算风险），不要给无依据的"建议优化"。
