# 主路由接入

MSF 作为旁路由时，**主路由必须配合两件事**。缺任一件，症状都是"DNS 能解析但网页打不开"，且极难从 MSF 侧看出问题。

## 两个必要条件

### 1. DHCP 只下发 MSF 的 DNS

主路由 DHCP 的 DNS 服务器**只能**填 MSF 的 IP。

**常见错误**：填 `MSF_IP` + `223.5.5.5` 作为备用。

后果：客户端会随机选 DNS，一部分查询绕过 MosDNS，直接拿到被污染的真实 IP 或直接超时。表现为"时好时坏""部分网站打不开"。

### 2. Fake-IP 静态路由

把 fake-IP 网段指向 MSF：

```
目标：<fake_ip_range_v4>   下一跳：<MSF_IP>
```

默认是 `28.0.0.0/8`，但**实际值以配置为准**：

```bash
curl -s -H "Authorization: Bearer $TOKEN" http://<host>:7777/api/v1/setup/config
# 看 fake_ip_range_v4 / fake_ip_range_v6
```

若改了 fake-IP 段而没同步改主路由静态路由 → 所有代理流量打到一个不存在的网段。

## 各路由系统

### RouterOS

```
/ip dns set servers=<MSF_IP> allow-remote-requests=yes
/ip route add dst-address=28.0.0.0/8 gateway=<MSF_IP>
```

DHCP 下发的 DNS 用 `/ip dhcp-server network` 里的 `dns-server=<MSF_IP>`。

### OpenWrt

```
网络 → 接口 → LAN → DHCP服务器 → 高级设置 → DHCP选项：
  6,<MSF_IP>

网络 → 静态路由：
  目标 28.0.0.0/8，网关 <MSF_IP>
```

同时在「接口 → LAN → DHCP服务器 → 高级」中关闭「强制」本地 DNS，并确保 `dnsmasq` 不覆盖。

### iKuai（爱快）

```
网络设置 → DHCP服务 → DNS服务器：<MSF_IP>
网络设置 → 静态路由：目的地址 28.0.0.0/8，网关 <MSF_IP>
```

### UniFi

```
Settings → Networks → <LAN> → DHCP Name Server：Manual → <MSF_IP>
Settings → Routes → 新增静态路由 28.0.0.0/8 → <MSF_IP>
```

## 客户端侧注意事项

- **Windows**：改 DHCP 后必须 `ipconfig /flushdns`，否则旧缓存仍然生效
- **Android**：若开启了「私人 DNS」（DoT），会完全绕过 MosDNS，必须关闭
- **iOS/macOS**：iCloud 私人中继可能影响 DNS 路径
- **浏览器**：Chrome/Edge 的「安全 DNS」若开启会绕过系统 DNS，需关闭
- 任何安装了本地代理客户端（Clash/V2Ray 等）的设备，会覆盖系统 DNS

## 排查顺序

```
客户端 nslookup www.google.com
├─ 超时                    → 53 不可达（防火墙 / MosDNS 未启动 / 静态路由错）
├─ 真实 IP（非 fake-IP 段） → DNS 绕过了 MosDNS
│   ├─ 检查该客户端的 DNS 设置
│   ├─ 检查浏览器安全 DNS / 私人 DNS
│   └─ 检查主路由是否下发了第二个 DNS
└─ fake-IP 段地址
    ├─ 网页打不开 → 主路由静态路由缺失或网段不匹配
    └─ 网页正常   → 链路正常
```

## IPv6 相关

**不要轻易开启 IPv6 双栈透明代理。** 常见事故：

1. 光猫/主路由通过 RA/SLAAC 直接向终端推送**运营商 DNS**，导致 IPv6 查询绕过 MosDNS
2. 多数家用路由器对 IPv6 静态路由支持不稳定
3. 运营商 IPv6 前缀会变化，静态路由随之失效
4. 国际出口的 IPv6 路由质量常劣于 IPv4，开启后反而变慢

若 MSF 关闭了 IPv6，MosDNS 通常会自动拦截 `AAAA` 查询（返回空），强制终端走 IPv4。这是**预期行为，不是故障**。验证：

```bash
nslookup -type=AAAA www.google.com <host>   # 正常应无 answer
```

若确认要开 IPv6，三件事必须同时成立：MSF 侧启用、主路由配好 fake-IPv6 静态路由、RA 不下发外部 DNS。缺一不可，否则不要开。
