# 实战案例库

> 每个案例都记录**可复现的证据链**，而不是结论。新增案例请照最后的结构写。

---

## 案例 A：机场整机故障 —— 判定为「不需要修复」

| 项 | 内容 |
|---|---|
| 首次发现 | 2026-10-16 17:38 |
| 最后一条 | 2026-10-17 18:18 |
| 影响量 | 24 小时内 2543 条相关日志 |
| 结论 | 上游故障，自愈。**未改任何配置** |

**现象**

`谷歌服务` 组大量失败，签名：

```
<组> → <域名> | stonehd.aurorapipe.com:16771 connect error: connection refused
```

**取证过程**

1. 原始日志显示错误形如：

```
[TCP] dial 谷歌服务 (match RuleSet/Google) 10.0.0.99:55249 --> mtalk.google.com:5228
  error: stonehd.aurorapipe.com:16771 connect error:
  dial tcp 38.165.64.156:16771: connect: connection refused
  \n dial tcp 185.148.13.253:16771: connect: connection refused
  \n dial tcp 185.148.13.127:16771: connect: connection refused
  \n dial tcp 38.59.244.113:16771: connect: connection refused
```

   这**四个 IP** 是该节点域名 `stonehd.aurorapipe.com` 的全部 A 记录，**全部拒绝** —— 说明是整机故障，不是单个 IP 被墙。

2. 该节点属于 `Dmit` 机场（`proxy_providers/Dmit.yaml`）。

3. 时间跨度 24 小时，之后**再无新增**；复测端口 `16771` 已可连通。

**为什么不是本地问题**

`connection refused` 出现在**节点主机**（`<节点域名>:<端口> connect error:`）上，意味着 TCP 已被对端明确拒绝。本地配置、DNS、路由都正常，否则会表现为 `can't resolve ip` 或 `i/o timeout`。

**教训**

- `connect error: connection refused` 指向节点主机 → **永远不是本地配置问题**
- 同一节点的多个 IP 全部失败 → 整机故障，换节点即可，不必动订阅
- 修复的判据是"1h 窗口是否仍有"，不是"日志里出现过"

---

## 案例 B：客户端残留域名 —— 不修 MSF，查客户端

| 项 | 内容 |
|---|---|
| 状态 | **仍在发生**，约 20 次/小时 |
| 累计 | 729 次 |
| 结论 | 客户端软件残留，与 MSF 配置无关 |

**现象**

```
漏网之鱼 → germany1.noesissite.ru | can't resolve ip: couldn't find ip
```

**取证过程**

1. 三上游交叉验证，排除单上游误判：

```bash
for u in 223.5.5.5 119.29.29.29 8.8.8.8; do
  printf '%-16s ' "$u"; dig +short +time=3 @$u germany1.noesissite.ru A | tr '\n' ' '; echo
done
# 三个全部为空 = 域名确实没有 A 记录
```

2. 权威 NS 存在（`ns1/ns2.hosting.reg.ru.`）但无 A 记录 → 域名注册了，记录被删除。

3. Mihomo 日志给出固定来源客户端（如 `10.0.0.8`）。

4. 命中 `漏网之鱼`（`match Match/`）= 兜底规则，说明没有任何规则匹配它。

**根因**

该设备上残留的 VPN / 代理客户端仍在连一个已废弃的服务器域名。属于客户端问题。

**处置**

1. **首选**：在客户端卸载或清理那个软件（根因）
2. **次选**：在 MosDNS 侧把该域名加入拦截（返回 0.0.0.0）—— 只为消噪，不解决根因
3. **不要**：改 Mihomo 规则、改 DNS 上游、改 log-level

**教训**

`漏网之鱼` + `can't resolve ip` 的组合几乎总是客户端行为。它不消耗代理流量、不影响其它设备，**优先级低**。

---

## 案例 C：上游 DoH 抖动 —— 观察不修

| 项 | 内容 |
|---|---|
| 时间 | 2026-10-13 16:48 → 2026-10-15 16:36 |
| 次数 | 67 |
| 现状 | 最近 24 小时窗口内**已归零** |
| 结论 | 上游侧短暂故障，已被同组 UDP 兜住。**未改配置** |

**现象**

```
WARN domestic doh/upstream.go:116 exchange failed
  {"error": "bad http status codes 500 with body [No response\n]"}
```

**取证过程**

1. 按时间排序：67 条全部集中在两天内，之后无新增。
2. 该组配置为 `concurrent: 3`，池中共 5 个上游（`udp://223.5.5.5`、`tcp://223.5.5.5`、`https://dns.alidns.com/dns-query`、`tls://223.5.5.5`、`udp://202.96.128.86`）。DoH 失败时 UDP 上游仍在正常工作，**用户无感**。
3. 用户侧无任何解析异常投诉。

**为什么当时不该动**

- 1 小时窗口内已无该签名 → 不是"仍在发生"
- 同组还有 4 个上游兜底 → 无可观测影响
- 贸然移除 DoH 会降低抗污染能力

**复发的判据**

只有同时满足才处理：① 该签名出现在 1 小时窗口 ② 同一时段出现解析超时或 SERVFAIL 升高。处置方式是在 WebUI 移除该 DoH 上游，或在 `upstream_overrides` 里把它 `enabled: false`。

---

## 案例 D：MosDNS `:9099` 无认证暴露（安全）

| 项 | 内容 |
|---|---|
| 验证时间 | 2026-10-18 |
| 验证方式 | 从局域网另一台主机发起只读 GET |
| 结论 | 模板默认行为，**属设计现状**，需用户自行收敛暴露面 |

**验证**

```
GET http://<MSF主机>:9099/api/v2/audit/stats      → 200（无任何凭据）
GET http://<MSF主机>:9090/                        → 401（Mihomo 配了 secret）
```

**风险**

同网段任意设备可以：
- 读取全部 DNS 查询记录（等同于看到每台设备访问过哪些域名）
- `POST /plugins/switch1..15/post` 改分流开关
- `POST /plugins/blocklist/post`、`/client_ip/post` 改名单
- `POST /api/v1/system/restart` 重启 MosDNS

**处置**

会话内**只报告不修改**（属 T3/T4）。建议用户用宿主防火墙限制来源，或把该端口收进管理网段。

---

## 案例 E：`proxy-providers` 健康检查地址被强制还原（上游缺陷）

| 项 | 内容 |
|---|---|
| 上游 Issue | [scoltzero/msf#22](https://github.com/scoltzero/msf/issues/22) |
| 结论 | 上游硬编码，**不要在本地打补丁** |

**机制**

`configs/mihomo/config.yaml` 是**运行时副本**。每次 MSF 启动或触发订阅同步，都会用 `renderProxyProvidersYAML` 重新生成 `proxy-providers` 段并覆盖它——其中的 `health-check.url` 是字符串常量。

**正确做法**

- 改 Mihomo 配置走**用户配置**（`user_configs/*.yaml`）或 WebUI
- 想让测速地址可持久化，等上游支持；或在 WebUI 的「延迟测试地址」里改（那是另一套设置，存在数据库，不会被覆盖）
- **不要**直接改二进制、不要直接改运行时副本

---

## 案例 F：随机子域名把上游拖到 5 秒超时 —— 值得修

| 项 | 内容 |
|---|---|
| 状态 | 反复出现，跨越 10-11 / 10-14 / 10-15 多天 |
| 结论 | **值得修**：在 MosDNS 侧拦掉该域族 |

**现象**

```
[ MOS ] udp_all  8efb7a69ff363ea9a8602640620c5b99.jddebug.com.  5.000149018s  ✗ context deadline exceeded
[ MOS ] udp_requery  163510b89a05b4f76a985c95da5b0d12.jddebug.com.  5.000648943s  ✗ context deadline exceeded
```

**取证过程**

1. `log-correlate.sh <host> jddebug --all` 把三个来源按时间合并，看到耗时精确停在 **5.000s**：

```
10-11 20:45:54.280  [MOS]  udp_all  <32位哈希>.jddebug.com.  5.000940312s  ✗ context deadline exceeded
10-14 04:31:11.330  [MOS]  udp_requery  <32位哈希>.jddebug.com.  5.000648943s  ✗ context deadline exceeded
```

2. 每条的子域名都是**随机哈希**（`88bd8779d7f457b53bc705f5eb0e07b5` 之类），父域 `jddebug.com` 是京东系的调试/埋点域。

3. 审计缓冲里同名查询的响应码是 `SERVFAIL`、耗时 `2940ms` —— 权威侧本来就答不出来。

**为什么这是真问题**

`5.000s` 不是巧合，是 `forward` 插件的**单次查询预算上限**。也就是说每个这样的请求都：

- 占住一个并发槽整整 5 秒
- `concurrent: 3` 的池子被这类请求占满时，**真实解析被排队拖慢**
- 用户可感知的表现是"偶尔打开网页卡一下"，很难自己归因到 DNS

**处置**

在 MosDNS 拦截该域族（T3，改配置需先同意），让它立刻返回而不是等 5 秒：

```yaml
# 加入拦截列表（domain_set 或 blocklist 插件）
+.jddebug.com
```

判据：改完重跑 `log-correlate.sh <host> jddebug`，该签名应消失；同时 `log-triage.sh` 里 `未命中`/`unmatched_rule` 不会因此升高（拦截发生在规则之外）。

**教训**

- 耗时**恰好**落在某个整数（5.000s / 1.200s）上是超时封顶，不是"慢"，别去查网络质量
- `SERVFAIL` + 随机子域名 = 埋点域名的垃圾查询，且**不会自己变好**
- 这类才是"该修"的：仍在发生 + 有可观测影响（拖慢并发池）+ 根因清楚

---

## 案例 G：订阅里的占位节点 —— 想修但修不了

| 项 | 内容 |
|---|---|
| 状态 | 持续存在 |
| 结论 | **技术上无法在本地持久修复**，只能上报或忽略 |

**现象**

MosDNS 日志里 `sub.info.node.` 出现 173 次 `transport has been closed`，是当时 MosDNS 签名排行的第二名。

**取证过程**

1. 该域名在订阅文件里被当作节点服务器：

```yaml
# proxy_providers/Dmit.yaml
- name: "📅过期时间 2027-07-30"
  type: ss
  server: sub.info.node          # ← 不存在的占位域名
  port: 443
  password: SubInfoNode
  cipher: aes-128-gcm
- name: "⌛剩余流量 187.71GB"
  server: sub.info.node          # ← 同上
```

2. 这是机场的常见做法：用假节点把"到期时间 / 剩余流量"显示在客户端节点列表里。MSF 把它们当真实节点导入了。

3. 后果：参与 `url-test` 优选永远失败、每次被选中触发一次 DNS 解析失败。

**为什么修不了**

原计划给 provider 加 `exclude-filter` 排除这两个名字。核代码后发现不可行：

```go
// configgen.go
func replaceMihomoProxyProviders(content, providersYAML string) string {
    return replaceTopLevelYAMLBlock(content, "proxy-providers", providersYAML)
}
```

`proxy-providers` 是**整块替换**——启动和每次订阅同步都会重新渲染整段，任何手写的 `filter` / `exclude-filter` / 自定义 `health-check` 都会消失。与 [#22](https://github.com/scoltzero/msf/issues/22) 同一个根因。

**处置**

- **不要**改运行时副本（改了会被覆盖，还会误以为生效）
- **不要**改二进制
- 正确路径：等上游支持 provider 级字段，或让机场别下发占位节点
- 影响有限：只增加日志噪音与少量健康检查开销，不影响实际分流

**教训**

动手前先确认"这个改动能活过下一次重生成"。凡是被 `render*` 系列函数生成的配置段，**手改一律无效**。

---

## 新案例模板

```markdown
## 案例 X：<一句话结论>

| 项 | 内容 |
|---|---|
| 时间 | |
| 影响量 | |
| 现状 | 仍在发生 / 已恢复 |
| 结论 | 修 / 不修 |

**现象**（原始签名，去掉可变部分）

**取证过程**（每条命令 + 得到什么 + 排除了什么）

**根因**

**处置**（含"不要做什么"）

**教训**（下次怎么更快判断）
```
