# API 端点分层

MSF 当前版本约有 **386 条** API 路由。不要试图全部记住或全部调用——按层取用，且先确认凭据作用域够不够。

## 认证

| 方式 | 用法 | 适用 |
|---|---|---|
| 免认证 | 直接 GET | `version`、`setup/check`、`setup/system-info`、`setup/network-interfaces`、`setup/privilege`、`setup/preflight`、`setup/reset/status`、`auth/login`、`auth/refresh` |
| JWT | `POST /api/v1/auth/login` → `access_token` | 交互式会话 |
| API Token | `Authorization: Bearer <token>` | 自动化（推荐） |

令牌作用域差异很大，动手前先看 `credentials.md` 的作用域表。**`read` 令牌看不到代理组、节点、连接、规则。**

## 未知路径怎么办

不要猜。虽然外部 agent 没有内置助手的 `list_msf_api` 工具，但可以：

1. 先在本文档里按业务域找
2. 用 OPTIONS / GET 探测是否存在（401/403 说明存在但无权限，404 说明路径错）
3. 让用户在 WebUI 操作一遍，用 `msf.log` 里的请求记录反查真实路径

---

## T0 探测（免认证）

```bash
GET /api/v1/version
GET /api/v1/setup/check
GET /api/v1/setup/system-info
GET /api/v1/setup/network-interfaces
GET /api/v1/setup/privilege        # is_root / docker / macos
GET /api/v1/setup/preflight
```

## T1 只读诊断

### 平台与资源
```bash
GET /api/v1/daemon/status
GET /api/v1/monitor/system
GET /api/v1/monitor/hardware
GET /api/v1/monitor/resources
GET /api/v1/monitor/network
GET /api/v1/monitor/stats
GET /api/v1/monitor/history
GET /api/v1/system/diagnostics
GET /api/v1/system/startup-issues
GET /api/v1/network/runtime
GET /api/v1/network/info
```

### 服务
```bash
GET /api/v1/services
GET /api/v1/services/{name}
```

### 日志
```bash
GET /api/v1/logs
GET /api/v1/logs/{service}
GET /api/v1/logs/{service}/stats
GET /api/v1/logs/{service}/download
GET /api/v1/events/logs/{service}
```
`{service}` ∈ `msf` / `mosdns` / `mihomo`（以实际返回为准）

### MosDNS
```bash
GET /api/v1/mosdns/status
GET /api/v1/mosdns/overview
GET /api/v1/mosdns/stats
GET /api/v1/mosdns/metrics
GET /api/v1/mosdns/version
GET /api/v1/mosdns/query-log
GET /api/v1/mosdns/clients
GET /api/v1/mosdns/rules/{path...}
GET /api/v1/mosdns/rule-sets
GET /api/v1/mosdns/rule-sources
GET /api/v1/mosdns/system/switches
GET /api/v1/mosdns/system/feature-switches
GET /api/v1/mosdns/system/upstream-overrides
GET /api/v1/mosdns/system/forward-settings
GET /api/v1/mosdns/system/cache
GET /api/v1/mosdns/system/routing
GET /api/v1/mosdns/system/log-capacity
```

MosDNS 内部 API 在另一个端口，审计数据只能从这里拿：
```bash
GET http://<host>:9099/api/v2/audit/logs
GET http://<host>:9099/api/v2/audit/stats
GET http://<host>:9099/api/v2/audit/rank/domain
GET http://<host>:9099/api/v2/audit/rank/client
GET http://<host>:9099/api/v2/audit/rank/slowest
GET http://<host>:9099/api/v2/audit/rank/domain_set
```

### Mihomo
```bash
GET /api/v1/mihomo/status
GET /api/v1/mihomo/overview
GET /api/v1/mihomo/traffic
GET /api/v1/mihomo/proxies            # 代理组与节点（read 作用域不可用）
GET /api/v1/mihomo/proxies/{group}    # 单组延迟测试
GET /api/v1/mihomo/connections        # 实时连接（read 作用域不可用）
GET /api/v1/mihomo/rules              # 规则
GET /api/v1/mihomo/rule-providers
GET /api/v1/mihomo/proxy-providers
GET /api/v1/mihomo/config
GET /api/v1/mihomo/config/files
GET /api/v1/mihomo/user-configs
GET /api/v1/mihomo/version
```

### 配置
```bash
GET /api/v1/config/tree
GET /api/v1/config/file?path=...
GET /api/v1/config/backups
GET /api/v1/history
GET /api/v1/history/compare
GET /api/v1/history/{id}
```

---

## T2 受控运维（需确认）

```bash
POST /api/v1/services/{name}/restart
POST /api/v1/daemon/restart
POST /api/v1/daemon/stop
POST /api/v1/mihomo/connections/{id}/close
DELETE /api/v1/mihomo/connections
POST /api/v1/system/diagnostics/run
POST /api/v1/mihomo/proxies/{group}/delay      # 触发测速
POST /api/v1/mihomo/proxy-providers/{name}/update  # 刷新订阅
POST /api/v1/mosdns/system/cache/clear         # 清缓存
```

## T3 配置变更（需确认 + 差异预览 + 回滚点）

```bash
PUT  /api/v1/config/file                    # 通用文件写入（危险，优先用领域 API）
PUT  /api/v1/mosdns/rules/{path...}
PUT  /api/v1/mosdns/system/upstream-overrides
PUT  /api/v1/mosdns/system/switches
PUT  /api/v1/mihomo/user-configs/{name}
PUT  /api/v1/mihomo/rules
PUT  /api/v1/mihomo/proxy-providers/{name}
```

**原则**：能用领域 API 就不要用通用文件写入。

## T4 危险（须显式加载 `dangerous.md`）

```bash
POST /api/v1/setup/reset          # 工厂重置
POST /api/v1/update/apply         # 应用更新
DELETE /api/v1/users/{id}
POST /api/v1/api-tokens           # 签发新令牌
```

---

## 调用纪律

1. **先读后写**：任何写操作前，先 GET 同一资源确认当前值
2. **不要循环重试写操作**——失败先看错误码，4xx 重试没有意义
3. **写操作后复验**：GET 回读，确认目标状态
4. **响应不要原样贴给用户**：归纳结论，只引用必要字段
5. **404 vs 403**：404 是路径/资源不存在，403 是作用域不够——两者的处置完全不同
