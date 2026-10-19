#!/usr/bin/env sh
# selftest.sh — 安装后自检
#
# 验证 skill 包完整性、凭据配置、远端连通性与依赖工具，
# 让新用户一眼看出"能不能用、缺什么"。
#
# 用法:
#   ./selftest.sh                # 全量自检（有 profile 时含远端探测）
#   ./selftest.sh <host>         # 指定 host
#   ./selftest.sh --local        # 只做本地静态检查，不联网
#   ./selftest.sh --no-ssh       # 跳过 SSH 相关检查
#   ./selftest.sh --profile home # 用命名 profile
#
# 只读。不写任何远端文件，不改配置。

set -u

SKILL_DIR=$(cd "$(dirname "$0")/.." && pwd)
PROFILE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/msf-skill"
# 与 CI 用同一套解析逻辑，避免两边算法不同互相掩盖问题
PYBIN=""
command -v python3 >/dev/null 2>&1 && PYBIN=python3
[ -z "$PYBIN" ] && command -v python >/dev/null 2>&1 && PYBIN=python
HOST=""
PROFILE="default"
LOCAL_ONLY=0
NO_SSH=0
SAVE_BASELINE_HINT=0

PASS=0; FAIL=0; WARN=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '  [ OK ] %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; [ $# -gt 1 ] && printf '         → %s\n' "$2"; }
warn() { WARN=$((WARN+1)); printf '  [WARN] %s\n' "$1"; [ $# -gt 1 ] && printf '         → %s\n' "$2"; }
skip() { SKIP=$((SKIP+1)); printf '  [SKIP] %s\n' "$1"; }
sec()  { printf '\n== %s ==\n' "$1"; }

# Git Bash / MSYS 下 ls 的权限位恒为 644，实际由 NTFS ACL 保护，不应据此报警
is_windows_shell() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --local) LOCAL_ONLY=1; shift ;;
    --no-ssh) NO_SSH=1; shift ;;
    --profile) PROFILE="$2"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "未知参数: $1" >&2; exit 2 ;;
    *) HOST="$1"; shift ;;
  esac
done

echo "MSF skill 自检"
echo "skill 目录: $SKILL_DIR"

# ══════════════════ A. 包完整性 ══════════════════
sec "A. 包完整性"

SKILL_MD="$SKILL_DIR/SKILL.md"
if [ -f "$SKILL_MD" ]; then ok "SKILL.md 存在"; else
  bad "SKILL.md 缺失" "skill 目录结构不对，应包含 SKILL.md"
fi

NAME=""
if [ -f "$SKILL_MD" ]; then
  NAME=$(sed -n 's/^name:[[:space:]]*\([a-z0-9-]*\)[[:space:]]*$/\1/p' "$SKILL_MD" | head -1)
  if [ -n "$NAME" ]; then
    if printf '%s' "$NAME" | grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*$'; then
      ok "frontmatter name 合法：$NAME"
    else
      bad "frontmatter name 不合规：$NAME" "只允许小写字母、数字、单连字符"
    fi
    DIRNAME=$(basename "$SKILL_DIR")
    if [ "$DIRNAME" = "$NAME" ]; then
      ok "目录名与 name 一致：$DIRNAME"
    else
      warn "目录名与 name 不一致（$DIRNAME ≠ $NAME）" "部分 agent 要求同名；可改目录名或改 name"
    fi
  else
    bad "frontmatter 缺少 name 或格式不对" "应为 name: <kebab-case>"
  fi

  if [ -n "$PYBIN" ]; then
    DESC_LEN=$("$PYBIN" - "$SKILL_MD" <<'PY' 2>/dev/null
import re, sys, pathlib
t = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
m = re.match(r"^---\r?\n(.*?)\r?\n---\r?\n", t, re.S)
fm = m.group(1) if m else ""
dm = re.search(r"^description:\s*(>-?|\|)\s*\n((?:[ \t]+.*\n)+)", fm, re.M)
if dm:
    d = " ".join(l.strip() for l in dm.group(2).splitlines()).strip()
else:
    dm = re.search(r"^description:\s*(.+)$", fm, re.M)
    d = dm.group(1).strip() if dm else ""
print(len(d))
PY
)
  else
    DESC_LEN=$(awk '
      /^description:/ {
        line=$0
        if (line ~ />-?[[:space:]]*$/ || line ~ /\|[[:space:]]*$/) { pend=1; next }
        sub(/^description:[[:space:]]*/,"",line); print line; exit
      }
      pend && /^[[:space:]]+/ { sub(/^[[:space:]]+/,""); printf "%s ", $0; next }
      pend && /^[^[:space:]]/ { exit }
    ' "$SKILL_MD" | wc -m | tr -d ' ')
  fi
  if [ "${DESC_LEN:-0}" -ge 1 ] && [ "${DESC_LEN:-0}" -le 1024 ]; then
    ok "description 长度 ${DESC_LEN} 字符（上限 1024）"
  else
    bad "description 缺失或超长（${DESC_LEN:-0}）" "需 1–1024 字符，且要写清「做什么」与「何时用」"
  fi
fi

MISS=0
for d in references scripts; do
  [ -d "$SKILL_DIR/$d" ] || { bad "缺少 $d/ 目录"; MISS=1; }
done
[ "$MISS" = 0 ] && ok "references/ 与 scripts/ 均存在"

if [ -f "$SKILL_MD" ]; then
  REFS=$({ grep -o '`references/[A-Za-z0-9._-]*`' "$SKILL_MD" 2>/dev/null
           grep -o '`scripts/[A-Za-z0-9._-]*`'   "$SKILL_MD" 2>/dev/null
         } | tr -d '`' | sort -u)
  RMBAD=""
  RN=0
  for r in $REFS; do
    RN=$((RN+1))
    [ -f "$SKILL_DIR/$r" ] || RMBAD="$RMBAD $r"
  done
  if [ -z "$RMBAD" ]; then
    ok "SKILL.md 引用的 $RN 个文件都存在"
  else
    bad "SKILL.md 引用了不存在的文件：$RMBAD"
  fi
fi

LINKBAD=""
for f in "$SKILL_DIR"/references/*.md; do
  [ -f "$f" ] || continue
  for r in $(grep -o '](\([A-Za-z0-9._-]*\.md\))' "$f" 2>/dev/null | sed 's/^](//; s/)$//' | sort -u); do
    [ -f "$(dirname "$f")/$r" ] || LINKBAD="$LINKBAD $(basename "$f")→$r"
  done
done
if [ -z "$LINKBAD" ]; then ok "references/ 之间的相对链接都有效"; else
  bad "存在失效链接：$LINKBAD"
fi

SHBAD=""
for f in "$SKILL_DIR"/scripts/*.sh; do
  [ -f "$f" ] || continue
  sh -n "$f" 2>/dev/null || SHBAD="$SHBAD $(basename "$f")"
  [ -x "$f" ] || SHBAD="$SHBAD $(basename "$f")(无执行位)"
done
if [ -z "$SHBAD" ]; then ok "所有 shell 脚本语法正确且可执行"; else
  bad "脚本问题：$SHBAD" "chmod +x scripts/*.sh"
fi

SECRET=""
for f in "$SKILL_DIR"/SKILL.md "$SKILL_DIR"/README.md "$SKILL_DIR"/references/*.md \
         "$SKILL_DIR"/scripts/*; do
  [ -f "$f" ] || continue
  grep -Eq 'ghp_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|BEGIN [A-Z ]*PRIVATE KEY' "$f" 2>/dev/null \
    && SECRET="$SECRET $(basename "$f")"
done
if [ -z "$SECRET" ]; then ok "未发现疑似凭据"; else bad "疑似凭据：$SECRET"; fi

# ══════════════════ B. 凭据配置 ══════════════════
sec "B. 凭据配置"

PF="$PROFILE_DIR/profile.json"
[ -f "$PROFILE_DIR/profiles/$PROFILE.json" ] && PF="$PROFILE_DIR/profiles/$PROFILE.json"

SSH_USER=""; SSH_KEY=""; DATA_DIR=""; DEPLOY=""
if [ -f "$PF" ]; then
  ok "profile 存在：$PF"
  if [ -n "$PYBIN" ]; then
    eval "$("$PYBIN" - "$PF" <<'PY'
import json,sys,shlex
d=json.load(open(sys.argv[1]))
def g(k):
    v=d.get(k,"")
    return shlex.quote(str(v)) if v!="" else "''"
print(f"P_HOST={g('host')}")
print(f"SSH_USER={g('ssh_user')}")
print(f"SSH_KEY={g('ssh_key')}")
print(f"DATA_DIR={g('data_dir')}")
print(f"DEPLOY={g('deploy_kind')}")
PY
)" 2>/dev/null || bad "profile.json 解析失败" "JSON 格式不对，或未安装 python3"
    [ -n "${P_HOST:-}" ] && [ -z "$HOST" ] && HOST="$P_HOST"
  else
    skip "python3 不可用，无法解析 profile（不影响其它检查）"
  fi
else
  # 无 profile 时允许环境变量临时指定，便于不落盘地做连通性验证
  SSH_USER="${MSF_SSH_USER:-}"
  SSH_KEY="${MSF_SSH_KEY:-}"
  DATA_DIR="${MSF_DATA_DIR:-}"
  [ -n "${MSF_HOST:-}" ] && [ -z "$HOST" ] && HOST="$MSF_HOST"
  if [ -n "$SSH_USER" ] && [ -n "$SSH_KEY" ]; then
    warn "尚未配置 profile（本次用环境变量）" "长期使用请运行 scripts/bootstrap.sh"
  else
    warn "尚未配置 profile" "运行 scripts/bootstrap.sh 完成首次配置"
  fi
fi

TOKEN_FILE="$PROFILE_DIR/token"
if [ -f "$TOKEN_FILE" ]; then
  if is_windows_shell; then
    ok "令牌文件存在（Windows 下权限由 NTFS ACL 决定，跳过权限位检查）"
  else
    PERM=$(ls -l "$TOKEN_FILE" 2>/dev/null | cut -c1-10)
    case "$PERM" in
      -rw-------) ok "令牌文件权限 0600" ;;
      *) warn "令牌文件权限为 $PERM" "chmod 600 $TOKEN_FILE" ;;
    esac
  fi
else
  skip "未配置 API 令牌（只能用免认证探测）"
fi

if [ -n "${SSH_KEY:-}" ]; then
  if [ -f "$SSH_KEY" ]; then
    if is_windows_shell; then
      ok "SSH 密钥存在（Windows 下权限由 NTFS ACL 决定，跳过权限位检查）"
    else
      PERM=$(ls -l "$SSH_KEY" 2>/dev/null | cut -c1-10)
      case "$PERM" in
        -rw-------) ok "SSH 密钥存在且权限 0600" ;;
        *) warn "SSH 密钥权限为 $PERM" "chmod 600 $SSH_KEY" ;;
      esac
    fi
  else
    bad "profile 里登记的 SSH 密钥不存在：$SSH_KEY"
  fi
else
  skip "未配置 SSH 密钥（宿主层检查不可用）"
fi

[ "$LOCAL_ONLY" = 1 ] && { echo; echo "（--local：跳过远端检查）"; }

# ══════════════════ C. 远端连通性 ══════════════════
if [ "$LOCAL_ONLY" != 1 ]; then
  sec "C. 远端连通性"

  if [ -z "$HOST" ]; then
    skip "没有已知 host，跳过（可用 ./selftest.sh <host> 指定）"
  else
    PORT="${MSF_PORT:-7777}"
    BASE="http://$HOST:$PORT"
    TOKEN=""
    [ -f "$TOKEN_FILE" ] && TOKEN=$(cat "$TOKEN_FILE" 2>/dev/null)

    if command -v curl >/dev/null 2>&1; then
      if curl -s -m 8 -o /dev/null -w '%{http_code}' "$BASE/api/v1/version" 2>/dev/null | grep -q '^200$'; then
        ok "WebUI 可达：$BASE"
      else
        bad "WebUI 不可达：$BASE" "确认 MSF 已启动、端口正确、无防火墙拦截"
      fi

      PRIV=$(curl -s -m 8 "$BASE/api/v1/setup/privilege" 2>/dev/null)
      if printf '%s' "$PRIV" | grep -q 'is_root'; then
        DK="systemd"
        printf '%s' "$PRIV" | grep -q '"docker":true' && DK="docker"
        printf '%s' "$PRIV" | grep -q '"macos":true'  && DK="macos"
        ok "运行时探测正常（判定形态：$DK）"
        if [ -n "$DEPLOY" ] && [ "$DEPLOY" != "$DK" ]; then
          warn "profile 记录形态为 $DEPLOY，实测 $DK" "必要时重跑 bootstrap.sh 更新 profile"
        fi
        printf '%s' "$PRIV" | grep -q '"is_root":false' && \
          warn "MSF 进程非 root" "53 端口 / TUN / nftables 将无法生效"
      else
        bad "setup/privilege 无响应" "WebUI 版本过旧或接口异常"
      fi

      if [ -n "$TOKEN" ]; then
        CODE=$(curl -s -m 8 -o /dev/null -w '%{http_code}' \
               -H "Authorization: Bearer $TOKEN" "$BASE/api/v1/auth/me" 2>/dev/null)
        case "$CODE" in
          200) ok "API 令牌有效" ;;
          401) bad "API 令牌无效（401）" "在 WebUI → API Token 重新签发，写入 $TOKEN_FILE" ;;
          403) warn "令牌有效但作用域不足（403）" "诊断需要 operate；read 看不到节点/连接/规则" ;;
          *)   warn "令牌校验返回 $CODE" "可能是网络问题或端点差异" ;;
        esac
        for ep in /api/v1/services /api/v1/monitor/system; do
          CODE=$(curl -s -m 8 -o /dev/null -w '%{http_code}' \
                 -H "Authorization: Bearer $TOKEN" "$BASE$ep" 2>/dev/null)
          [ "$CODE" = 200 ] && ok "读取 $ep 正常" || warn "读取 $ep 返回 $CODE" "作用域不足或该版本无此端点"
        done
      else
        skip "无令牌，跳过认证类探测"
      fi

      MOS="${MSF_MOSDNS_API:-9099}"
      if curl -s -m 5 "http://$HOST:$MOS/api/v1/audit/status" 2>/dev/null | grep -q 'capturing'; then
        ok "MosDNS API :$MOS 可达（日志分诊的 DNS 审计可用）"
      else
        warn "MosDNS API :$MOS 不可达" "log-triage 的 DNS 审计段会被跳过，其余功能不受影响"
      fi
    else
      bad "本机缺少 curl" "安装 curl 后重试"
    fi

    # SSH
    if [ "$NO_SSH" = 1 ]; then
      skip "SSH 检查（--no-ssh）"
    elif [ -n "${SSH_KEY:-}" ] && [ -n "${SSH_USER:-}" ] && [ -f "$SSH_KEY" ]; then
      OUT=$(ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
                -o ConnectTimeout=8 "$SSH_USER@$HOST" 'echo SELFTEST_OK; command -v msf >/dev/null && echo HAS_MSF' 2>/dev/null)
      if printf '%s' "$OUT" | grep -q SELFTEST_OK; then
        ok "SSH 免密可用（$SSH_USER@$HOST）"
        printf '%s' "$OUT" | grep -q HAS_MSF && ok "远端可执行 msf 命令" || \
          warn "远端 PATH 中找不到 msf" "日志与宿主检查改用绝对路径或 sudo"
        DD="${DATA_DIR:-}"
        if [ -z "$DD" ]; then
          case "${DEPLOY:-systemd}" in
            fnos) DD=/var/apps/msf/var ;;
            unraid) DD=/mnt/user/appdata/msf ;;
            macos) DD="/Library/Application Support/MSF" ;;
            *) DD=/opt/msf ;;
          esac
        fi
        if ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=8 "$SSH_USER@$HOST" \
             "test -d '$DD/logs'" 2>/dev/null; then
          ok "数据目录存在：$DD"
        else
          bad "数据目录不存在：$DD" "在 profile 里把 data_dir 改成实际路径"
        fi
        DMISS=""
        for c in grep sed awk date tail sort uniq head curl; do
          ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=8 "$SSH_USER@$HOST" \
              "command -v $c >/dev/null" 2>/dev/null || DMISS="$DMISS $c"
        done
        if [ -z "$DMISS" ]; then ok "远端依赖工具齐全"; else
          bad "远端缺少工具：$DMISS" "log-triage.sh 需要它们做归一化聚合"
        fi
      else
        bad "SSH 不可用（$SSH_USER@$HOST）" "确认公钥已在 authorized_keys，或用 bootstrap.sh 重新配置"
      fi
    else
      skip "未配置 SSH 密钥，跳过宿主层检查"
    fi
  fi
fi

# ══════════════════ 汇总 ══════════════════
printf '\n== 结果 ==\n'
printf '  通过 %s  失败 %s  警告 %s  跳过 %s\n' "$PASS" "$FAIL" "$WARN" "$SKIP"

if [ "$FAIL" -gt 0 ]; then
  printf '\n存在失败项，先修掉再使用。\n'
  exit 1
fi

if [ "$PASS" -eq 0 ]; then
  printf '\n没有跑成任何检查，环境异常。\n'
  exit 1
fi

printf '\n基础可用。建议接下来：\n'
if [ -f "$PF" ]; then
  printf '  1) bash scripts/log-triage.sh <host> --baseline-save   建一次基线\n'
  printf '     bash scripts/log-triage.sh <host>                   之后每次自动比对\n'
else
  printf '  1) bash scripts/bootstrap.sh                          首次配置\n'
  printf '  2) bash scripts/log-triage.sh <host> --baseline-save  建一次基线\n'
fi
exit 0
