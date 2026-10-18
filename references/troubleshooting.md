# 故障排查手册

每条都按「现象 → 定位 → 处置」。定位阶段全部只读（T1）；处置按层标注。

---

## 1. 局域网设备完全上不了网

**定位**

```bash
# 客户端 → 网关可达？
ping <gateway>

# DNS 是否由 MosDNS 承接
nslookup www.baidu.com <msf_host>

# 国外域名是否返回 fake-IP
nslookup www.google.com <msf_host>
```

| 结果 | 结论 |
|---|---|
| MosDNS 超时 | 53 未监听 / MosDNS 挂了 |
| 返回真实公网 IP | DNS 绕过了 MosDNS（主路由下发了外部 DNS，或客户端有本地 DNS 覆盖） |
| 返回 28.x.x.x | DNS 正常，问题在转发或出站 |

**处置（按结论分叉）**

- 53 未监听 → 见第 2 节
- DNS 绕过 → 修主路由 DHCP（见 `router-integration.md`），客户端 `ipconfig /flushdns`
- 转发失败 → 见第 3 节
- 出站失败 → 见第 4 节

---

## 2. 53 端口被占用 / MosDNS 起不来

**定位**

```bash
ss -tulpn | grep ':53 '
lsof -i:53
systemctl status systemd-resolved --no-pager
```

**处置（T2）**

若被 `systemd-resolved` 占用：

```bash
# /etc/systemd/resolved.conf
DNSStubListener=no

sudo systemctl restart systemd-resolved
sudo msf restart
```

若是 Docker 形态，容器内不跑 systemd-resolved，需要检查宿主是否占用了 53（macvlan 模式下尤其容易撞）。

---

## 3. 解析出 fake-IP 但流量没进代理

**定位**

```bash
# 1) nft 规则是否存在（Docker 形态跳过本条）
nft list table inet msf

# 2) 策略路由
ip rule show | grep 'fwmark 0x1'

# 3) 内核转发
sysctl net.ipv4.ip_forward

# 4) Mihomo 是否在监听 TProxy
ss -tulpn | grep -E ':(7896|7877)\b'
```

**常见原因**

| 现象 | 原因 |
|---|---|
| `nft list table inet msf` 报 "No such file or directory" | MSF 未启用 nft 模式，或服务异常退出后 `ExecStopPost` 已清理规则 |
| 有 nft 规则但无 `ip rule` | 策略路由未建立，通常需重启 MSF |
| `ip_forward = 0` | 内核转发关闭 |
| 主路由没有 `fake-ip 段 → MSF` 的静态路由 | **最常见**，见 `router-integration.md` |

**处置（T2）**

```bash
sudo msf restart
```

重启后按上面 4 步复验。若仍失败，检查 `mihomo.out.log` 是否有 TProxy 绑定错误。

---

## 4. 节点连不上 / 测速失败 / 订阅不更新

**定位**

```bash
# 代理组与节点状态
curl -s -H "Authorization: Bearer $TOKEN" http://<host>:7777/api/v1/mihomo/proxies

# 订阅缓存文件时间
ls -l /opt/msf/configs/mihomo/proxy_providers/

# 订阅任务日志
grep -i 'proxy-providers\|subscription' /opt/msf/logs/msf.log | tail -n 20
```

**处置**

- 订阅缓存过期 → T2：触发订阅刷新，或在 WebUI 手动更新
- 节点全部超时 → 上游机场故障，或本机到机场线路问题；先排除本机出口
- 单节点失败 → 换节点，不是配置问题

**测速失败 ≠ 节点不可用**：MSF 默认用 `https://www.gstatic.com/generate_204` 做健康检查。若该地址在当前网络被干扰，会全组显示超时但实际可用。判断方法：直接手工验证

```bash
curl -s -o /dev/null -w '%{http_code}\n' -x http://<host>:7890 https://www.gstatic.com/generate_204
```

返回 204 说明链路通。注意：`proxy-providers` 的 `health-check.url` 是**代码里硬编码生成**的，改配置文件会被下次生成覆盖（上游 Issue #22）。WebUI 里的「延迟测试地址」是另一套设置，存在数据库里，不会被覆盖。

---

## 5. fake-IP 缓存错乱（改网段后部分站点异常）

**处置（T2，需确认）**

```bash
sudo msf stop
# 仅删缓存，不要删配置与证书
rm -f /opt/msf/configs/mihomo/cache.db
sudo msf start
```

客户端侧 `ipconfig /flushdns`。

---

## 6. 容器/虚拟机资源异常

**定位**

```bash
free -m
df -h /opt/msf
cat /proc/$(pgrep -f 'msf serve' | head -1)/limits | grep 'open files'
systemctl show msf -p NRestarts -p ActiveState
```

| 指标 | 关注点 |
|---|---|
| 内存 | MosDNS 在生产量级下通常百 MB 级；持续上涨到接近总内存说明缓存参数过大 |
| 磁盘 | `< 15%` 剩余需处理日志轮转 |
| open files | 应为 `LimitNOFILE` 值（默认 1048576）；若为 1024，说明不是通过 systemd 启动 |
| `NRestarts` | 非零说明发生过崩溃重启，查 `msf.log` 启动段 |

---

## 7. 服务反复重启

**定位**

```bash
systemctl status msf --no-pager -n 50
journalctl -u msf -n 200 --no-pager
grep -i 'startup\|issue\|fatal' /opt/msf/logs/msf.log | tail -n 30
```

**要点**

MSF 设计了「配置校验失败也把面板拉起来」的行为——否则会变成 systemd 崩溃循环且无修复入口。所以看到 `startup-issues` 时，应通过 WebUI 修复配置，而不是反复重启。

```bash
curl -s -H "Authorization: Bearer $TOKEN" http://<host>:7777/api/v1/system/startup-issues
```

---

## 8. 升级 / 更新失败

先确认形态（`environment.md`）：

- Docker / fnOS：**不支持** `msf update`，必须走镜像或插件管理器
- systemd：`sudo msf update`

```bash
curl -s http://<host>:7777/api/v1/update/status -H "Authorization: Bearer $TOKEN"
```

升级前必须备份（用平台自带能力，不要手写 `cp`）：

```bash
curl -s -H "Authorization: Bearer $TOKEN" http://<host>:7777/api/v1/config/backups
```

---

## 9. 游戏每隔 30–40 秒掉一次线

**这是 MSF 的一个已知机制，不是玄学。**

Mihomo 的 UDP 隧道有固定的 **60 秒空闲超时**（`tunnel.go` 的 `udpTimeout`）。国内游戏 UDP 若经 Mihomo，会话会被周期性回收，表现为每 30–40 秒断一次。

MSF 的应对是在内核层直接放行：

```
set game_udp_bypass { type inet_service; elements = { <端口> } }
...
udp dport @game_udp_bypass return
```

**定位**

```bash
# 当前放行端口（默认 22101,22102）
grep -A2 'game_udp_bypass' $DATA/configs/network/network.nft

# 或从设置读取
curl -s -H "Authorization: Bearer $TOKEN" http://<host>:7777/api/v1/settings | grep game_udp_bypass
```

**处置（T3）**：把该游戏的 UDP 端口加入 `network.game_udp_bypass_ports`，然后重新应用网络配置。国内 UDP 目标（`china_udp_ipv4/6` 集合）同样在内核层 return，不进 Mihomo。

> 若用户报"游戏掉线"但端口已在放行列表里，方向应转向节点质量或游戏服务器本身，而不是继续改 MSF。

---

## 10. 只有部分设备走代理（或只有部分设备不走）

**这是设计功能，不是故障。** 由 `client_ip.txt` + 两个开关控制：

| 开关 | 状态 | 效果 |
|---|---|---|
| `switch2 = A` | 启用 | **只有** `client_ip.txt` 里的 IP 走代理，其余直连 |
| `switch12 = A` | 启用 | **只有** `client_ip.txt` 里的 IP 不走代理，其余走代理 |

两者同时为 `A` 时以流程顺序决定，实际效果接近"白名单直连"。

**定位**

```bash
curl -s http://<host>:9099/plugins/switch2/show
curl -s http://<host>:9099/plugins/switch12/show
cat $DATA/configs/mosdns/client_ip.txt
```

**处置**：在 WebUI 的客户端管理里增删 IP，不要手工编辑 `client_ip.txt`（会被改写）。

---

## 11. Docker 环境里 nft / ip rule 全是空

**不是故障。** Docker 形态使用 Mihomo TUN，**不写宿主机 nftables，也不建 policy routing**。

判定：

```bash
curl -s http://<host>:7777/api/v1/setup/privilege   # runtime.docker = true
cat /.dockerenv
env | grep MSF_DOCKER_NETWORK_MODE
```

在这种形态下，排查应转向：

- TUN 设备是否存在（`/dev/net/tun`）
- 容器是否具备 `CAP_NET_ADMIN` / `CAP_NET_RAW`
- `host-tun` 还是 `macvlan-tun`
- 主路由静态路由是否指向容器实际的 LAN IP（macvlan 模式）

同理，Docker 与 fnOS 下 `msf update` 被禁用，升级要走镜像或插件管理器。

---

## 处置后的复验清单

任何处置完成后，按这四条自证，不要只声称"已修复"：

```bash
1) nslookup www.baidu.com <host>      # 应返回真实国内 IP
2) nslookup www.google.com <host>     # 应返回 fake-IP
3) curl -x http://<host>:7890 -s -o /dev/null -w '%{http_code}\n' https://www.gstatic.com/generate_204   # 204
4) curl -s -o /dev/null -w '%{http_code}\n' https://www.baidu.com   # 200
```
