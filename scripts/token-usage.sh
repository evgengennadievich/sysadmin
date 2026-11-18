#!/bin/bash
# Замер расхода контекста по транскриптам Claude Code (ADR-0040).
#   bash scripts/token-usage.sh              — сводка по всем проектам
#   bash scripts/token-usage.sh detail СЛАГ  — инструменты, повторы и чтения одного проекта
#   bash scripts/token-usage.sh codex        — только сессии Codex (ADR-0042)
# Источник: ~/.claude/projects/*/*.jsonl, поле usage; дедупликация по message.id.
# Шкала стоимости: вход x1, запись кеша x1.25, чтение кеша x0.1, выход x5.
set -uo pipefail
P="$HOME/.claude/projects"
command -v jq >/dev/null || { echo "нужен jq"; exit 1; }

summary() {
  printf "%-5s %-8s %-8s %-8s %-7s %s\n" "сесс" "out_k" "зап_k" "чт_M" "усл.ед" "проект"
  for d in "$P"/*/; do
    files=("$d"*.jsonl); [ -e "${files[0]}" ] || continue
    cwd=$(head -60 "${files[0]}" | jq -r 'select(.cwd) | .cwd' 2>/dev/null | head -1)
    [ -z "$cwd" ] && cwd=$(basename "$d")
    cat "${files[@]}" 2>/dev/null \
      | jq -r 'select(.type=="assistant" and .message.id)
               | [.message.id,(.message.usage.output_tokens//0),
                  (.message.usage.cache_creation_input_tokens//0),
                  (.message.usage.cache_read_input_tokens//0),
                  (.message.usage.input_tokens//0)] | @tsv' 2>/dev/null \
      | sort -u -k1,1 \
      | awk -v c="$cwd" -v n="${#files[@]}" -F'\t' \
          '{o+=$2;cc+=$3;cr+=$4;i+=$5}
           END{if(o+cc>0) printf "%-5d %-8.0f %-8.0f %-8.2f %-7.1f %s\n",
               n,o/1000,cc/1000,cr/1000000,(i+cc*1.25+cr*0.1+o*5)/1000000,c}'
  done | sort -k5 -rn
}

detail() {
  slug="$1"; d="$P/$1/"
  [ -d "$d" ] || { echo "нет такого проекта: $slug"; exit 1; }
  TMP=$(mktemp -t tokenusage) || exit 1
  trap 'rm -f "$TMP"' EXIT
  for f in "$d"*.jsonl; do
    [ -e "$f" ] || continue
    sid=$(basename "$f" .jsonl)
    jq -r --arg sid "$sid" '
      if .type=="assistant" and (.message.content|type=="array") then
        (.message.content[] | select(.type=="tool_use")
         | ["U",$sid,.id,.name,((.input.command // .input.file_path // .input.pattern // .input.query // "")|tostring|gsub("[\n\t]";" "))] | @tsv)
      elif .type=="user" and (.message.content|type=="array") then
        (.message.content[] | select(.type=="tool_result")
         | ["R",$sid,.tool_use_id,"",((.content|tostring)|length|tostring)] | @tsv)
      else empty end' "$f" 2>/dev/null >> "$TMP"
  done
  awk -F'\t' '
    $1=="U"{ s[$3]=$2; t[$3]=$4; c[$3]=$5; cnt[$4]++ }
    $1=="R"{ if($3 in t) len[$3]=$5 }
    END{
      for(id in t){
        k=s[id]"|"t[id]"|"c[id]; seen[k]++; tot++
        tl[t[id]]+=len[id]
        if(seen[k]>1){ dup++; dupl+=len[id] }
        if(t[id]=="Read"){ if(c[id] ~ /claude-501|\/tmp\//){rt++; rtl+=len[id]} else {rp++; rpl+=len[id]} }
      }
      print "инструмент: вызовов, объём результатов"
      for(x in cnt) printf "  %-16s %5d  %8.1f млн симв\n", x, cnt[x], tl[x]/1000000
      printf "\nточных повторов вызова внутри сессии: %d из %d (%.0f%%), %.1f млн симв\n", dup, tot, 100*dup/tot, dupl/1000000
      printf "чтение своего временного каталога: %d шт, %.1f млн симв\n", rt, rtl/1000000
      printf "чтение файлов проекта:             %d шт, %.1f млн симв\n", rp, rpl/1000000
    }' "$TMP"
}

# Codex (ADR-0042): записи ~/.codex/sessions/ГГГГ/ММ/ДД/rollout-*.jsonl. Расход берётся из
# последнего event_msg/token_count каждой записи (там накопленный итог сессии), проект —
# из session_meta.cwd. Шкала Codex своя: вход без кеша x1, чтение кеша x0.1, выход x5 —
# те же условные единицы, но тарифы и лимиты у Codex другие, сравнивать с Claude напрямую
# нельзя (правило «срок годности» в ~/.codex/AGENTS.md).
codex_summary() {
  local C="${CODEX_HOME:-$HOME/.codex}/sessions"
  [ -d "$C" ] || { echo "нет записей Codex в $C"; return 0; }
  printf "%-5s %-8s %-8s %-8s %-7s %s\n" "сесс" "out_k" "вход_k" "кеш_M" "усл.ед" "проект (Codex)"
  command -v python3 >/dev/null || { echo "для замера Codex нужен python3"; return 0; }
  python3 - "$C" <<'PY' | sort -k5 -rn
import glob, json, os, sys
agg = {}
for f in glob.glob(os.path.join(sys.argv[1], "*", "*", "*", "rollout-*.jsonl")):
    cwd, last = None, None
    with open(f, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                d = json.loads(line)
            except Exception:
                continue
            p = d.get("payload") or {}
            if d.get("type") == "session_meta" and cwd is None:
                cwd = p.get("cwd") or "?"
            elif d.get("type") == "event_msg" and p.get("type") == "token_count" and p.get("info"):
                last = p["info"].get("total_token_usage") or last
    if not last:
        continue
    a = agg.setdefault(cwd or "?", [0, 0, 0, 0])
    a[0] += 1
    a[1] += last.get("output_tokens", 0)
    a[2] += last.get("input_tokens", 0) - last.get("cached_input_tokens", 0)
    a[3] += last.get("cached_input_tokens", 0)
for k, (n, o, i, c) in agg.items():
    print("%-5d %-8.0f %-8.0f %-8.2f %-7.1f %s" % (n, o / 1e3, i / 1e3, c / 1e6, (i + c * 0.1 + o * 5) / 1e6, k))
PY
}

case "${1:-}" in
  detail) detail "${2:?укажи слаг проекта из ~/.claude/projects}" ;;
  codex)  codex_summary ;;
  *)      summary; echo; codex_summary ;;
esac
