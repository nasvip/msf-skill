#!/usr/bin/env sh
# log-triage.sh — MSF 日志分诊（只读）
#
# 目的：把海量 WARN/ERROR 归一化成"可判断的签名"，并按时间窗区分
#   「仍在发生」与「已恢复」，避免对着历史噪音乱改配置。
#
# 用法:
#   ./log-triage.sh <host>
#   ./log-triage.sh              # 读 profile
#
# 只读。不改任何配置，不重启任何服务。

set -u

PROFILE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/msf-skill"
HOST=""
SSH_USER=""
SSH_KEY=""
DATA_DIR=""
PROFILE="default"

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --data-dir) DATA_DIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "未知参数: $1" >&2; exit 2 ;;
    *) HOST="$1"; shift ;;
  esac
done

f="$PROFILE_DIR/profile.json"
[ -f "$PROFILE_DIR/profiles/$PROFILE.json" ] && f="$PROFILE_DIR/profiles/$PROFILE.json"
if [ -f "$f" ] && command -v python3 >/dev/null 2>&1; then
  eval "$(python3 - "$f" <<'PY'
import json,sys,shlex
d=json.load(open(sys.argv[1]))
def g(k):
    v=d.get(k,"")
    return shlex.quote(str(v)) if v!="" else "''"
print(f"HOST={g('host')}")
print(f"SSH_USER={g('ssh_user')}")
print(f"SSH_KEY={g('ssh_key')}")
print(f"DATA_DIR={g('data_dir')}")
PY
)"
fi

[ -n "$HOST" ] || HOST="${MSF_HOST:-}"
[ -n "$HOST" ] || { echo "未指定 host 且无 profile。用法: $0 <host>" >&2; exit 2; }

# 允许用环境变量覆盖，便于无 profile 的临时排障与 CI
SSH_USER="${SSH_USER:-${MSF_SSH_USER:-}}"
SSH_KEY="${SSH_KEY:-${MSF_SSH_KEY:-}}"
DATA_DIR="${DATA_DIR:-${MSF_DATA_DIR:-/opt/msf}}"

if [ -z "$SSH_USER" ] || [ -z "$SSH_KEY" ]; then
  echo "日志在 MSF 主机本地，需要 SSH。请先运行 bootstrap.sh 建立专用密钥。" >&2
  exit 2
fi

# 远端脚本：时间戳为 ISO-8601 同偏移，可安全做字符串比较
REMOTE=$(cat <<'EOS'
set -u
LOG_M="$DATA/logs/mihomo.out.log"
LOG_D="$DATA/logs/mosdns.log"
LOG_S="$DATA/logs/msf.log"

CUT1H=$(date -d '1 hour ago'  +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -v-1H +%Y-%m-%dT%H:%M:%S)
CUT24H=$(date -d '24 hours ago' +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -v-24H +%Y-%m-%dT%H:%M:%S)

# ---------- Mihomo 签名 ----------
mihomo_sig() { # $1 = cutoff（空 = 全部）
  grep -E 'level=(warning|error)' "$LOG_M" 2>/dev/null \
  | sed -n 's/.*time="\([^"]\{19\}\)[^"]*".*msg="\(.*\)"$/\1|\2/p' \
  | awk -F'|' -v cut="$1" '$1 >= cut || cut == ""' \
  | sed -n 's/.*dial \([^(]*\) (match \([^)]*\)).*--> \([^ ]*\) error: \(.*\)$/\1|\3|\4/p' \
  | awk -F'|' '{
      d=$2; sub(/:.*/,"",d);
      e=$3; sub(/\\\\n.*/,"",e);
      sub(/^dial tcp .*/,"dial tcp 失败",e);
      sub(/^<HOST>:<PORT> connect error: .*/,"节点连接失败",e);
      gsub(/[0-9]+/,"N",e);
      sub(/:.*/,"",e);
      print $1" → "d" | "e
    }' \
  | sort | uniq -c | sort -rn | head -12
}

echo "════════ Mihomo 仍在发生（最近 1 小时）════════"
r=$(mihomo_sig "$CUT1H"); [ -z "$r" ] && r="  （无警告，或日志已轮转）"; echo "$r"
echo
echo "════════ Mihomo 最近 24 小时 ════════"
r=$(mihomo_sig "$CUT24H"); [ -z "$r" ] && r="  （无）"; echo "$r"
echo

# ---------- MosDNS 签名 ----------
mosdns_sig() { # $1 = cutoff
  tail -n 20000 "$LOG_D" 2>/dev/null \
  | awk -v cut="$1" '{
      ts = substr($0, 1, 19)
      if (cut != "" && ts < cut) next
      print
    }' \
  | grep -E '\b(WARN|ERROR)\b' \
  | sed -E 's/^[^ ]+[[:space:]]+//; s/::ffff://g;
            s/[0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]+/<IP:PORT>/g;
            s/[0-9]{1,3}(\.[0-9]{1,3}){3}/<IP>/g;
            s/"elapsed":[[:space:]]*"[^"]+"/"elapsed":"<D>"/g;
            s/"trace":[[:space:]]*"[^"]+",?[[:space:]]*//g;
            s/"uqid":[[:space:]]*[0-9]+,?[[:space:]]*//g;
            s/"[a-z0-9._-]+\.[a-z]{2,}\."/"<DOMAIN>"/g' \
  | cut -c1-170 \
  | sort | uniq -c | sort -rn | head -10
}

echo "════════ MosDNS 仍在发生（最近 1 小时）════════"
r=$(mosdns_sig "$CUT1H"); [ -z "$r" ] && r="  （无）"; echo "$r"
echo
echo "════════ MosDNS 最近 24 小时 ════════"
r=$(mosdns_sig "$CUT24H"); [ -z "$r" ] && r="  （无）"; echo "$r"
echo

# ---------- MSF 平台 ----------
echo "════════ MSF 平台 error/warn（全量计数）════════"
grep -oE '"level":"(error|warn|warning)"' "$LOG_S" 2>/dev/null | sort | uniq -c || echo "  （无）"
echo
echo "════════ 重启痕迹 ════════"
printf '  mosdns 终止信号次数: '; grep -c 'signal received' "$LOG_D" 2>/dev/null || echo 0
printf '  mihomo 启动次数:     '; grep -c 'Start initial configuration' "$LOG_M" 2>/dev/null || echo 0
printf '  systemd 重启次数:    '; systemctl show msf -p NRestarts --value 2>/dev/null || echo "n/a"
echo

# ---------- 输出判据 ----------
echo "════════ 判据提示 ════════"
echo "  1h 与 24h 都出现  → 仍在发生，值得归因"
echo "  仅 24h / all 出现 → 已恢复，不要动配置"
echo "  同一目标高频集中  → 目标侧问题（节点/上游/客户端软件）"
echo "  分散且低频        → 通常是客户端行为噪音"
EOS
)

SSH_OPTS="-i $SSH_KEY -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
# shellcheck disable=SC2086
printf '%s\n' "$REMOTE" | ssh $SSH_OPTS "$SSH_USER@$HOST" "export DATA='$DATA_DIR'; sh -s"
