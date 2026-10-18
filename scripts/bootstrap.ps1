<#
.SYNOPSIS
    MSF skill 首次配置（Windows / PowerShell 版）

.DESCRIPTION
    与 bootstrap.sh 等价。设计原则相同：
      - 不接收、不保存、不传输任何密码
      - API 令牌通过 SecureString 读取后写 0600 等价权限的文件
      - SSH 公钥安装由 ssh 自己在控制台询问密码（Windows 无 ssh-copy-id，
        用 ssh + 远程追加 authorized_keys 的方式，密码提示仍由 ssh 产生）

.EXAMPLE
    .\bootstrap.ps1 -HostName 10.0.0.10 -SshUser root -Mode remote
#>

[CmdletBinding()]
param(
    [string]$HostName,
    [string]$SshUser,
    [string]$Mode,
    [int]$Port = 7777,
    [ValidateSet('read','operate','admin')]
    [string]$TokenScope = 'operate',
    [switch]$SkipSsh,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'

$profileDir = Join-Path $env:USERPROFILE '.config\msf-skill'
$keyPath    = Join-Path $env:USERPROFILE '.ssh\msf_skill_ed25519'

function Fail($msg) { Write-Error $msg; exit 2 }

# ---------------- 1. 问对问题 ----------------
if (-not $Mode) {
    if ($NonInteractive) { Fail '非交互模式必须提供 -Mode (local|remote)' }
    $Mode = Read-Host 'MSF 是否运行在当前这台机器上？(local/remote)'
}
if ($Mode -notin @('local','remote')) { Fail 'Mode 只能是 local 或 remote' }

if ($Mode -eq 'local') {
    if (-not $HostName) { $HostName = '127.0.0.1' }
    $SkipSsh = $true
} else {
    if (-not $HostName) {
        if ($NonInteractive) { Fail '远程模式必须提供 -HostName' }
        $HostName = Read-Host 'MSF 主机地址 (IP 或域名)'
    }
    if (-not $SshUser) {
        if ($NonInteractive) { Fail '远程模式必须提供 -SshUser' }
        $SshUser = Read-Host 'SSH 用户名'
    }
}

$base = "http://${HostName}:${Port}"

# ---------------- 2. 探测 ----------------
Write-Host "`n-> 探测 $base"
try {
    $ver = Invoke-RestMethod -Uri "$base/api/v1/version" -TimeoutSec 8
} catch {
    Fail "无法连接 $base/api/v1/version。请确认 MSF 已启动、端口正确。"
}
Write-Host "  版本: $($ver | ConvertTo-Json -Compress)"

$priv = $null
try { $priv = Invoke-RestMethod -Uri "$base/api/v1/setup/privilege" -TimeoutSec 8 } catch { }

$isDocker = $priv.runtime.docker
$isMacos  = $priv.runtime.macos
$isRoot   = $priv.is_root

$deployKind = if ($isDocker) { 'docker' }
              elseif ($isMacos) { 'macos' }
              else { 'systemd' }

Write-Host "  部署形态: $deployKind"
if ($isRoot -eq $false) { Write-Host '  ! is_root=false：53 端口 / TUN / nftables 都不会生效' }

# ---------------- 3. 风险告知 ----------------
@"

────────────────────────────────────────
请先阅读以下风险，理解后再继续：

 1. 本工具会在 ~\.ssh 生成本地专用密钥（$keyPath）。
    上传到服务器后，任何能读到该私钥的进程都能免密登录该机器。

 2. MSF 是网络的单点故障。配置错误可能导致整个局域网断网。

 3. 工厂重置 / 卸载 / 升级 不可逆，本工具默认不主动执行。

 4. 日志包含客户端 IP、访问域名等隐私信息，不要公开粘贴。

 5. 建议优先同机部署。远程部署会把 SSH 访问路径暴露在网络中。

 6. 本工具不会接收、保存或传输任何密码。
────────────────────────────────────────
"@ | Write-Host

if (-not $NonInteractive) {
    $ack = Read-Host '理解以上风险并继续？输入 accept 继续，其他任意输入取消'
    if ($ack -ne 'accept') { Write-Host '已取消。'; exit 1 }
}

New-Item -ItemType Directory -Force -Path $profileDir | Out-Null

# ---------------- 4. API 令牌 ----------------
$tokenFile = Join-Path $profileDir 'token'
if (-not $NonInteractive) {
    Write-Host "`n-> API 令牌（推荐 scope=$TokenScope；直接回车表示先不配置）"
    Write-Host '   在 WebUI -> API Token 页面创建后粘贴。输入不回显。'
    $secure = Read-Host '  令牌' -AsSecureString
    $plain  = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                  [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
    if ($plain) {
        Set-Content -Path $tokenFile -Value $plain -NoNewline -Encoding ascii
        # 收紧 ACL 到仅当前用户
        icacls $tokenFile /inheritance:r /grant:r "$($env:USERNAME):(R,W)" 2>$null | Out-Null
    }
    $plain = $null; $secure = $null
}

if (Test-Path $tokenFile) {
    $tok = Get-Content $tokenFile -Raw
    try {
        $me = Invoke-RestMethod -Uri "$base/api/v1/auth/me" -TimeoutSec 8 `
                -Headers @{ Authorization = "Bearer $tok" }
        Write-Host '  v 令牌校验通过'
    } catch {
        Write-Host "  x 令牌校验失败: $($_.Exception.Message)"
    }
}

# ---------------- 5. SSH 专用密钥 ----------------
$fp = ''
if ($SkipSsh) {
    Write-Host "`n-> 跳过 SSH 配置"
} else {
    Write-Host "`n-> SSH 专用密钥"
    if (Test-Path $keyPath) {
        Write-Host "  已存在: $keyPath（复用）"
    } else {
        New-Item -ItemType Directory -Force -Path (Split-Path $keyPath) | Out-Null
        ssh-keygen -t ed25519 -f $keyPath -N '""' -C 'msf-skill' | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail 'ssh-keygen 失败' }
        Write-Host "  已生成: $keyPath"
    }

    $test = & ssh -i $keyPath -o BatchMode=yes -o StrictHostKeyChecking=accept-new `
                  -o ConnectTimeout=8 "$SshUser@$HostName" 'true' 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host '  v 免密已可用'
    } else {
        Write-Host '  免密不可用。下面由 ssh 自己询问服务器密码（不经过本脚本）。'
        if ($NonInteractive) {
            Write-Host '  x 非交互模式无法交互式输入密码。请手工执行：'
            Write-Host "     type `"$keyPath.pub`" | ssh $SshUser@$HostName `"mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys`""
        } else {
            Read-Host '  回车开始安装公钥' | Out-Null
            $pub = Get-Content "$keyPath.pub" -Raw
            $pub | & ssh "$SshUser@$HostName" `
                'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'
            if ($LASTEXITCODE -eq 0) { Write-Host '  v 公钥已安装' }
            else { Write-Host '  x 安装失败；宿主层检查将不可用，API 部分仍可使用' }
        }
    }

    $scan = & ssh-keyscan -t ed25519 $HostName 2>$null
    if ($scan) {
        $fp = ($scan | & ssh-keygen -lf - 2>$null | ForEach-Object { ($_ -split ' ')[1] }) -join ''
        if ($fp) { Write-Host "  主机指纹: $fp" }
    }

    & ssh -i $keyPath -o BatchMode=yes -o ConnectTimeout=8 "$SshUser@$HostName" 'sudo -n true' 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host '  v sudo 免密可用'
    } else {
        Write-Host '  ! sudo 需要密码。本工具不会接收 sudo 密码；宿主层只读检查可能受限。'
    }
}

# ---------------- 6. 落盘 ----------------
$profileJson = [ordered]@{
    version               = 1
    name                  = 'default'
    mode                  = $Mode
    host                  = $HostName
    port                  = $Port
    ssh_user              = if ($SshUser) { $SshUser } else { '' }
    ssh_key               = $keyPath
    ssh_host_fingerprint  = $fp
    deploy_kind           = $deployKind
    token_scope           = $TokenScope
    configured_at         = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}
$profileFile = Join-Path $profileDir 'profile.json'
$profileJson | ConvertTo-Json | Set-Content -Path $profileFile -Encoding utf8
icacls $profileFile /inheritance:r /grant:r "$($env:USERNAME):(R,W)" 2>$null | Out-Null

Write-Host "`nv 配置完成: $profileFile"
Write-Host '  下一步: .\msf-health.ps1'
