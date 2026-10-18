# MSF Skill

给**外部 AI agent** 用的 MSF 运维技能包。

[MSF](https://github.com/scoltzero/msf) 是一个自托管的 **MosDNS + Mihomo 管理平台**，通常部署为局域网旁路由（DNS 智能分流 + 透明代理）。本仓库把这个平台的运维知识、排障手册和安全边界打包成一个符合 [Agent Skills 开放标准](https://agentskills.io/home) 的 skill，可被 Claude Code、Cursor、Codex、OpenClaw、Hermes、DeepSeek Harness 等支持该标准的 agent 直接加载。

> **非官方项目。** 与 MSF 官方无隶属、赞助或背书关系，仅作兼容性说明。
> MSF 本体采用 GPL-3.0；本仓库为独立撰写的文档与脚本，采用 MIT-0。

---

## 为什么需要它

MSF 的运维有几个**反直觉**的点，没有背景知识很容易误判：

- **三方分工容易搞混**：MSF 只做编排（生成配置、看住进程、写 nft），MosDNS 才是 DNS 分流大脑，Mihomo 才是代理执行器。面板正常 ≠ 网络正常
- 日志有**四个独立维度**，看错一个就会把正常的客户端行为当成故障
- `config.yaml` 是**运行时副本**，直接改会被服务重新生成覆盖
- `read` 作用域的 API 令牌**看不到节点、连接、规则**——诊断时会莫名 403
- Docker 部署**没有 nftables**，按 Linux 思路查 nft 只会得到假故障
- **数据目录随部署形态变化**，fnOS / Unraid / macOS 都不是 `/opt/msf`
- **nft 对入站 TCP 是全量 redirect**，国内网站打不开也可能是 Mihomo 规则写错
- **游戏每 30–40 秒掉线**通常是 UDP 端口未加入内核 bypass（Mihomo 隧道有 60 秒空闲超时）
- 多数"上不了网"其实是**主路由的静态路由或 DHCP 配置**问题，不在 MSF 上

这个 skill 把这些固化成可加载的流程，而不是每次从零推导。三方联动的完整链路见 [`references/integration.md`](references/integration.md)。

---

## 安装

标准是通用的，但各 agent 的目录约定不同。

### 通用（推荐）

```bash
git clone https://github.com/nasvip/msf-skill.git ~/.agents/skills/msf-skill
```

`~/.agents/skills/` 是多个 agent 共同认可的中立路径（Cursor、Amp、Replit、DeepSeek Harness 等原生读取）。

### 按 agent

| Agent | 安装位置 / 命令 |
|---|---|
| **DeepSeek Harness** | 克隆到 `~/.agents/skills/msf-skill`（原生读取） |
| **Cursor** | `~/.agents/skills/` 或 `~/.cursor/skills/`，也兼容 `.claude/skills/`、`.codex/skills/` |
| **Claude Code** | `git clone ... ~/.claude/skills/msf-skill` |
| **OpenClaw** | `git clone ... ~/.openclaw/skills/msf-skill` 或 `openclaw skills install git:nasvip/msf-skill@main` |
| **Hermes** | `git clone ... ~/.hermes/skills/msf-skill` 或 `hermes skills install https://raw.githubusercontent.com/nasvip/msf-skill/main/SKILL.md` |
| **Codex** | `git clone ... ~/.codex/skills/msf-skill` |
| **skills.sh 生态** | `npx skills add nasvip/msf-skill` |

装好后新开一个会话，agent 会自动发现。

**Windows 提示**：多个 agent 目录可以用目录联接共享同一份内容，改一处全局生效：

```cmd
mklink /J "%USERPROFILE%\.claude\skills\msf-skill" "%USERPROFILE%\.agents\skills\msf-skill"
```

---

## 首次使用

接入一个 MSF 实例需要一次配置。**本 skill 不接受、不保存、不传输任何密码。**

### 先自检

装好后先跑一次，它会告诉你缺什么：

```bash
bash scripts/selftest.sh --local     # 只查包完整性，不联网
bash scripts/selftest.sh             # 全量：加查 WebUI / MosDNS API / SSH / 远端依赖
bash scripts/selftest.sh 10.0.0.10   # 临时指定 host
```

检查项：frontmatter 合规、引用文件齐全、脚本语法与执行位、疑似凭据、profile 与令牌权限、WebUI 连通性、运行时形态、令牌作用域、MosDNS API 可达性、SSH 免密、数据目录、远端 `grep/sed/awk/curl` 等依赖。

每条失败都带修复建议，不会只说"错了"。

### 自动化脚本

```bash
# Linux / macOS / Git Bash
bash scripts/bootstrap.sh

# Windows
powershell -ExecutionPolicy Bypass -File scripts\bootstrap.ps1
```

脚本会：

1. 问「MSF 是否运行在当前这台机器上」（而不是含糊的"本地还是局域网"）
2. 探测部署形态（systemd / Docker / fnOS / macOS）
3. 展示风险并要求逐字输入 `accept`
4. 读取 API 令牌并校验
5. 生成**专用** SSH 密钥，用 `ssh-copy-id` 安装（密码由 ssh 自己在终端询问）
6. 落盘 `~/.config/msf-skill/profile.json`（0600）

### 凭据要点

| 通道 | 用途 | 注意 |
|---|---|---|
| **API 令牌** | 日常诊断与受控运维（首选） | `read` 作用域**看不到节点/连接/规则**；日常建议 `operate`；**不要用 `admin`** |
| **SSH 专用密钥** | 仅宿主层检查（nftables / systemd / 磁盘） | 用 `~/.ssh/msf_skill_ed25519`，不要复用个人 `id_rsa` |

详见 [`references/credentials.md`](references/credentials.md)。

### 手动配置

不想跑脚本就自己写 `~/.config/msf-skill/profile.json`：

```json
{
  "version": 1,
  "name": "default",
  "mode": "remote",
  "host": "10.0.0.10",
  "port": 7777,
  "ssh_user": "root",
  "ssh_key": "~/.ssh/msf_skill_ed25519",
  "deploy_kind": "systemd",
  "data_dir": "/opt/msf",
  "token_scope": "operate"
}
```

令牌单独放 `~/.config/msf-skill/token`（0600）。**不要写 `password` 字段。**

`data_dir` 随部署形态不同：fnOS 为 `/var/apps/msf/var`，Unraid 为 `/mnt/user/appdata/msf`，macOS 为 `/Library/Application Support/MSF`。不填时按 `deploy_kind` 推断。

---

## 能做什么

按**危险等级**分层，写操作永远需要明确同意：

| 层 | 范围 | 行为 |
|---|---|---|
| **T0** | 环境探测：版本、形态、权限 | 自动 |
| **T1** | 只读诊断：状态、四类日志、监控、连接、规则 | 自动 |
| **T2** | 受控运维：重启服务、清缓存、刷新订阅 | 先说明影响，取得同意 |
| **T3** | 配置变更：规则、上游、代理组、用户配置 | 差异预览 + 回滚点 + 同意 |
| **T4** | 重置、卸载、升级、切换网络模式 | 仅显式加载 `references/dangerous.md` 后，逐字确认 |

### 知识与流程

- **日志分诊**：把海量 WARN 归一化成签名，按时间窗区分「仍在发生 / 已恢复」，只修该修的
- **有据修复**：归因五问 + 取证固定动作，答不出证据就不允许改
- 四类日志的区分与定位（含"看着像故障其实不是"的清单）
- fake-IP / TProxy / nftables 链路断层定位
- 订阅、代理组、节点异常判断
- 配置体检：资源、上游冗余、缓存容量、参数一致性、安全暴露面
- 主路由接入核查（DHCP DNS、fake-IP 静态路由、IPv6 陷阱）
- 部署形态判定矩阵

### 日志分诊流程

```bash
bash scripts/log-triage.sh <host>

# 平稳运行时建一次基线，之后每次都自动标出突增
bash scripts/log-triage.sh <host> --baseline-save
```

输出：仍在发生 / 仅 24 小时（已恢复）/ 与基线对比（`NEW` `xN` `GONE`）/ 平台与重启痕迹 / DNS 审计（命中分布、客户端查询量、最慢查询、非 NOERROR 采样）。

输出每个日志源在**最近 1 小时**与**最近 24 小时**的签名排行，并给出重启痕迹。判据：

| 时间窗表现 | 含义 | 动作 |
|---|---|---|
| 1h 与 24h 都排前列 | 仍在发生 | 归因后决定是否修 |
| 仅 24h 出现、1h 无 | 已恢复 | **不要动配置** |
| 分散且低频 | 客户端行为噪音 | 不处理 |

核心立场：**不是所有 WARN 都要修。** 只有「仍在发生 + 有可观测影响 + 根因有证据」三条同时成立才动手。

### 跨日志时间轴

分诊出"仍在发生"之后，用它定位失败在哪一层：

```bash
bash scripts/log-correlate.sh <host> www.baidu.com
bash scripts/log-correlate.sh <host> 10.0.0.8 --all --limit 100
```

三个来源按时间合并：

| 标记 | 来源 | 意义 |
|---|---|---|
| `AUD` | MosDNS 审计缓冲 | DNS 阶段，**含正常解析**，有响应码与耗时 |
| `MOS` | MosDNS 文本日志 | 只有 WARN/ERROR，能看到上游超时与关闭 |
| `MIH` | Mihomo 日志 | 命中哪条规则、出站错在哪 |

`AUD` 正常 + `MIH` 超时 → 解析没问题、目标不可达；`AUD` SERVFAIL → 上游解析失败。一眼分开，不用猜。

## 不做什么

- **不提供代理节点、订阅或任何访问凭据**
- 不提供规避网络监管或访问控制的方案
- 不替代 MSF 内置 AI 助手（那套只适用于 MSF 自己的 WebUI agent）
- 不鼓励直接修改运行时副本或二进制——这类需求通常是上游缺陷，应提 issue

请在**你拥有或已获充分授权**的网络中使用。

## 覆盖范围与已知缺口

上游有约 **386 条** API 路由，本 skill 按"日常真正会用到"的原则覆盖了约 80 条，其余通过 WebUI 操作即可。

**已覆盖**：日志分诊与有据修复、部署形态与数据目录、CLI、端口全景、三方联动链路、四类日志定位、11 类故障场景、配置体检、主路由接入、凭据分层、危险区清单。

**尚未覆盖**（知道有缺口，比假装齐全更可靠）：

| 缺口 | 现状 |
|---|---|
| MosDNS DNS 学习 / requery 调度 | 未写。相关端点为 `/plugins/requery/*` 与 `mosdns_routing_scheduler` 设置 |
| 配置历史与回滚 | 只提了一句 `GET /api/v1/history`，未写 `compare` / 回滚流程 |
| 备份与恢复 | 只提了 `GET /api/v1/config/backups` |
| 组件更新（MosDNS / Mihomo / Zashboard 分别升级） | 未写 `/api/v1/component-updates` |
| 客户端管理与按 IP 分流的具体增删 | 只写了判定方式，未写增删流程 |
| geosite / rule-sets / rule-sources / AdGuard 规则的编辑 | 未写 |
| 用户与权限、审计日志 | 未写 |
| Zashboard（`:9090`）的用法 | 未写 |
| Linux TUN 模式的独立诊断路径 | 只在 Docker 段落提到 TUN |

遇到这些场景时，应按 `references/api-map.md` 的"未知路径怎么办"处理，或直接引导用户去 WebUI，不要凭猜测调用接口。

---

## 仓库结构

```
msf-skill/
├── SKILL.md                      入口：触发条件 / 日志分诊 / 三方分工 / 安全契约
├── references/
│   ├── log-triage.md             日志分诊方法、真实签名目录、决策矩阵、有据修复协议
│   ├── incidents.md              实战案例库（现象→取证→根因→处置→教训）
│   ├── integration.md            三方联动全链路、端口全景、开关表、不可改常量
│   ├── environment.md            部署形态判定矩阵、数据目录、CLI
│   ├── credentials.md            首次配置与凭据分层
│   ├── api-map.md                API 端点按 T1–T4 分层
│   ├── logs.md                   四类日志的来源与定位
│   ├── troubleshooting.md        故障手册（11 个场景）
│   ├── config-audit.md           配置体检
│   ├── router-integration.md     主路由接入
│   └── dangerous.md              T4 危险操作
├── scripts/
│   ├── bootstrap.sh / .ps1       首次配置
│   ├── selftest.sh               安装后自检（检查包完整性 / 凭据 / 连通性 / 依赖）
│   ├── log-triage.sh             日志分诊（只读）
│   ├── log-correlate.sh          跨日志时间轴（只读）
│   └── msf-health.sh / .ps1      只读快照
└── .github/workflows/validate.yml
```

设计依据是 Agent Skills 的**渐进式披露**：`SKILL.md` 保持精简（每次加载都进上下文），细节按需读取 `references/`。

---

## 与 MSF 内置助手的区别

MSF 自带一个基于 Eino ADK 的 AI 助手，它也有自己的 skill 机制（存在 `/opt/msf/configs/assistant/skills/`）。两者**不通用**：

| | MSF 内置助手 skill | 本仓库 |
|---|---|---|
| 面向 | MSF WebUI 内的 agent | 任意外部 agent |
| 形态 | 单段 `prompt` 文本 | `SKILL.md` + `references/` + `scripts/` |
| 权限 | 受 MSF 后端 Policy 约束 | 受各 agent 自身沙箱约束 |

本仓库**只做外部 agent 这一套**。

---

## 贡献

发现问题或想补充场景，欢迎开 issue 或 PR。提交前请注意：

- 不要在示例里放真实的服务器地址、域名、订阅链接或任何凭据
- 说明适用的 MSF 版本（当前验证于 `0.6.7.1`）
- 区分「用户配置问题」与「上游设计如此」

## 许可

MIT-0。见 [LICENSE](LICENSE)。
