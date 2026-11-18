#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Разбор записи сессии Codex для замков мозга (ADR-0042).

Замки (красная зона, общая рабочая копия, сверка inventory, разбор /retro) писались под
запись сессии Claude Code. У Codex запись другая: `~/.codex/sessions/ГГГГ/ММ/ДД/rollout-*.jsonl`,
первая строка `session_meta`, дальше `response_item` (то, что видит модель) и `event_msg`
(события интерфейса). Этот модуль знает только формат Codex; формат Claude замки по-прежнему
читают сами, поэтому поведение под Claude Code не меняется.

ГЛАВНОЕ ПРАВИЛО (конституция C.11). Голос оператора в записи Codex только один:
`event_msg` с `payload.type == "user_message"`. Записи `response_item` с `role: "user"`
голосом оператора НЕ считаются: туда движок кладёт текст AGENTS.md (в нём есть образец фразы
красной зоны), контекст IDE (открытые вкладки) и другие вставки. Если считать их репликами,
фраза подтверждения из файла открыла бы замок сама. Проверено чтением настоящих записей
(разбор 18.11.2026, `knowledge/agent-runtime/_reference/codex-transcript.md`).

Запись субагента (`session_meta.payload.source` содержит `subagent`) реплик оператора не имеет
вовсе: оператор говорит только с основной сессией.

Модуль ничего не пишет на диск. Ошибка чтения возвращает None, решение (fail-closed или
fail-open) принимает сам замок.
"""
import glob
import html
import json
import os
import re

PATCH_FILE_RE = re.compile(r"^\*\*\* (?:Update|Add|Delete) File: (.+?)\s*$", re.M)
MOVE_TO_RE = re.compile(r"^\*\*\* Move to: (.+?)\s*$", re.M)
# Строковый литерал JS сразу после ключа cmd/command: "…", '…' или `…`.
JS_CMD_RE = re.compile(
    r"\b(?:cmd|command)\s*:\s*(\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*'|`(?:[^`\\]|\\.)*`)", re.S)


def codex_home():
    return os.environ.get("CODEX_HOME") or os.path.join(os.path.expanduser("~"), ".codex")


def _first_record(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if line:
                    return json.loads(line)
    except Exception:
        return None
    return None


def is_codex(path):
    """Запись Codex начинается со строки session_meta; у Claude такой нет."""
    if not path or not os.path.isfile(path):
        return False
    rec = _first_record(path)
    return isinstance(rec, dict) and rec.get("type") == "session_meta"


def find_transcript(session_id):
    """Путь к записи по id сессии: rollout-<время>-<id>.jsonl в любом дне."""
    if not session_id or not re.fullmatch(r"[A-Za-z0-9_-]+", session_id):
        return ""
    hits = glob.glob(os.path.join(codex_home(), "sessions", "*", "*", "*",
                                  "rollout-*" + session_id + ".jsonl"))
    return max(hits, key=os.path.getmtime) if hits else ""


def is_subagent_meta(meta):
    src = meta.get("source")
    if isinstance(src, dict) and "subagent" in src:
        return True
    return bool(meta.get("parent_thread_id"))


def latest_for_cwd(cwd):
    """Свежайшая запись основной сессии, открытой в этом каталоге (для /retro)."""
    best, best_m = "", -1.0
    for p in glob.glob(os.path.join(codex_home(), "sessions", "*", "*", "*", "rollout-*.jsonl")):
        rec = _first_record(p) or {}
        meta = rec.get("payload") or {}
        if rec.get("type") != "session_meta" or is_subagent_meta(meta):
            continue
        if os.path.realpath(meta.get("cwd") or "") != os.path.realpath(cwd):
            continue
        m = os.path.getmtime(p)
        if m > best_m:
            best, best_m = p, m
    return best


def load(path):
    recs = []
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    recs.append(json.loads(line))
                except Exception:
                    continue
    except Exception:
        return None
    return recs


def clean_text(s):
    """Текст реплики из интерфейса: убрать HTML-сущности и экранирование markdown."""
    s = html.unescape(s or "")
    return re.sub(r"\\([\\`*_{}\[\]()#+\-.!>~|])", r"\1", s)


def is_operator(rec):
    p = rec.get("payload") or {}
    return rec.get("type") == "event_msg" and p.get("type") == "user_message"


def operator_messages(path, recs=None):
    """Реплики оператора по порядку. None, если запись не прочитать."""
    recs = load(path) if recs is None else recs
    if recs is None:
        return None
    for r in recs:
        if r.get("type") == "session_meta":
            if is_subagent_meta(r.get("payload") or {}):
                return []
            break
    out = []
    for r in recs:
        if is_operator(r):
            t = clean_text((r.get("payload") or {}).get("message") or "")
            if t.strip():
                out.append(t)
    return out


def current_turn(recs):
    """Записи после последней реплики оператора и сам текст этой реплики."""
    start, last = 0, ""
    for i, r in enumerate(recs):
        if is_operator(r):
            start, last = i + 1, (r.get("payload") or {}).get("message") or ""
    return recs[start:], last


def _decode_js(lit):
    q = lit[0]
    if q == '"':
        try:
            return json.loads(lit)
        except Exception:
            return lit[1:-1]
    body = lit[1:-1]
    if q == "'":
        return body.replace("\\'", "'").replace("\\n", "\n").replace("\\\\", "\\")
    return body.replace("\\`", "`").replace("\\$", "$").replace("\\\\", "\\")


def _cmd_from_value(v):
    if isinstance(v, list):
        if len(v) >= 3 and v[0] in ("bash", "zsh", "sh") and v[1] in ("-lc", "-c"):
            return str(v[2])
        return " ".join(str(x) for x in v)
    return str(v) if v is not None else ""


def commands(recs):
    """Команды оболочки и тексты патчей, которые агент отдал инструментам.

    В режиме кода (custom_tool_call `exec`) агент пишет JavaScript, а команды лежат
    строками после ключа cmd/command. Если литерал собран из переменных и не разбирается,
    в список идёт весь исходник вызова: сопоставление идёт по нему целиком (fail-closed
    для замка красной зоны, лишний блок дешевле пропуска).
    """
    out = []
    for r in recs:
        if r.get("type") != "response_item":
            continue
        p = r.get("payload") or {}
        t = p.get("type")
        if t == "custom_tool_call":
            src = p.get("input") or ""
            found = [_decode_js(m.group(1)) for m in JS_CMD_RE.finditer(src)]
            if p.get("name") == "apply_patch" or src.lstrip().startswith("*** Begin Patch"):
                found.append(src)
            out.extend(found if found else [src])
        elif t == "function_call":
            try:
                a = json.loads(p.get("arguments") or "{}")
            except Exception:
                a = {"cmd": p.get("arguments") or ""}
            if isinstance(a, dict):
                for k in ("cmd", "command", "input", "patch"):
                    if k in a:
                        out.append(_cmd_from_value(a[k]))
        elif t == "local_shell_call":
            out.append(_cmd_from_value((p.get("action") or {}).get("command")))
    return [c for c in out if c]


def edited_paths(recs):
    """Карточки, затронутые подтверждённым применением патча."""
    out = []
    for r in recs:
        p = r.get("payload") or {}
        if r.get("type") != "event_msg" or p.get("type") != "patch_apply_end" or p.get("success") is not True:
            continue
        for path, change in (p.get("changes") or {}).items():
            if change.get("type") in ("add", "update"):
                out.append(change.get("move_path") or path)
    return out


def tool_corpus(recs):
    """Всё, что сессия передавала в инструменты: для замка авторства строк (ADR-0041)."""
    parts = []
    for r in recs:
        if r.get("type") != "response_item":
            continue
        p = r.get("payload") or {}
        if p.get("type") in ("custom_tool_call", "function_call"):
            parts.append(p.get("input") or p.get("arguments") or "")
        elif p.get("type") == "local_shell_call":
            parts.append(json.dumps(p.get("action") or {}, ensure_ascii=False))
    parts.extend(commands(recs))
    return parts


def patch_added_text(patch, name_suffix):
    """Добавленные строки патча для файлов, чьё имя кончается на name_suffix."""
    out, cur = [], None
    for line in (patch or "").splitlines():
        m = PATCH_FILE_RE.match(line)
        if m:
            cur = m.group(1)
            continue
        if line.startswith("*** "):
            continue
        if cur and cur.endswith(name_suffix) and line.startswith("+"):
            out.append(line[1:])
    return "\n".join(out)


if __name__ == "__main__":
    # Ручная проверка на настоящей записи: python3 codex_transcript.py <rollout.jsonl>
    import sys
    rs = load(sys.argv[1]) or []
    print("codex:", is_codex(sys.argv[1]))
    for m in operator_messages(sys.argv[1], rs) or []:
        print("ОПЕРАТОР:", m[:100].replace("\n", " "))
    for c in commands(rs)[:10]:
        print("КОМАНДА:", c[:100].replace("\n", " "))
    print("ПРАВКИ:", edited_paths(rs)[:10])
