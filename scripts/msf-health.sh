#!/usr/bin/env sh
# msf-health.sh — MSF 只读健康快照
#
# 用法:
#   ./msf-health.sh                 # 读 ~/.config/msf-skill/profile.json
#   ./msf-health.sh 10.0.0.10       # 直接指定 host
#   ./msf-health.sh --profile home  # 指定命名 profile
#
# 只做读操作。不写文件、不改配置、不重启服务。
# 输出为分节文本，便于人工或 agent 归纳。

set -u

PROFILE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/msf-skill"
HOST=""
PROFILE="default"
PORT=""
TOKEN=""
SSH_USER=""
SSH_KEY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    -*) echo "未知参数: $1" >&2; exit 2 ;;
    *) HOST="$1"; shift ;;
  esac
done

# ---------- 读取 profile（可选） ----------
if [ -z "$HOST" ] && [ -f "$PROFILE_DIR/profiles/$PROFILE.json" ]; then
  f="$PROFILE_DIR/profiles/$PROFILE.json"
elif [ -z "$HOST" ] && [ -f "$PROFILE_DIR/profile.json" ]; then
  f="$PROFILE_DIR/profile.json"
else
  f=""
fi

if [ -n "$f" ] && command -v python3 >/dev/null 2>&1; then
  eval "$(python3 - "$f" <<'PY'
import json,sys,shlex
d=json.load(open(sys.argv[1]))
def g(k):
    v=d.get(k,"")
    return shlex.quote(str(v)) if v!="" else "''"
print(f"HOST={g('host')}")
print(f"PORT={g('port')}")
print(f"SSH_USER={g('ssh_user')}")
print(f"SSH_KEY={g('ssh_key')}")
print(f"DEPLOY_KIND={g('deploy_kind')}")
print(f"DATA_DIR={g('data_dir')}")
PY
)"
fi

[ -n "$HOST" ] || { echo "未指定 host，且未找到 profile。用法: $0 <host>" >&2; exit 2; }
PORT="${PORT:-7777}"

# 数据目录随部署形态变化（见 references/environment.md）
DEPLOY_KIND="${DEPLOY_KIND:-systemd}"
if [ -z "${DATA_DIR:-}" ]; then
  case "$DEPLOY_KIND" in
    fnos)   DATA_DIR="/var/apps/msf/var" ;;
    unraid) DATA_DIR="/mnt/user/appdata/msf" ;;
    macos)  DATA_DIR="/Library/Application Support/MSF" ;;
    *)      DATA_DIR="/opt/msf" ;;
  esac
fi

if [ -z "$TOKEN" ] && [ -f "$PROFILE_DIR/token" ]; then
  TOKEN="$(cat "$PROFILE_DIR/token")"
fi

BASE="http://$HOST:$PORT"
AUTH=""
[ -n "$TOKEN" ] && AUTH="-H \"Authorization: Bearer $TOKEN\""

say() { printf '\n=== %s ===\n' "$1"; }

# 带认证的 GET（用 /bin/sh 兼容写法，避免数组）
get() {
  if [ -n "$TOKEN" ]; then
    curl -s -m 8 -H "Authorization: Bearer $TOKEN" "$BASE$1"
  else
    curl -s -m 8 "$BASE$1"
  fi
}

say "环境"
if V="$(curl -s -m 8 "$BASE/api/v1/version")" && [ -n "$V" ]; then
  printf '%s\n' "$V"
else
  echo "不可达: $BASE"
  echo "→ 检查 WebUI 端口、防火墙，或 host 是否正确"
  exit 1
fi

say "运行时与权限（免认证）"
curl -s -m 8 "$BASE/api/v1/setup/privilege" || echo "(获取失败)"

say "服务状态"
get "/api/v1/services" || echo "(需要令牌或作用域不足)"

say "启动问题"
get "/api/v1/system/startup-issues" || true

say "资源监控"
get "/api/v1/monitor/system" || true

say "网络运行时"
get "/api/v1/network/runtime" || true

say "MosDNS 概览"
get "/api/v1/mosdns/overview" || true

say "Mihomo 概览"
get "/api/v1/mihomo/overview" || true

# ---------- 宿主侧只读检查（需要 SSH） ----------
if [ -n "$SSH_USER" ] && [ -n "$SSH_KEY" ]; then
  SSH_OPTS="-i $SSH_KEY -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8"
  say "宿主侧（只读，deploy=$DEPLOY_KIND data=$DATA_DIR）"
  # shellcheck disable=SC2086
  ssh $SSH_OPTS "$SSH_USER@$HOST" "
    echo '--- uptime ---';           uptime 2>/dev/null
    echo '--- memory ---';           free -m 2>/dev/null | head -2
    echo '--- disk $DATA_DIR ---';   df -h '$DATA_DIR' 2>/dev/null | tail -1
    echo '--- ip_forward ---';       cat /proc/sys/net/ipv4/ip_forward 2>/dev/null
    echo '--- msf status ---';       msf status 2>/dev/null
    echo '--- restart count ---';    systemctl show msf -p NRestarts -p ActiveState 2>/dev/null
    echo '--- nft (容器内为空属正常) ---'; nft list table inet msf 2>&1 | head -5
    echo '--- switch states ---';    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do printf 'switch%s=%s ' \"\$i\" \"\$(cat '$DATA_DIR/configs/mosdns/rule/switch'\$i'.txt' 2>/dev/null)\"; done; echo
  " 2>/dev/null || echo "(SSH 不可用，跳过宿主侧检查)"
else
  say "宿主侧"
  echo "(未配置 SSH，跳过。宿主层检查需 scripts/bootstrap.sh 建立的专用密钥)"
fi

say "完成"
echo "以上为只读结果。任何修改需另行确认。"
