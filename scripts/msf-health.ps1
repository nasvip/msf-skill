<#
.SYNOPSIS
    MSF 只读健康快照（Windows / PowerShell 版）

.DESCRIPTION
    与 msf-health.sh 等价。只做读操作：不写文件、不改配置、不重启服务。

.EXAMPLE
    .\msf-health.ps1
    .\msf-health.ps1 -HostName 10.0.0.10
#>

[CmdletBinding()]
param(
    [string]$HostName,
    [int]$Port = 0,
    [string]$ProfileName = 'default'
)

$ErrorActionPreference = 'Continue'

$profileDir = Join-Path $env:USERPROFILE '.config\msf-skill'
$profileFile = Join-Path $profileDir 'profile.json'

$cfg = $null
if (Test-Path $profileFile) {
    try { $cfg = Get-Content $profileFile -Raw | ConvertFrom-Json } catch { }
}

if (-not $HostName) {
    if ($cfg -and $cfg.host) { $HostName = $cfg.host }
    else { Write-Error '未指定 -HostName 且未找到 profile.json'; exit 2 }
}
if ($Port -le 0) { $Port = if ($cfg -and $cfg.port) { [int]$cfg.port } else { 7777 } }

$base  = "http://${HostName}:${Port}"
$token = $null
$tokenFile = Join-Path $profileDir 'token'
if (Test-Path $tokenFile) { $token = (Get-Content $tokenFile -Raw).Trim() }

$headers = @{}
if ($token) { $headers['Authorization'] = "Bearer $token" }

function Get-Json($path, $needAuth = $true) {
    try {
        $h = if ($needAuth) { $headers } else { @{} }
        Invoke-RestMethod -Uri "$base$path" -Headers $h -TimeoutSec 8 |
            ConvertTo-Json -Depth 6 -Compress
    } catch {
        "(失败: $($_.Exception.Message))"
    }
}

function Section($title) { Write-Host "`n=== $title ===" }

Section '环境'
try {
    $v = Invoke-RestMethod -Uri "$base/api/v1/version" -TimeoutSec 8
    $v | ConvertTo-Json -Compress
} catch {
    Write-Host "不可达: $base"
    Write-Host '-> 检查 WebUI 端口、防火墙，或 host 是否正确'
    exit 1
}

Section '运行时与权限（免认证）'; Get-Json '/api/v1/setup/privilege' $false
Section '服务状态';               Get-Json '/api/v1/services'
Section '启动问题';               Get-Json '/api/v1/system/startup-issues'
Section '资源监控';               Get-Json '/api/v1/monitor/system'
Section '网络运行时';             Get-Json '/api/v1/network/runtime'
Section 'MosDNS 概览';            Get-Json '/api/v1/mosdns/overview'
Section 'Mihomo 概览';            Get-Json '/api/v1/mihomo/overview'

# ---------- 宿主侧只读检查 ----------
Section '宿主侧（只读）'
if ($cfg -and $cfg.ssh_user -and $cfg.ssh_key -and (Test-Path $cfg.ssh_key)) {
    $dataDir = if ($cfg.data_dir) { $cfg.data_dir } else {
        switch ($cfg.deploy_kind) {
            'fnos'   { '/var/apps/msf/var' }
            'unraid' { '/mnt/user/appdata/msf' }
            'macos'  { '/Library/Application Support/MSF' }
            default  { '/opt/msf' }
        }
    }
    Write-Host "(data=$dataDir deploy=$($cfg.deploy_kind))"
    $remote = @"
echo '--- uptime ---';           uptime 2>/dev/null
echo '--- memory ---';           free -m 2>/dev/null | head -2
echo '--- disk $dataDir ---';    df -h '$dataDir' 2>/dev/null | tail -1
echo '--- ip_forward ---';       cat /proc/sys/net/ipv4/ip_forward 2>/dev/null
echo '--- msf status ---';       msf status 2>/dev/null
echo '--- restart count ---';    systemctl show msf -p NRestarts -p ActiveState 2>/dev/null
echo '--- nft (容器内为空属正常) ---'; nft list table inet msf 2>&1 | head -5
"@
    & ssh -i $cfg.ssh_key -o BatchMode=yes -o StrictHostKeyChecking=accept-new `
         -o ConnectTimeout=8 "$($cfg.ssh_user)@$HostName" $remote
    if ($LASTEXITCODE -ne 0) { Write-Host '(SSH 不可用，跳过)' }
} else {
    Write-Host '(未配置 SSH，跳过。宿主层检查需 bootstrap 建立的专用密钥)'
}

Section '完成'
Write-Host '以上为只读结果。任何修改需另行确认。'
