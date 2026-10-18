#!/usr/bin/env sh
# bootstrap.sh — MSF skill 首次配置
#
# 设计原则：密码与本脚本、与 agent 的对话都无关。
#   - API 令牌：从标准输入静默读取，写入 0600 文件
#   - SSH 密钥：ssh-keygen 生成本地专用密钥；ssh-copy-id 由 ssh 自己在
#     终端里询问密码。密码不经过本脚本的变量、不写入任何文件、不进日志。
#
# 用法:
#   ./bootstrap.sh            # 交互式
#   ./bootstrap.sh --non-interactive --host H --user U [--token-stdin]
#
# 退出码: 0 成功 / 1 用户取消 / 2 参数或环境错误 / 3 校验失败

set -u

PROFILE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/msf-skill"
KEY_PATH="$HOME/.ssh/msf_skill_ed25519"

HOST=""
SSH_USER=""
PORT="7777"
MODE=""
DEPLOY_KIND=""
TOKEN_SCOPE="operate"
NON_INTERACTIVE=0
TOKEN_STDIN=0
SKIP_SSH=0

while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --user) SSH_USER="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --token-stdin) TOKEN_STDIN=1; shift ;;
    --token-scope) TOKEN_SCOPE="$2"; shift 2 ;;
    --skip-ssh) SKIP_SSH=1; shift ;;
    --non-interactive) NON_INTERACTIVE=1; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

die() { echo "错误: $*" >&2; exit 2; }
need() { command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"; }

need curl

# ---------------- 1. 问对问题 ----------------
if [ -z "$MODE" ]; then
  [ "$NON_INTERACTIVE" = 1 ] && die "非交互模式必须提供 --mode (local|remote)"
  printf 'MSF 是否运行在**当前这台机器**上？(local/remote) '
  read -r MODE
fi
case "$MODE" in
  local|remote) ;;
  *) die "mode 只能是 local 或 remote" ;;
esac

if [ "$MODE" = "local" ]; then
  HOST="${HOST:-127.0.0.1}"
  SKIP_SSH=1
else
  if [ -z "$HOST" ]; then
    [ "$NON_INTERACTIVE" = 1 ] && die "远程模式必须提供 --host"
    printf 'MSF 主机地址 (IP 或域名): '
    read -r HOST
  fi
  if [ -z "$SSH_USER" ]; then
    [ "$NON_INTERACTIVE" = 1 ] && die "远程模式必须提供 --user"
    printf 'SSH 用户名: '
    read -r SSH_USER
  fi
fi

BASE="http://$HOST:$PORT"

# ---------------- 2. 探测可达性与形态 ----------------
echo ""
echo "→ 探测 $BASE"
if ! V="$(curl -s -m 8 "$BASE/api/v1/version")" || [ -z "$V" ]; then
  die "无法连接 $BASE/api/v1/version。请确认 MSF 已启动、端口正确、无防火墙拦截。"
fi
echo "  版本: $V"

PRIV="$(curl -s -m 8 "$BASE/api/v1/setup/privilege" || true)"

# 解析 docker / macos 标志（不强依赖 jq）
json_bool() {
  printf '%s' "$1" | tr -d ' \n' | grep -o "\"$2\":\(true\|false\)" | head -1 | sed 's/.*://'
}

IS_DOCKER="$(json_bool "$PRIV" docker)"
IS_MACOS="$(json_bool "$PRIV" macos)"
IS_ROOT="$(json_bool "$PRIV" is_root)"

if [ "$IS_DOCKER" = "true" ]; then
  DEPLOY_KIND="docker"
elif [ "$IS_MACOS" = "true" ]; then
  DEPLOY_KIND="macos"
elif [ -n "$SSH_USER" ] && [ "$MODE" = "remote" ]; then
  # 远端再探一次 fnos / unraid 标志
  if ssh -o BatchMode=yes -o ConnectTimeout=8 "$SSH_USER@$HOST" \
       'test -e /etc/fnos-release -o -e /etc/feiniu-release -o -d /var/packages/msf' 2>/dev/null; then
    DEPLOY_KIND="fnos"
  else
    DEPLOY_KIND="systemd"
  fi
else
  DEPLOY_KIND="systemd"
fi

echo "  部署形态: $DEPLOY_KIND"
[ "${IS_ROOT:-}" = "false" ] && echo "  ⚠ is_root=false：53 端口 / TUN / nftables 都不会生效"

# ---------------- 3. 风险告知 ----------------
cat <<EOF

────────────────────────────────────────
请先阅读以下风险，理解后再继续：

 1. 本工具会在 ~/.ssh 生成本地专用密钥（$KEY_PATH）。
    上传到服务器后，任何能读到该私钥的进程都能免密登录该机器。

 2. MSF 是网络的单点故障。配置错误可能导致整个局域网断网。

 3. 工厂重置 / 卸载 / 升级 不可逆，本工具默认不主动执行。

 4. 日志包含客户端 IP、访问域名等隐私信息，不要公开粘贴。

 5. 建议优先同机部署。远程部署会把 SSH 访问路径暴露在网络中。

 6. 本工具不会接收、保存或传输任何密码。
────────────────────────────────────────
EOF

if [ "$NON_INTERACTIVE" != 1 ]; then
  printf '理解以上风险并继续？输入 accept 继续，其他任意输入取消: '
  read -r ACK
  [ "$ACK" = "accept" ] || { echo "已取消。"; exit 1; }
fi

mkdir -p "$PROFILE_DIR"
chmod 700 "$PROFILE_DIR" 2>/dev/null || true

# ---------------- 4. API 令牌 ----------------
TOKEN_FILE="$PROFILE_DIR/token"
if [ "$TOKEN_STDIN" = 1 ]; then
  # 由调用方通过管道/重定向提供，不走交互
  if [ -t 0 ]; then
    die "--token-stdin 需要从管道输入，例如: printf '%s' \"\$TOKEN\" | ./bootstrap.sh --token-stdin"
  fi
  cat > "$TOKEN_FILE"
elif [ -t 0 ]; then
  echo ""
  echo "→ API 令牌（推荐 scope=$TOKEN_SCOPE；留空表示先不配置，仅能使用免认证探测）"
  echo "  在 WebUI → API Token 页面创建，然后粘贴到这里。输入不回显。"
  printf '  令牌: '
  if stty -echo 2>/dev/null; then
    read -r TOKEN_IN
    stty echo 2>/dev/null
    printf '\n'
    if [ -n "${TOKEN_IN:-}" ]; then
      printf '%s' "$TOKEN_IN" > "$TOKEN_FILE"
    fi
  else
    read -r TOKEN_IN
    [ -n "${TOKEN_IN:-}" ] && printf '%s' "$TOKEN_IN" > "$TOKEN_FILE"
  fi
  unset TOKEN_IN
else
  echo "  非交互且未提供令牌，跳过（仅免认证探测可用）"
fi

if [ -f "$TOKEN_FILE" ]; then
  chmod 600 "$TOKEN_FILE"
  # 校验令牌可用性与实际作用域
  CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 8 \
    -H "Authorization: Bearer $(cat "$TOKEN_FILE")" "$BASE/api/v1/auth/me")"
  case "$CODE" in
    200) echo "  ✓ 令牌校验通过" ;;
    401) echo "  ✗ 令牌无效（401）。已保留文件供你修正, 或删除后重跑。"; ;;
    *)   echo "  ? 校验返回 $CODE，继续但请留意权限问题" ;;
  esac
fi

# ---------------- 5. SSH 专用密钥 ----------------
if [ "$SKIP_SSH" = 1 ]; then
  echo ""
  echo "→ 跳过 SSH 配置（local 模式或 --skip-ssh）"
else
  echo ""
  echo "→ SSH 专用密钥"
  if [ -f "$KEY_PATH" ]; then
    echo "  已存在: $KEY_PATH（复用，不覆盖）"
  else
    ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "msf-skill" >/dev/null 2>&1 \
      && echo "  已生成: $KEY_PATH" \
      || die "ssh-keygen 失败"
    chmod 600 "$KEY_PATH"
  fi

  echo "  正在测试免密连通性..."
  if ssh -i "$KEY_PATH" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=8 "$SSH_USER@$HOST" 'true' 2>/dev/null; then
    echo "  ✓ 免密已可用"
  else
    echo "  免密不可用。下面执行 ssh-copy-id —— 它会自己在终端里询问服务器密码。"
    echo "  该密码不会经过本脚本，也不会进入任何文件或对话。"
    if [ "$NON_INTERACTIVE" = 1 ]; then
      echo "  ✗ 非交互模式无法完成 ssh-copy-id。请手工执行："
      echo "     ssh-copy-id -i $KEY_PATH.pub $SSH_USER@$HOST"
    else
      printf '  回车开始 ssh-copy-id: '
      read -r _
      if ssh-copy-id -i "$KEY_PATH.pub" "$SSH_USER@$HOST"; then
        echo "  ✓ 密钥已安装"
      else
        echo "  ✗ ssh-copy-id 失败。宿主层检查将不可用，API 部分仍可使用。"
      fi
    fi
  fi

  # 记录主机指纹，后续连接只信任这个
  FP="$(ssh-keyscan -t ed25519 "$HOST" 2>/dev/null | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')"
  if [ -n "${FP:-}" ]; then
    echo "  主机指纹: $FP"
  fi

  # sudo 可用性（只探测，不索取密码）
  if ssh -i "$KEY_PATH" -o BatchMode=yes -o ConnectTimeout=8 "$SSH_USER@$HOST" \
       'sudo -n true' 2>/dev/null; then
    echo "  ✓ sudo 免密可用"
  else
    echo "  ! sudo 需要密码。本工具不会接收 sudo 密码；"
    echo "    宿主层只读检查可能受限。建议为用户配置 NOPASSWD 或使用 root 密钥。"
  fi
fi

# ---------------- 6. 落盘 ----------------
PROFILE_JSON="$PROFILE_DIR/profile.json"
{
  printf '{\n'
  printf '  "version": 1,\n'
  printf '  "name": "default",\n'
  printf '  "mode": "%s",\n' "$MODE"
  printf '  "host": "%s",\n' "$HOST"
  printf '  "port": %s,\n' "$PORT"
  printf '  "ssh_user": "%s",\n' "${SSH_USER:-}"
  printf '  "ssh_key": "%s",\n' "$KEY_PATH"
  printf '  "ssh_host_fingerprint": "%s",\n' "${FP:-}"
  printf '  "deploy_kind": "%s",\n' "$DEPLOY_KIND"
  printf '  "token_scope": "%s",\n' "$TOKEN_SCOPE"
  printf '  "configured_at": "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '}\n'
} > "$PROFILE_JSON"
chmod 600 "$PROFILE_JSON"

echo ""
echo "✓ 配置完成: $PROFILE_JSON"
echo "  下一步: ./msf-health.sh"
