#!/usr/bin/env sh
# log-correlate.sh — 跨日志时间轴（只读）
#
# 把 MosDNS 与 Mihomo 里匹配同一关键词的记录按时间合并，
# 用来回答"这条请求在 DNS 层和代理层分别发生了什么"。
#
# 用法:
#   ./log-correlate.sh <host> <关键词>            # 默认最近 30 分钟
#   ./log-correlate.sh <host> <关键词> --window 2h
#   ./log-correlate.sh <host> <关键词> --all      # 不限时间
#   ./log-correlate.sh <host> <关键词> --limit 100
#   ./log-correlate.sh <host> <关键词> --regex    # 关键词当正则用
#
# 关键词可以是域名、客户端 IP、节点主机名，或任意能 grep 到的文本。
# 只读。不写远端文件、不改配置、不重启服务。

set -u

PROFILE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/msf-skill"
HOST=""
PATTERN=""
WINDOW="30m"
LIMIT=60
REGEX=0
PROFILE="default"

while [ $# -gt 0 ]; do
  case "$1" in
    --window) WINDOW="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    --all) WINDOW="0" ; shift ;;
    --regex) REGEX=1; shift ;;
    --profile) PROFILE="$2"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "未知参数: $1" >&2; exit 2 ;;
    *)
      if [ -z "$HOST" ]; then HOST="$1"; else PATTERN="$1"; fi
      shift ;;
  esac
done

f="$PROFILE_DIR/profile.json"
[ -f "$PROFILE_DIR/profiles/$PROFILE.json" ] && f="$PROFILE_DIR/profiles/$PROFILE.json"
SSH_USER=""; SSH_KEY=""; DATA_DIR=""
if [ -f "$f" ] && command -v python3 >/dev/null 2>&1; then
  eval "$(python3 - "$f" <<'PY'
import json,sys,shlex
d=json.load(open(sys.argv[1]))
def g(k):
    v=d.get(k,"")
    return shlex.quote(str(v)) if v!="" else "''"
print(f"P_HOST={g('host')}")
print(f"SSH_USER={g('ssh_user')}")
print(f"SSH_KEY={g('ssh_key')}")
print(f"DATA_DIR={g('data_dir')}")
PY
)"
  [ -z "$HOST" ] && HOST="${P_HOST:-}"
fi

SSH_USER="${SSH_USER:-${MSF_SSH_USER:-}}"
SSH_KEY="${SSH_KEY:-${MSF_SSH_KEY:-}}"
DATA_DIR="${DATA_DIR:-${MSF_DATA_DIR:-/opt/msf}}"

[ -n "$HOST" ] || { echo "用法: $0 <host> <关键词>   （或先运行 bootstrap.sh）" >&2; exit 2; }
[ -n "$PATTERN" ] || { echo "缺少关键词。用法: $0 <host> <域名|IP|节点名>" >&2; exit 2; }
if [ -z "$SSH_USER" ] || [ -z "$SSH_KEY" ]; then
  echo "需要 SSH 访问 MSF 主机（日志在主机本地）。" >&2
  echo "可用 MSF_SSH_USER / MSF_SSH_KEY 临时指定。" >&2
  exit 2
fi

case "$WINDOW" in
  0|all) CUT="" ;;
  *m) CUT=$(date -u -d "-${WINDOW%m} minutes" +%Y-%m-%dT%H:%M:%S 2>/dev/null) ;;
  *h) CUT=$(date -u -d "-${WINDOW%h} hours" +%Y-%m-%dT%H:%M:%S 2>/dev/null) ;;
  *)  CUT="" ;;
esac

# 远端：分别抽取三边的 (排序键|显示时间|来源|文本)，再合并排序
REMOTE=$(cat <<'EOS'
set -u
LOG_D="$DATA/logs/mosdns.log"
LOG_M="$DATA/logs/mihomo.out.log"
MOS_API="${MOS_API:-9099}"
PAT="$PAT"
GREP_MODE="$GREP_MODE"
CUT="$CUT"
LIMIT="$LIM"

if [ "$GREP_MODE" = "E" ]; then
  G() { grep -E -- "$PAT" 2>/dev/null; }
else
  G() { grep -F -- "$PAT" 2>/dev/null; }
fi

# ---- MosDNS 文本日志：只有 WARN/ERROR，正常解析不在这里 ----
mos() {
  tail -n 50000 "$LOG_D" \
  | G \
  | awk -F'\t' 'NF>=5 {
      ts = substr($1,1,23);
      fmt = substr(ts,6,5) " " substr(ts,12,8) "." substr(ts,21,3);
      plugin = $3;
      rest = substr($0, index($0,$5));
      qn=""; if (match(rest, /"qname": "[^"]*"/)) qn=substr(rest, RSTART+10, RLENGTH-11);
      el=""; if (match(rest, /"elapsed": "[^"]*"/)) el=substr(rest, RSTART+12, RLENGTH-13);
      er=""; if (match(rest, /"error": "[^"]*"/)) er=substr(rest, RSTART+10, RLENGTH-11);
      if (qn != "") printf "%s|%s|MOS|%s  %s%s%s\n", ts, fmt, plugin, qn,
        (el!="" ? "  " el : ""), (er!="" ? "  ✗ " er : "");
      else printf "%s|%s|MOS|%s  %s\n", ts, fmt, plugin, substr(rest,1,140);
    }'
}

# ---- MosDNS 审计缓冲：正常解析在这里，服务端支持 q= 全文检索 ----
aud() {
  command -v curl >/dev/null 2>&1 || return 0
  curl -s -m 8 -G --data-urlencode "q=$PAT" --data-urlencode "page_size=50" \
       "http://127.0.0.1:$MOS_API/api/v2/audit/logs" 2>/dev/null \
  | grep -o '"client_ip":"[^"]*","query_type":"[^"]*","query_name":"[^"]*","query_class":"[^"]*","query_time":"[^"]*","duration_ms":[0-9.]*,"trace_id":"[^"]*","response_code":"[^"]*"' \
  | sed -E 's/.*"client_ip":"([^"]*)","query_type":"[^"]*","query_name":"([^"]*)","query_class":"[^"]*","query_time":"([^"]*)","duration_ms":([0-9.]*),"trace_id":"[^"]*","response_code":"([^"]*)".*/\3|\1|\2|\4|\5/' \
  | awk -F'|' '{
      t=$1; sub(/::ffff:/,"",$2);
      ts=substr(t,1,23);
      fmt = substr(ts,6,5) " " substr(ts,12,8) "." substr(ts,21,3);
      printf "%s|%s|AUD|%s  %s  %sms  client=%s\n", ts, fmt, $3, $5, $4, $2;
    }'
}

# ---- Mihomo：time="..." level=... msg="..." ----
mih() {
  grep -E 'level=(warning|error|info)' "$LOG_M" 2>/dev/null \
  | G \
  | sed -n 's/^time="\([^"]\{23\}\)[^"]*"[[:space:]]*level=[a-z]*[[:space:]]*msg="\(.*\)"$/\1|\2/p' \
  | awk -F'|' '{
      ts=$1; m=$2; gsub(/\\\\n/, " ⏎ ", m);
      fmt = substr(ts,6,5) " " substr(ts,12,8) "." substr(ts,21,3);
      printf "%s|%s|MIH|%s\n", ts, fmt, substr(m,1,160);
    }'
}

{ mos; aud; mih; } \
| awk -F'|' -v cut="$CUT" 'cut=="" || $1 >= cut' \
| sort -k1,1 \
| awk -F'|' -v lim="$LIMIT" 'NR<=lim { printf "%s  [%s]  %s\n", $2, $3, $4 }'
EOS
)

GREP_MODE=$([ "$REGEX" = 1 ] && echo E || echo F)
MOS_API="${MSF_MOSDNS_API:-9099}"

SSH_OPTS="-i $SSH_KEY -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
# shellcheck disable=SC2086
printf '%s\n' "$REMOTE" | ssh $SSH_OPTS "$SSH_USER@$HOST" \
  "export DATA='$DATA_DIR' PAT='$PATTERN' GREP_MODE='$GREP_MODE' CUT='$CUT' LIM='$LIMIT' MOS_API='$MOS_API'; sh -s" 2>&1 \
| {
    printf '跨日志时间轴  host=%s  关键词=%s  窗口=%s  上限=%s 条\n' "$HOST" "$PATTERN" "$WINDOW" "$LIMIT"
    printf '%s\n' "────────────────────────────────────────────────────────────"
    n=0
    while IFS= read -r line; do
      n=$((n+1))
      printf '%s\n' "$line"
    done
    if [ "$n" -eq 0 ]; then
      printf '  （该窗口内三处都没有匹配记录）\n'
      printf '  试试：--all 放宽时间，或换关键词（域名 / 客户端 IP / 节点主机名）\n'
    else
      printf '%s\n' "────────────────────────────────────────────────────────────"
      printf 'AUD = MosDNS 审计缓冲（DNS 阶段，含正常解析）\n'
      printf 'MOS = MosDNS 文本日志（仅 WARN/ERROR）\n'
      printf 'MIH = Mihomo（分流与出站）\n'
    fi
  }
