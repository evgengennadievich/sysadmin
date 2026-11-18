#!/usr/bin/env bash
# build-agents-md.sh — собирает AGENTS.md (ядро для Codex) из адаптера и CLAUDE.md (ADR-0042).
#
# ЗАЧЕМ. Ядро персоны одно, агентов два. Claude Code читает CLAUDE.md, Codex читает
# AGENTS.md. Две ручные копии разошлись бы на первой же правке (класс дефекта «выжимка
# врёт», ADR-0015), поэтому AGENTS.md не пишется руками, а собирается:
#   codex/AGENTS.header.md  — что в Codex устроено иначе (скиллы, хуки, память);
#   CLAUDE.md без первой строки-заголовка — само ядро, байт в байт.
#
# Использование:
#   bash scripts/build-agents-md.sh           — пересобрать AGENTS.md
#   bash scripts/build-agents-md.sh --check [папка-снимок]  — сверить исходники и итог
#
# Предел Codex: инструкции читаются до project_doc_max_bytes (по умолчанию 32 КиБ) вместе
# с ~/.codex/AGENTS.md. Скрипт печатает размер и напоминает поднять предел (INSTALL.md).

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ "${1:-}" = "--check" ] && [ -n "${2:-}" ]; then
  ROOT="$2"
fi
HEADER="$ROOT/codex/AGENTS.header.md"
CORE="$ROOT/CLAUDE.md"
OUT="$ROOT/AGENTS.md"

[ -f "$HEADER" ] || { echo "нет адаптера: $HEADER" >&2; exit 2; }
[ -f "$CORE" ]   || { echo "нет ядра: $CORE" >&2; exit 2; }

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
{
  cat "$HEADER"
  tail -n +2 "$CORE"
} > "$TMP"

if [ "${1:-}" = "--check" ]; then
  if [ -f "$OUT" ] && cmp -s "$TMP" "$OUT"; then
    exit 0
  fi
  echo "AGENTS.md разошёлся с CLAUDE.md + codex/AGENTS.header.md." >&2
  echo "Пересобери: bash scripts/build-agents-md.sh, затем git add AGENTS.md" >&2
  exit 1
fi

cp "$TMP" "$OUT"
BYTES="$(wc -c < "$OUT" | tr -d ' ')"
echo "AGENTS.md собран: ${BYTES} Б."
echo "Codex читает инструкции до project_doc_max_bytes (по умолчанию 32768 Б) вместе с"
echo "~/.codex/AGENTS.md. В ~/.codex/config.toml должно стоять project_doc_max_bytes = 98304."
