# 首次配置与凭据

## 核心原则

**永远不要在对话里向用户索要密码。**

密码一旦进入聊天，就会被写进会话记录、作为上下文发送给模型提供方，并可能出现在导出日志里——即使事后改密码，已落盘的那份也追不回来。这是不可逆泄露。

MSF 自己的内置助手提示词也明确写了「`prompt` 不得包含密钥」。外部 agent 更应如此。

## 第一步：问对问题

**不要问「本地还是局域网」。** 这个说法有歧义——用户会理解成"MSF 是不是装在家里"，而真实需要区分的是：

> MSF 是否运行在**当前这个 agent 所在的同一台机器**上？

- **是（同机）**：直接 `http://127.0.0.1:7777`，宿主操作走本地 shell / sudo
- **否（远程）**：需要 host、user、port，走 SSH + HTTP

判断错这一步，后面所有命令的路径与地址都是错的。

## 第二步：探测部署形态

不要问用户，直接查（详见 `environment.md`）：

```bash
curl -s http://<host>:7777/api/v1/setup/privilege
```

## 第三步：建立凭据（两条独立通道）

### 通道 A：HTTP API 令牌（首选）

MSF 的 API Token 有 **三档作用域**，能力差别很大：

| 作用域 | 能做什么 | 不能做什么 |
|---|---|---|
| `read` | 状态 / 概览 / 流量 / 统计 / 日志 / 监控 / 服务 / 版本 | **看不到代理组、节点、连接、规则、配置树** |
| `operate` | 绝大多数读写端点 | 用户管理、系统设置、API 令牌、工厂重置、许可激活 |
| `admin` | 全部 | — |

**重要：`read` 比想象中窄。** 它放行的只有这些前缀：

```
/api/v1/monitor        /api/v1/services       /api/v1/logs
/api/v1/network/runtime
/api/v1/mosdns/{status,overview,stats,metrics,version,logs,query-log,audit,upstream/stats}
/api/v1/mihomo/{status,overview,dashboard,summary,stats,traffic,logs}
/api/v1/proxy/{status,overview,stats,traffic,logs}
```

**不在列表里的**：`mihomo/proxies`、`mihomo/connections`、`mihomo/rules`、`mosdns/rules`、`mosdns/system/*`、`config/tree`。

也就是说：**要诊断「节点为什么连不上」「这条流量命中哪条规则」，`read` 令牌会直接 403。**

推荐配置：

```
日常诊断 + 受控运维  → scope=operate
纯只读巡检          → scope=read（能力受限，但权限更小）
永远不要用 admin    → 它能签发新令牌、改用户，泄露等于永久后门
```

**令牌怎么给**：让用户自己在 WebUI 的「API Token」页面创建，然后：

- 有 TTY：用 `read -s` 之类的方式在终端里读入，不经过对话
- 无 TTY：由 `scripts/bootstrap.sh` 提示，或让用户写入文件

存放位置：`~/.config/msf-skill/token`，权限 `0600`。

### 通道 B：SSH 密钥（仅宿主层检查需要）

只用于 API 表达不了的检查：nftables、systemd、二进制完整性、磁盘、sysctl。

**用专用密钥，不要复用用户个人的 `id_rsa`：**

```bash
ssh-keygen -t ed25519 -f ~/.ssh/msf_skill_ed25519 -C "msf-skill" -N ""
ssh-copy-id -i ~/.ssh/msf_skill_ed25519.pub <user>@<host>
```

`ssh-copy-id` 会**自己在终端里问密码**，agent 只看得到退出码——密码不进上下文。

**主机密钥校验**：使用 `-o StrictHostKeyChecking=accept-new` 并在首次连接后记录指纹。**不要用 `StrictHostKeyChecking=no`**，那等于放弃 MITM 防护。

**root 不一定能登录**：现代发行版默认 `PermitRootLogin prohibit-password`。向导必须支持「普通用户 + sudo」分支：

```bash
ssh -i ~/.ssh/msf_skill_ed25519 -o StrictHostKeyChecking=accept-new <user>@<host> \
  'sudo -n true && echo sudo-ok || echo sudo-needs-password'
```

若 sudo 需要密码，提示用户配置 `NOPASSWD` 或改用 root 密钥登录，不要把 sudo 密码交给 agent。

## 第四步：风险告知（强制，不可跳过）

在写入任何配置前，向用户明确说明：

1. **SSH 密钥 = 免密登录权限**。任何能读到该私钥的进程都能登录这台机器。
2. **代理平台是全网单点故障**。错误改动可能让整个局域网断网。
3. **T4 操作不可逆**（工厂重置、卸载）。
4. **日志含隐私**：客户端 IP、访问域名、可能的查询串令牌。
5. 建议**优先同机部署**，避免把 root 凭据暴露在网络路径上。

用户需逐字确认后才继续。

## 第五步：落盘

```json
// ~/.config/msf-skill/profile.json  权限 0600
{
  "version": 1,
  "name": "default",
  "mode": "remote",              // local | remote
  "host": "10.0.0.10",
  "port": 7777,
  "ssh_user": "root",
  "ssh_key": "~/.ssh/msf_skill_ed25519",
  "ssh_host_fingerprint": "SHA256:...",
  "deploy_kind": "systemd",      // systemd | docker | unraid | fnos | macos
  "token_scope": "operate",
  "created_at": "2026-10-18T12:00:00+08:00"
}
```

**绝对不要写入的字段**：`password`、`token` 明文（令牌单独存 `token` 文件）、任何私钥内容。

## 多实例

支持命名 profile：`~/.config/msf-skill/profiles/<name>.json`，默认取 `default`。非交互环境用环境变量指定：

```bash
MSF_SKILL_PROFILE=home bash scripts/msf-health.sh
```

## 无 TTY / CI 环境

- 跳过所有交互式提问
- 从 `MSF_SKILL_PROFILE` 或 `~/.config/msf-skill/profile.json` 读取
- 只允许 T0/T1（探测与只读）；检测到需要 T2 以上直接失败并说明原因

## 卸载

```bash
# 1) 从服务器移除本 skill 的公钥行
ssh <user>@<host> "sed -i '/msf-skill$/d' ~/.ssh/authorized_keys"

# 2) 吊销 API 令牌（WebUI → API Token → 删除）

# 3) 删除本地凭据
rm -rf ~/.config/msf-skill ~/.ssh/msf_skill_ed25519 ~/.ssh/msf_skill_ed25519.pub
```
