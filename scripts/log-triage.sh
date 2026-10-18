#!/usr/bin/env sh
# log-triage.sh — MSF 日志分诊（只读）
#
# 把海量 WARN/ERROR 归一化成可判断的签名，按时间窗区分
# 「仍在发生」与「已恢复」，并与历史基线对比找出突增。
#
# 用法:
#   ./log-triage.sh <host>                  # 分诊 + 与基线对比（若有基线）
#   ./log-triage.sh <host> --baseline-save  # 把本次结果保存为新基线
#   ./log-triage.sh --profile home          # 用命名 profile
#   ./log-triage.sh <host> --no-baseline    # 跳过基线对比
#   ./log-triage.sh <host> --no-audit       # 跳过 DNS 审计维度
#
# 只读。不写远端文件、不改配置、不重启服务。

set -u

PROFILE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/msf-skill"
HOST=""
SSH_USER=""
SSH_KEY=""
DATA_DIR=""
PROFILE="default"
SAVE_BASELINE=0
USE_BASELINE=1
USE_AUDIT=1

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --data-dir) DATA_DIR="$2"; shift 2 ;;
    --baseline-save) SAVE_BASELINE=1; shift ;;
    --no-baseline) USE_BASELINE=0; shift ;;
    --no-audit) USE_AUDIT=0; shift ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

SSH_USER="${SSH_USER:-${MSF_SSH_USER:-}}"
SSH_KEY="${SSH_KEY:-${MSF_SSH_KEY:-}}"
DATA_DIR="${DATA_DIR:-${MSF_DATA_DIR:-/opt/msf}}"
MSF_PORT="${MSF_PORT:-7777}"
MOSDNS_API="${MSF_MOSDNS_API:-9099}"

if [ -z "$SSH_USER" ] || [ -z "$SSH_KEY" ]; then
  echo "日志在 MSF 主机本地，需要 SSH。请先运行 bootstrap.sh 建立专用密钥，" >&2
  echo "或用 MSF_SSH_USER / MSF_SSH_KEY 环境变量临时指定。" >&2
  exit 2
fi

# 远端脚本：时间戳为 ISO-8601 同偏移，可直接做字符串比较
REMOTE=$(cat <<'EOS'
set -u
LOG_M="$DATA/logs/mihomo.out.log"
LOG_D="$DATA/logs/mosdns.log"
LOG_S="$DATA/logs/msf.log"

CUT1H=$(date -d '1 hour ago'  +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -v-1H +%Y-%m-%dT%H:%M:%S)
CUT24H=$(date -d '24 hours ago' +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -v-24H +%Y-%m-%dT%H:%M:%S)

# ---------- Mihomo 签名 -> ts|group|dest|err ----------
norm_mihomo() {
  grep -E 'level=(warning|error)' "$LOG_M" 2>/dev/null \
  | sed -n 's/.*time="\([^"]\{19\}\)[^"]*".*dial \([^(]*\) (match [^)]*).*--> \([^ ]*\) error: \(.*\)$/\1|\2|\3|\4/p'
}

# ---------- MosDNS 签名 -> ts|level|plugin|caller|msg ----------
norm_mosdns() {
  tail -n 20000 "$LOG_D" 2>/dev/null \
  | awk -F'\t' 'NF>=4 && ($2=="WARN" || $2=="ERROR") {
      print substr($1,1,19) "|" $2 "|" $3 "|" $4 "|" substr($0, index($0,$5))
    }' \
  | sed 's/::ffff://g' \
  | sed -E 's/[0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]+/<IP:PORT>/g; s/[0-9]{1,3}(\.[0-9]{1,3}){3}/<IP>/g;
            s/"elapsed":"[^"]*"/"elapsed":"<D>"/g; s/"trace":"[^"]*",?//g; s/"uqid":[0-9]+,?//g;
            s/"qname":"[^"]*"/"qname":"<DOMAIN>"/g'
}

echo "#SIG-BEGIN#"
norm_mihomo | awk -F'|' -v c1="$CUT1H" -v c24="$CUT24H" '
  { ts=$1; g=$2; d=$3; e=$4;
    sub(/:.*/,"",d);
    sub(/\\\\n.*/,"",e);
    sub(/^dial tcp .*/,"dial tcp 失败",e);
    gsub(/[0-9]+/,"N",e); sub(/:.*/,"",e);
    sig = g" → "d" | "e;
    if (ts >= c24) { k24[sig]++; if (ts >= c1) k1[sig]++ }
  }
  END { for (s in k24) if (k24[s] >= 2) printf "mihomo\t%s\t%d\t%d\n", s, (s in k1 ? k1[s] : 0), k24[s] }
'
norm_mosdns | awk -F'|' -v c1="$CUT1H" -v c24="$CUT24H" '
  { ts=$1; lv=$2; plugin=$3; caller=$4; msg=$5;
    sub(/^[ \t]+/, "", msg);
    sig = plugin " | " caller " | " msg;
    if (ts >= c24) { k24[sig]++; if (ts >= c1) k1[sig]++ }
  }
  END { for (s in k24) if (k24[s] >= 3) printf "mosdns\t%s\t%d\t%d\n", s, (s in k1 ? k1[s] : 0), k24[s] }
'
echo "#SIG-END#"

# ---------- 平台与重启 ----------
echo "#INFO-BEGIN#"
printf 'msf_error=%s\n' "$(grep -c '"level":"error"' "$LOG_S" 2>/dev/null; true)"
printf 'msf_warn=%s\n' "$(grep -cE '"level":"(warn|warning)"' "$LOG_S" 2>/dev/null; true)"
printf 'mosdns_terminated=%s\n' "$(grep -c 'signal received' "$LOG_D" 2>/dev/null; true)"
printf 'mihomo_starts=%s\n' "$(grep -c 'Start initial configuration' "$LOG_M" 2>/dev/null; true)"
printf 'systemd_restarts=%s\n' "$(systemctl show msf -p NRestarts --value 2>/dev/null || echo n/a)"
MPID=$(pgrep -x mosdns 2>/dev/null | head -1)
printf 'mosdns_started=%s\n' "$([ -n "${MPID:-}" ] && ps -o lstart= -p "$MPID" 2>/dev/null | sed 's/^ *//' || echo n/a)"
echo "#INFO-END#"

# ---------- DNS 审计维度 ----------
echo "#AUDIT-BEGIN#"
A="http://127.0.0.1:$MOSDNS_API"
if curl -s -m 4 "$A/api/v1/audit/status" >/dev/null 2>&1; then
  echo "field_set"
  curl -s -m 6 "$A/api/v2/audit/rank/domain_set" \
    | tr '}' '\n' | sed -n 's/.*"key":"\([^"]*\)","count":\([0-9]*\).*/\2 \1/p' | head -8
  echo "client"
  curl -s -m 6 "$A/api/v2/audit/rank/client" \
    | tr '}' '\n' | sed -n 's/.*"key":"\([^"]*\)","count":\([0-9]*\).*/\2 \1/p' \
    | sed 's/::ffff://' | head -6
  echo "slowest"
  curl -s -m 6 "$A/api/v2/audit/rank/slowest" \
    | tr '}' '\n' | sed -n 's/.*"query_name":"\([^"]*\)".*"duration_ms":\([0-9.]*\).*/\2 \1/p' | head -5
  echo "non_noerror"
  TOTALP=$(curl -s -m 6 "$A/api/v2/audit/logs?page=1&page_size=50" \
           | sed -n 's/.*"total_pages":\([0-9]*\).*/\1/p' | head -1)
  TOTALP=${TOTALP:-1}
  STEP=$(( TOTALP / 20 )); [ "$STEP" -lt 1 ] && STEP=1
  NX=$(
    p=1
    while [ "$p" -le "$TOTALP" ] && [ "$p" -le 200000 ]; do
      curl -s -m 6 "$A/api/v2/audit/logs?page=$p&page_size=50" \
        | grep -o '"query_name":"[^"]*","query_class":"[^"]*","query_time":"[^"]*","duration_ms":[0-9.]*,"trace_id":"[^"]*","response_code":"[^"]*"' \
        | sed -n 's/"query_name":"\([^"]*\)".*"response_code":"\([^"]*\)"/\2|\1/p'
      p=$(( p + STEP ))
    done
  )
  printf 'sampled=%s\n' "$(printf '%s\n' "$NX" | grep -c . ; true)"
  printf 'nonnoerror=%s\n' "$(printf '%s\n' "$NX" | grep -vcE '^NOERROR\|' ; true)"
  printf '%s\n' "$NX" | grep -vE '^NOERROR\|' | sort | uniq -c | sort -rn | head -8
else
  echo "audit_api_unavailable"
fi
echo "#AUDIT-END#"
EOS
)

SSH_OPTS="-i $SSH_KEY -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
# shellcheck disable=SC2086
OUT=$(printf '%s\n' "$REMOTE" | ssh $SSH_OPTS "$SSH_USER@$HOST" "export DATA='$DATA_DIR' MOSDNS_API='$MOSDNS_API'; sh -s" 2>&1) || {
  echo "远端执行失败：" >&2
  printf '%s\n' "$OUT" >&2
  exit 1
}

TMP=$(mktemp 2>/dev/null || echo "/tmp/msf-triage.$$")
printf '%s\n' "$OUT" | sed -n '/^#SIG-BEGIN#$/,/^#SIG-END#$/p' | grep -v '^#' > "$TMP" || true

echo "════════════ 日志分诊 ════════════"
echo "窗口：最近 1 小时 / 24 小时"
echo

echo "──── 仍在发生（1 小时窗口，按频次）────"
awk -F'\t' '$3+0 > 0' "$TMP" | sort -t"$(printf '\t')" -k3,3nr | head -10 \
  | awk -F'\t' '{ printf "%6s/1h  %6s/24h  [%s]  %s\n", $3, $4, $1, $2 }'
awk -F'\t' '$3+0 > 0' "$TMP" | grep -q . || echo "  （无）"
echo

echo "──── 仅 24 小时（已恢复，不要动配置）────"
awk -F'\t' '$3+0 == 0 && $4+0 >= 3' "$TMP" | sort -t"$(printf '\t')" -k4,4nr | head -10 \
  | awk -F'\t' '{ printf "%6s/24h  [%s]  %s\n", $4, $1, $2 }'
awk -F'\t' '$3+0 == 0 && $4+0 >= 3' "$TMP" | grep -q . || echo "  （无）"
echo

# ---------- 基线对比 ----------
BASELINE="$PROFILE_DIR/baseline.tsv"
mkdir -p "$PROFILE_DIR" 2>/dev/null || true

if [ "$SAVE_BASELINE" = 1 ]; then
  cp "$TMP" "$BASELINE" 2>/dev/null && printf '基线已保存：%s（%s 条签名）\n\n' "$BASELINE" "$(wc -l < "$TMP" | tr -d ' ')"
elif [ "$USE_BASELINE" = 1 ] && [ -f "$BASELINE" ]; then
  echo "──── 与基线对比（突增 / 新增 / 消失）────"
  UP=$(awk -F'\t' 'NR==FNR { b[$1"|"$2]=$4+0; next }
    { k=$1"|"$2; cur=$4+0; old=b[k]+0;
      if (old==0 && cur>=5) { printf "  NEW    %4d/24h  %s\n", cur, k; }
      else if (old>0 && cur >= old*2 && cur >= 5) { printf "  x%.1f  %4d/24h (原 %d)  %s\n", cur/old, cur, old, k; } }' \
    "$BASELINE" "$TMP" | head -8)
  GONE=$(awk -F'\t' 'NR==FNR { b[$1"|"$2]=$4+0; next } { seen[$1"|"$2]=1 }
    END { for (k in b) if (!(k in seen) && b[k]>=5) printf "  GONE   %4d/24h  %s\n", b[k], k }' \
    "$BASELINE" "$TMP" | head -8)
  if [ -n "$UP" ]; then
    printf '%s\n' "$UP"
  else
    echo "  （无新增或突增）"
  fi
  if [ -n "$GONE" ]; then
    printf '%s\n' "$GONE"
  fi
  if [ -z "$UP" ] && [ -z "$GONE" ]; then
    echo "  （与基线无明显变化）"
  fi
  echo
else
  [ "$USE_BASELINE" = 1 ] && { echo "（尚无基线，运行一次 --baseline-save 建立）"; echo; }
fi

# ---------- 平台与重启 ----------
printf '%s\n' "$OUT" | sed -n '/^#INFO-BEGIN#$/,/^#INFO-END#$/p' | grep -v '^#' \
| while IFS='=' read -r k v; do
    [ -n "$k" ] || continue
    case "$k" in
      msf_error)          printf '  MSF error 行数      : %s\n' "$v" ;;
      msf_warn)           printf '  MSF warn 行数       : %s\n' "$v" ;;
      mosdns_terminated)  printf '  MosDNS 终止信号     : %s\n' "$v" ;;
      mihomo_starts)      printf '  Mihomo 启动次数     : %s\n' "$v" ;;
      systemd_restarts)   printf '  systemd 重启次数    : %s\n' "$v" ;;
      mosdns_started)     printf '  MosDNS 启动时间     : %s\n' "$v" ;;
    esac
  done
echo

# ---------- DNS 审计 ----------
if [ "$USE_AUDIT" = 1 ]; then
  AUD=$(printf '%s\n' "$OUT" | sed -n '/^#AUDIT-BEGIN#$/,/^#AUDIT-END#$/p' | grep -v '^#')
  if printf '%s' "$AUD" | grep -q 'audit_api_unavailable'; then
    echo "──── DNS 审计 ────"
    echo "  （MosDNS API :$MOSDNS_API 不可达，跳过）"
  else
    echo "──── DNS 审计（缓冲窗口内）────"
    echo "$AUD" | awk '
      /^field_set$/   { mode="ds";  print "  命中分布（domain_set）:"; next }
      /^client$/      { mode="cl";  print "  客户端查询量 TOP:"; next }
      /^slowest$/     { mode="sl";  print "  最慢查询 TOP:"; next }
      /^non_noerror$/ { mode="nx";  print "  非 NOERROR 响应（采样）:"; next }
      /^sampled=/     { printf "    采样 %s 条；\n", substr($0, 9); next }
      /^nonnoerror=/  { printf "    其中非 NOERROR %s 条\n", substr($0, 12); next }
      mode=="ds" && NF>=2 { printf "    %8s  %s\n", $1, substr($0, index($0,$2)) }
      mode=="cl" && NF>=2 { printf "    %8s  %s\n", $1, substr($0, index($0,$2)) }
      mode=="sl" && NF>=2 { printf "    %8sms  %s\n", $1, substr($0, index($0,$2)) }
      mode=="nx" && NF>=2 { printf "    %8s  %s\n", $1, substr($0, index($0,$2)) }
    '
  fi
  echo
fi

cat <<'TIP'
════════════ 判据 ════════════
  1h 与 24h 都出现   → 仍在发生，值得归因
  仅 24h / 基线中出现 → 已恢复，不要动配置
  标 NEW / xN 的     → 相比基线突增，优先看
  同一目标高频集中    → 目标侧问题（节点/上游/客户端软件）
  分散且低频         → 通常是客户端行为噪音

三条同时成立才修：仍在发生 + 有可观测影响 + 根因有证据
详见 references/log-triage.md
TIP

rm -f "$TMP" 2>/dev/null || true
