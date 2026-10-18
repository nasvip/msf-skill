# 配置体检

目的：判断一套 MSF 配置是否正常、有没有明显可优化项。**输出结论和建议，不擅自修改。**

阈值都带有场景假设（家庭 / 小型局域网、1–2GB 内存）。偏离阈值不等于错误，需结合实际规模判断，并在结论里写明"需现场核实"。

---

## 1. 资源与内核

```bash
free -m
df -h /opt/msf
cat /proc/$(pgrep -f 'msf serve' | head -1)/limits | grep 'open files'
cat /proc/sys/net/ipv4/ip_forward
nproc
```

| 项 | 正常 | 异常含义 |
|---|---|---|
| `open files` | 等于 `LimitNOFILE`（默认 1048576） | 1024 说明不是 systemd 启动，高并发下会 EMFILE |
| `ip_forward` | `1` | `0` 则透明代理必然失效 |
| `/opt/msf` 剩余 | `> 15%` | 低于则需处理日志轮转 |
| 内存占用 | MosDNS + Mihomo 合计低于总量 50% | 持续接近上限 → 缓存参数过大或内存泄漏 |

**检查 systemd 兜底**：`msf.service` 应有 `ExecStopPost` 在崩溃/被 kill 时清理 nft 与策略路由，否则 MSF 一停，全 LAN 会黑洞。缺失是严重配置缺陷。

```bash
systemctl cat msf | grep -A3 ExecStopPost
```

## 2. MosDNS

### 上游冗余

```bash
GET /api/v1/mosdns/system/upstream-overrides
```

看 `domestic` 数组里 `enabled: true` 的条目数。

- **6 个以上**（如同时开 `ariapi`/UDP/TCP/DoH/DoT/运营商）→ 每个国内域名会并发向全部上游发包，socket 压力大，慢的会被丢弃并在 `mosdns.log` 刷出 `connection ctx canceled`
- 建议保留 **2–3 个**：`阿里 UDP (223.5.5.5:53)` + `本地运营商 UDP` 通常最优（运营商 DNS 能拿到就近 CDN）
- 保留 DoH/DoT 作为抗污染备份也可以，但没必要与 UDP 同时全开

### 缓存容量

```bash
GET /api/v1/mosdns/system/cache
```

`size` 常见默认值是 `20000000`（2000 万条）。家庭场景活跃域名通常几千到几万，这个上限在 1GB 内存的机器上属潜在风险。

- 建议 `200000` ~ `500000`
- `lazy_cache_ttl` 不宜过长（默认 86400 秒合理）；过长的 stale 缓存会把错误的旧分流结果长期复活

### 执行模式

```bash
GET /api/v1/mosdns/system/feature-switches
GET /api/v1/mosdns/system/routing
```

确认分流顺序符合预期：国内域名走国内上游拿真实 IP，国外域名进 Mihomo fake-IP。

## 3. Mihomo

```bash
GET /api/v1/mihomo/config
```

| 项 | 关注点 |
|---|---|
| `tproxy-port` / `redir-port` | 与 `network.yaml` 的 `tproxy_port` / `listen_port` 必须一致 |
| `routing-mark` | 与 `network.yaml` 的 `mark` 一致，否则策略路由断裂 |
| `dns.nameserver` | 应指向 MosDNS 内部端口（默认 `127.0.0.1:8888`），不是公共 DNS |
| `fake-ip-range` | 与主路由静态路由的网段一致 |
| `external-controller` | 若监听 `0.0.0.0:9090`，**必须**有 `secret`，否则局域网任意主机可控 |
| `sniffer` | 开启可提高 fake-IP 还原率；`force-domain: +.*` 会带来轻微 CPU 开销，PT/BT 大流量场景需确认 tracker 已直连 |
| `log-level` | 生产建议 `warning`；`info` 会显著增加日志量 |

### 参数一致性检查（最容易被忽略）

```bash
grep -E 'tproxy_port|listen_port|mark' /opt/msf/configs/network/network.yaml
grep -E 'tproxy-port|redir-port|routing-mark' /opt/msf/configs/mihomo/config.yaml
```

两边不一致 → 流量进得来出不去，症状是"DNS 正常但网页一直转圈"。

## 4. 网络安全

| 检查 | 期望 |
|---|---|
| `external-controller` 是否暴露 `0.0.0.0` | 若暴露，必须有强 `secret` |
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
