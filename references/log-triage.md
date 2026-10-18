# 日志分诊与有据修复

> 本文中 `$DATA` 指 MSF 数据目录：systemd 为 `/opt/msf`，fnOS 为 `/var/apps/msf/var`，Unraid 为 `/mnt/user/appdata/msf`，macOS 为 `/Library/Application Support/MSF`。

## 一、核心立场

**不是所有 WARN 都需要修。** 一个正常运行中的 MSF 每天产生几千条 WARN 是常态，其中绝大多数是客户端行为、目标侧问题或已恢复的历史事件。

改错配置的代价远大于忽略一条警告：一次错误的 DNS 上游改动可以让整个局域网解析变慢，一次错误的规则调整可以让所有代理断掉。

因此本 skill 的默认动作是 **分诊（不修）**，只有同时满足以下三条才进入修复：

1. **仍在发生**（最近 1 小时窗口内仍有）
2. **有可观测影响**（用户能感知的故障，或持续消耗资源）
3. **根因已定位且有证据**（能回答"你怎么知道是这个原因"）

缺任一条 → 只报告，不动手。

## 二、三步分诊法

### 第一步：归一化聚合（把噪音变成签名）

原始日志每行都不同（IP、端口、耗时、trace id 都在变），必须先归一化才能看出模式。

```bash
bash scripts/log-triage.sh <host>
```

输出四块：

| 区块 | 内容 |
|---|---|
| 仍在发生 | 最近 1 小时窗口内仍出现的签名，按频次排序 |
| 仅 24 小时 | 24 小时出现过、1 小时已无 —— **已恢复，不要动** |
| 与基线对比 | 相比历史基线的 `NEW` / `xN` 突增 / `GONE` 消失 |
| 平台与重启 | MSF error/warn 计数、MosDNS 终止次数、Mihomo 启动次数、systemd 重启次数、MosDNS 启动时间 |
| DNS 审计 | 命中分布（domain_set）、客户端查询量、最慢查询、非 NOERROR 采样 |

### 基线机制

单看"现在有多少"没有意义，要看"比平时多了多少"。

```bash
bash scripts/log-triage.sh <host> --baseline-save   # 把当前分布存为基线
bash scripts/log-triage.sh <host>                   # 之后每次自动对比
bash scripts/log-triage.sh <host> --no-baseline     # 本次跳过对比
bash scripts/log-triage.sh <host> --no-audit        # 跳过 DNS 审计（省时间）
```

基线存于 `~/.config/msf-skill/baseline.tsv`。**建议在系统运行平稳时建一次**，之后每次分诊都会标出：

| 标记 | 含义 |
|---|---|
| `NEW` | 基线里没有、现在 24h ≥ 5 次 —— 新出现的问题 |
| `x2.0+` | 相比基线翻倍以上且 ≥ 5 次 —— 突增 |
| `GONE` | 基线里有、现在消失 —— 已恢复或已下线 |

阈值（≥5 次、×2）是为了滤掉低频抖动；如环境本身噪音大，可在脚本里调整。

### DNS 审计维度

除了文本日志，MosDNS 的审计缓冲能回答"解析到底命中哪条规则"：

```bash
curl -s 'http://<host>:9099/api/v2/audit/rank/domain_set'
curl -s 'http://<host>:9099/api/v2/audit/rank/client'
curl -s 'http://<host>:9099/api/v2/audit/rank/slowest'
```

`domain_set` 的分布很能说明问题：

- `白名单` 占绝大多数 → 正常（大部分流量是直连）
- `unmatched_rule` 偏高 → 分流规则覆盖不足，大量域名落到兜底
- `未命中` / `BANHTTPS` 异常升高 → 规则或开关最近被改过

最慢查询持续停在 `~5000 ms` 是**上游超时的封顶值**（例如 `5s` 超时），不是真的有查询跑了 5000 秒。

审计缓冲是环形内存（默认 10 万条），超出后最旧的被丢弃；`rank/*` 是对当前缓冲的整体统计，**不是时间窗内的**。

也可以手动做聚合：

```bash
# Mihomo：按「组 → 目标 → 错误类别」聚合
grep -E 'level=(warning|error)' $DATA/logs/mihomo.out.log \
| sed -n 's/.*time="\([^"]\{19\}\)[^"]*".*msg="\(.*\)"$/\1|\2/p' \
| sed -n 's/.*dial \([^(]*\) (match \([^)]*\)).*--> \([^ ]*\) error: \(.*\)$/\1|\3|\4/p' \
| awk -F'|' '{d=$2; sub(/:.*/,"",d); e=$3; sub(/\\\\n.*/,"",e); gsub(/[0-9]+/,"N",e); sub(/:.*/,"",e); print $1" → "d" | "e}' \
| sort | uniq -c | sort -rn | head -20
```

### 第二步：时间窗对比（区分"还在发生"与"已经过去"）

**这是最关键的一步，也是大多数误修的来源。**

```
1h 与 24h 都排前列  → 仍在发生，值得归因
仅 24h 出现，1h 无  → 已恢复，不要动配置
仅 all 出现         → 历史事件，可能已在上游修复
```

时间戳是带固定偏移的 ISO-8601，可以直接做字符串比较：

```bash
CUT=$(date -d '1 hour ago' +%Y-%m-%dT%H:%M:%S)
awk -v cut="$CUT" '{ ts=substr($0,1,19); if (ts >= cut) print }' $DATA/logs/mihomo.out.log
```

### 第三步：归因五问

对每个"仍在发生"的签名，逐条回答：

| # | 问题 | 数据来源 |
|---|---|---|
| 1 | **谁发起的？** 客户端 IP 还是系统组件 | Mihomo 日志行内的 `源IP:端口`；MosDNS 审计 `client_ip` |
| 2 | **目标是什么？** 域名 / IP / 端口 | 日志中的 `--> 目标` |
| 3 | **命中了哪条规则？** 哪个组 / RuleSet | 日志中的 `(match RuleSet/xxx)` 或 `(match Match/)` |
| 4 | **失败在哪一层？** DNS 解析 / TCP 连接 / TLS / 认证 | 错误文本：`can't resolve ip` / `dial tcp` / `EOF` / `connection refused` |
| 5 | **是持续还是已恢复？** | 第二步的时间窗对比 |

五问都答不上来的，就是**证据不足，不允许修**。

## 三、决策矩阵

| 归因结论 | 该修吗 | 修哪里 |
|---|---|---|
| 域名本身不存在（NXDOMAIN），客户端在反复重试 | 通常**不修** | 首选在**客户端**卸载残留软件；若无法处理，才在 MosDNS 侧加黑名单消噪 |
| 节点服务器 `connection refused`（整机不可达） | **不改配置** | 换节点或等上游恢复；这是机场故障 |
| 节点 `EOF` / `reset by peer` / `deadline exceeded` | **改选择** | 换节点；或调整组的 `url-test` 容差 |
| 直连目标 `i/o timeout` / `connection refused` | **不修** | 目标服务已下线或无响应，规则判定是正确的 |
| MosDNS 上游 DoH 返回 500 / 超时，且持续 | **改上游** | 在 WebUI 移除该 DoH，保留 UDP 上游 |
| `connection ctx canceled` / `use of closed network connection` | **不修** | 客户端并发后主动关闭，属正常 |
| `signal received terminated` 但次数与重启次数吻合 | **不修** | 正常重启 |
| `signal received terminated` 远多于重启次数、且服务时间短 | **查崩溃** | 看是否 OOM、配置校验失败、端口冲突 |
| MSF 平台 `level=error` 有稳定复现 | **修** | 按 `msg` 定位；注意配置校验失败时面板仍会启动 |
| 单客户端高频、其他客户端正常 | **查客户端** | 不是 MSF 的问题 |

## 四、真实签名目录

以下是**从生产日志实测**归纳的签名，不是假设。

### Mihomo

| 签名 | 真实含义 | 判定 |
|---|---|---|
| `漏网之鱼 → <域名> \| can't resolve ip: couldn't find ip` | 域名无 A/AAAA 记录，上游返回 NXDOMAIN，无法还原 IP，落入兜底规则 | **通常不修**。先查客户端 |
| `<组> → <域名> \| <节点主机>:<端口> connect error: connection refused` | 节点服务器整机拒绝连接（服务挂了或端口关闭） | 不改配置，**换节点 / 等恢复** |
| `<组> → <域名> \| <节点主机>:<端口> connect error: EOF` | 节点建立了 TCP 但对端立刻关闭 | 节点异常，换节点 |
| `<组> → <域名> \| <节点主机>:<端口> connect error: context deadline exceeded` | 节点握手超时 | 节点拥塞或被限速 |
| `<组> → <域名> \| ... read: connection reset by peer` | 对端重置连接 | 常见于被干扰或限速 |
| `全局直连 → <IP> \| dial tcp ...: i/o timeout` | 直连目标端口无响应 | **目标侧问题**，规则没错 |
| `全局直连 → <IP> \| dial tcp ...: connection refused` | 目标主动拒绝 | **目标服务已关** |
| `全局直连 → <域名> \| dns resolve failed: couldn't find ip` | 本应直连但域名解析失败 | 查该域名的解析链路 |
| `Mihomo shutting down` / `Start initial configuration` | 正常启停 | 与重启次数对照 |

> 节点错误的格式是 `<服务器域名>:<端口> connect error: dial tcp <解析到的IP>:<端口>: ...`。
> 中间那一串多行 `dial tcp ...` 是同一节点的多个 A 记录依次尝试失败，**不代表多个问题**。

### MosDNS

| 签名 | 真实含义 | 判定 |
|---|---|---|
| `tcp_all ... failed to write response ... use of closed network connection` | 响应时客户端已关连接 | **不修** |
| `... "error": "connection ctx canceled"` | 客户端并发查询后主动放弃其余 | **不修**（看 `elapsed` 是否仅几微秒） |
| `udp_*/tcp_* ... "use of closed network connection"`（集中在某几个端口，且伴随 `signal received`） | 服务关闭时各监听器收尾 | **不修**，是重启的一部分 |
| `domestic doh/upstream.go: exchange failed {"error": "bad http status codes 500 ..."}` | DoH 上游返回 HTTP 500 | 观察是否**持续**；持续则移除该 DoH |
| `domestic ... "http request failed: context deadline exceeded"` | DoH 上游超时 | 同上 |
| `coremain/run.go: signal received {"signal": "terminated"}` | 收到终止信号（重启/停服） | 与重启次数对照，不是崩溃 |
| `sb_udp ... "error": "transport has been closed"` | 代理核心查询节点域名时 UDP 传输被关闭 | 通常不修 |

### MSF 平台

MSF 主日志正常情况下应该**几乎没有** `level=error`：

```bash
grep -c '"level":"error"' $DATA/logs/msf.log
```

非零且稳定复现 → 必查。注意 MSF 的设计：配置校验失败时**面板仍会启动**，错误会出现在 `startup-issues` 而不是日志里：

```bash
curl -s -H "Authorization: Bearer $TOKEN" http://<host>:7777/api/v1/system/startup-issues
```

## 五、取证的固定动作

修复前必须能拿到这些证据，缺一项就不要改：

```bash
# 1) 域名是否真的不存在（多上游交叉验证，避免单上游误判）
for u in 223.5.5.5 119.29.29.29 8.8.8.8; do
  printf '%-16s ' "$u"; dig +short +time=3 @$u <域名> A | tr '\n' ' '; echo
done
# 三处都空 = 域名确实无记录

# 2) 节点端口是否可达（从 MSF 主机发起）
for p in <端口>; do timeout 5 nc -z <节点IP> $p && echo "$p open" || echo "$p closed"; done

# 3) 谁在发请求（MosDNS 审计缓冲，含 client_ip）
curl -s 'http://<host>:9099/api/v2/audit/logs?page=1&page_size=50' \
  | python3 -c 'import sys,json;[print(x["client_ip"],x["query_name"],x["response_code"]) for x in json.load(sys.stdin)["logs"]]'

# 4) 该请求命中了哪条规则（Mihomo 日志里的 match 部分）
grep '<域名>' $DATA/logs/mihomo.out.log | tail -1 | sed 's/.*msg="//' | cut -c1-160
```

审计缓冲上限 100000 条、每页最多 50 条，高频域名也可能落在窗口外——**查不到不等于没发生**，要用 Mihomo 日志交叉验证。

## 六、修复协议

一旦决定修，按这个顺序，**一次只改一个变量**：

1. **写清三段论**：现象 → 证据 → 推断的根因。缺证据就是猜。
2. **选择正确的层**：
   - 客户端行为 → 改客户端，不改 MSF
   - 上游/节点故障 → 换选择，不改链路配置
   - 真正的配置错误 → 改配置，且走 WebUI 或领域 API
3. **备份**：用平台自带的 `GET /api/v1/config/backups`，不要手写 `cp`
4. **改**（T3 需用户同意 + 差异预览）
5. **复验**：改完必须重新跑一次分诊，确认目标签名在 1h 窗口内归零或显著下降
6. **记录**：把案例写进 `references/incidents.md`（现象、证据、根因、处置、复验结果）

**禁止的修法**（见过太多次）：

| 错误动作 | 为什么错 |
|---|---|
| 看到 `can't resolve ip` 就去改 DNS 上游 | 域名本身不存在，改上游没用 |
| 看到 `i/o timeout` 就换节点 | 直连目标超时与节点无关 |
| 看到 `connection ctx canceled` 就调低上游并发 | 这是客户端行为，不是并发问题 |
| 看到 WARN 多就把 `log-level` 调成 silent | 掩盖问题，下次真故障看不见 |
| 直接改 `config.yaml`（运行时副本） | 会被重新生成覆盖 |
| 为了让日志"干净"而加一堆黑名单 | 掩盖真实问题，且规则会腐化 |

## 七、案例

完整案例（含原始日志、取证命令、排除过程）在 [`incidents.md`](incidents.md)。速查：

| 案例 | 签名特征 | 判定 |
|---|---|---|
| 机场整机故障 | 节点主机 `:端口 connect error: connection refused`，多个 IP 全拒 | **不修**，换节点 / 等恢复 |
| 客户端残留域名 | `漏网之鱼 → <域名>` + `can't resolve ip`，三上游全 NXDOMAIN | **不修 MSF**，查客户端 |
| 上游 DoH 抖动 | `doh/upstream.go: exchange failed ... http status codes 500` | 观察；持续才换上游 |
| `:9099` 无认证 | 非日志问题，体检发现 | 只报告，不动配置 |
| 测速地址被还原 | 改 `config.yaml` 重启后回退 | 上游缺陷，走 user_configs |

## 八、报告格式

分诊结果按这个结构给，不要贴原始日志：

```
日志分诊（窗口：最近 1 小时 / 24 小时）

仍在发生
  [高] <签名> — N 次/小时，来源 <客户端/组件>，根因 <归因>，建议 <动作>
  [低] <签名> — 目标侧问题，无需处理

已恢复（不要动）
  <签名> — 最后出现 <时间>，已持续 <时长> 无新增

良性噪音（不必处理）
  <签名> — 原因

需要取证才能判断
  <签名> — 缺少 <哪项证据>
```

每条都必须能回答"你怎么知道"，答不出就归到"需要取证"。
