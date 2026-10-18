# T4 危险操作

> **本文件仅在用户明确要求执行重置、卸载、升级或切换网络模式时加载。**
> 不要在其他场景预先加载、预先列出命令，或主动建议这些操作。
>
> 执行前必须：① 说明影响面 ② 确认备份 ③ 取得用户**逐字确认**（不是"嗯"或"好"，是明确要求执行）。
> 任一条件不满足 → 停止，只给方案。

---

## 通用前置

```bash
# 1) 当前版本与形态
curl -s http://<host>:7777/api/v1/version
curl -s http://<host>:7777/api/v1/setup/privilege

# 2) 备份（用平台自带能力，不要手写 cp）
curl -s -H "Authorization: Bearer $TOKEN" http://<host>:7777/api/v1/config/backups
curl -s -H "Authorization: Bearer $TOKEN" -X POST http://<host>:7777/api/v1/config/backup
```

---

## 1. 工厂重置

**不可逆。** 清除所有配置、用户、订阅、规则、令牌。

```bash
POST /api/v1/setup/reset
```

影响面（必须逐条告知用户）：

- 管理员账号与密码全部失效 → 需要重新走初始化向导
- 订阅链接、代理组、规则、MosDNS 配置全部丢失
- API 令牌全部吊销
- **网络会中断**：重置过程中 nft 规则被清理，若主路由仍指向 fake-IP 网段则全 LAN 断网，直到重新初始化完成

**注意**：若 `operatorAllows` 里 `/api/v1/setup/reset` 被排除，`operate` 作用域令牌**无权执行**，需要 admin 或 WebUI。

重置前必须确认：已有可用的配置备份文件（下载到本地，不只是留在服务器上）。

---

## 2. 卸载

### systemd 形态

```bash
sudo msf uninstall
```

交互式询问是否保留数据。**保留数据**意味着 `/opt/msf` 还在，但服务与二进制被移除。

### 卸载后必查

卸载脚本的 `ExecStopPost` 会清理 nft 规则与策略路由。若清理失败，残留规则会把流量黑洞：

```bash
nft list table inet msf          # 应为 "No such file or directory"
ip rule show | grep 'fwmark 0x1'  # 应为空
ip route show table 100           # 应为空
```

有残留则手动清理：

```bash
sudo nft delete table inet msf
sudo ip rule del fwmark 1 table 100
sudo ip route flush table 100
```

**不做这一步就直接拔掉 MSF，全网会断。**

### Docker / fnOS / Unraid

不走 `msf uninstall`。Docker 用 `docker rm`，fnOS/Unraid 用插件管理器卸载。

---

## 3. 升级

```bash
# 先看形态（environment.md）
# Docker 与 fnOS 禁用 msf update

curl -s -H "Authorization: Bearer $TOKEN" http://<host>:7777/api/v1/update/status
POST /api/v1/update/apply      # 或 sudo msf update
```

风险：

- 升级过程中服务重启，**网络短暂中断**
- 新版本可能改变配置结构，导致启动校验失败（MSF 会把面板拉起来但功能可能降级）
- 升级后若出现 `startup-issues`，不要反复重启，去 WebUI 修配置

升级后必查：

```bash
curl -s http://<host>:7777/api/v1/version
curl -s -H "Authorization: Bearer $TOKEN" http://<host>:7777/api/v1/system/startup-issues
```

---

## 4. 切换网络模式（nftables ↔ TUN）

```bash
# 当前模式
grep -E 'mode|proxy_mode' /opt/msf/configs/network/network.yaml
```

风险：

- 两种模式的依赖不同：nftables 需要内核 nft 与 `ip_forward`；TUN 需要 `/dev/net/tun` 与相应 cap
- 切换后主路由若仍指向舊网段静态路由，**全 LAN 断网**
- Docker 形态**只支持 TUN**，尝试切 nftables 会被后端拒绝

切换后必查：

```bash
ss -tulpn | grep -E ':(7896|7877)\b'   # nftables 模式
ip link show | grep -i tun             # TUN 模式
```

---

## 5. 用户与令牌

```bash
DELETE /api/v1/users/{id}
POST   /api/v1/api-tokens
DELETE /api/v1/api-tokens/{id}
```

风险：

- 删除当前唯一管理员 → 之后只能用 `sudo msf reset-password` 恢复
- 签发 `admin` 作用域令牌 → 等同于分发完全控制权
- 吊销令牌会立即中断使用该令牌的所有自动化

---

## 6. 直接写运行时副本（禁止）

以下操作**永远不做**，即使看起来能解决问题：

| 文件 | 为什么 |
|---|---|
| `/usr/local/bin/msf` | 服务主程序；任何补丁都会破坏版本校验，升级时失败 |
| `/opt/msf/data/binaries/**` | 受管组件，会被组件更新覆盖 |
| `/opt/msf/configs/mihomo/config.yaml` | 运行时副本，服务重启后被重新生成覆盖 |
| `/opt/msf/configs/mosdns/rule/switch*.txt` | 自动生成的开关状态 |
| `/opt/msf/configs/network/network.nft` | 自动生成的 nft 规则 |

替代做法：改 `user_configs/*.yaml`、走 WebUI，或调用领域 API。

若发现只能靠改运行时副本才能达成目标，**这通常说明是上游缺陷**——应向 <https://github.com/scoltzero/msf/issues> 提 issue，而不是在本地打补丁。
