#!/usr/bin/env python3
"""
extract-transcript.py — превращает JSONL-транскрипт сессии Claude Code в читаемый
дайджест для субагента-аудитора скилла /retro.

Источник истины — НАСТОЯЩИЙ лог сессии (не память агента, она необъективна).
Claude Code хранит транскрипты в ~/.claude/projects/<slug>/<session-id>.jsonl,
где <slug> — cwd с заменой не-буквенно-цифровых символов на «-».

Использование:
  python3 extract-transcript.py [SESSION]
    SESSION — id сессии, путь к .jsonl или пусто (тогда — свежайший транскрипт
              текущего проекта = текущая сессия).

Вывод: markdown-дайджест в stdout. Каждая реплика в хронологии:
  ОПЕРАТОР / АГЕНТ / [tool: name] / [result] — длинные блоки усечены.
Аудитор по этому дайджесту судит работу агента (см. references/audit-rubric.md).

Никаких изменений на диске не делает (Green Zone). PII оператора (IP, домены)
в дайджесте остаётся — поэтому дайджест и сырой отчёт живут в gitignore-зоне
retro/reviews/, а в трекаемый backlog идут только обезличенные находки (ADR-0017).

Секреты (пароли в URL, токены, API-ключи) РЕДАКТИРУЮТСЯ автоматически перед выводом
(находка ретро 2026-07-10: транскрипт содержал живые креды из вывода grep по конфигам;
digest — одна ошибка git add -f до утечки). Redaction — страховка, не индульгенция:
правило «читать файлы с секретами только с редакцией в самой команде» остаётся
(references/trust-zones.md, Green Zone).
"""
import sys, os, re, json, glob

TEXT_CAP = 3000          # макс. символов на текстовый блок
RESULT_CAP = 1500        # макс. символов на tool_result / вход tool_use

# Типовые секреты — замазываются до записи в дайджест. Git-хеши (40 hex) не трогаем:
# порог для голого hex — 48+ символов (64-hex токены), привязка аудитора к коммитам живёт.
SECRET_PATTERNS = [
    (re.compile(r'\bgithub_pat_[A-Za-z0-9_]{20,}'), '***GH-PAT***'),
    (re.compile(r'\bgh[pousr]_[A-Za-z0-9]{20,}\b'), '***GH-TOKEN***'),
    (re.compile(r'(://[^/\s:@"\']+:)[^@\s"\']+(@)'), r'\1***\2'),          # URL-креды
    (re.compile(r'\b[0-9a-f]{48,}\b'), '***HEX-TOKEN***'),
    (re.compile(r'\bsk-[A-Za-z0-9_-]{20,}'), '***API-KEY***'),
    (re.compile(r'\bAKIA[0-9A-Z]{16}\b'), '***AWS-KEY***'),
    (re.compile(r'(?i)\b(bearer\s+)[A-Za-z0-9._~+/=-]{16,}'), r'\1***'),
    (re.compile(r'(?i)((?:pass(?:word|wd|phrase)?|secret|token|api[_-]?key)\w*'
                r'["\']?\s*[:=]\s*["\']?)([^\s"\',;]{8,})'), r'\1***REDACTED***'),
]


def redact(s: str) -> str:
    for pat, repl in SECRET_PATTERNS:
        s = pat.sub(repl, s)
    return s


def project_dir() -> str:
    slug = re.sub(r'[^a-zA-Z0-9]', '-', os.getcwd())
    return os.path.join(os.path.expanduser('~/.claude/projects'), slug)


def _codex():
    """Разбор записи Codex (ADR-0042): модуль рядом с замками, .claude/hooks/."""
    here = os.path.dirname(os.path.abspath(__file__))
    hooks = os.path.normpath(os.path.join(here, '..', '..', '..', 'hooks'))
    if hooks not in sys.path:
        sys.path.insert(0, hooks)
    try:
        import codex_transcript
        return codex_transcript
    except Exception:
        return None


def resolve_transcript(arg: str | None) -> str:
    """Запись Claude Code или Codex. Без аргумента берётся свежайшая из обеих."""
    pdir = project_dir()
    cx = _codex()
    if arg:
        if os.path.isfile(arg):
            return arg
        cand = os.path.join(pdir, arg if arg.endswith('.jsonl') else arg + '.jsonl')
        if os.path.isfile(cand):
            return cand
        found = cx.find_transcript(arg) if cx else ''
        if found:
            return found
        sys.exit(f"ОШИБКА: транскрипт не найден: {arg}")
    files = glob.glob(os.path.join(pdir, '*.jsonl'))
    if cx:
        latest = cx.latest_for_cwd(os.getcwd())
        if latest:
            files.append(latest)
    if not files:
        sys.exit(f"ОШИБКА: нет транскриптов ни в {pdir}, ни в ~/.codex/sessions для этого "
                 f"каталога. Запущен ли разбор из каталога проекта?")
    return max(files, key=os.path.getmtime)


def codex_rows(recs, cx):
    """Строки дайджеста из записи Codex: оператор, агент, вызовы, результаты."""
    rows, n_op, n_ag, n_tool, ts = [], 0, 0, 0, []
    for r in recs:
        p = r.get('payload') or {}
        t, pt = r.get('type'), p.get('type')
        if r.get('timestamp'):
            ts.append(r['timestamp'])
        if t == 'event_msg' and pt == 'user_message':
            rows.append(('ОПЕРАТОР', clip(cx.clean_text(p.get('message', '')), TEXT_CAP))); n_op += 1
        elif t == 'response_item' and pt == 'message' and p.get('role') == 'assistant':
            txt = ' '.join(c.get('text', '') for c in p.get('content') or [] if isinstance(c, dict))
            if txt.strip():
                rows.append(('АГЕНТ', clip(txt, TEXT_CAP))); n_ag += 1
        elif t == 'response_item' and pt in ('custom_tool_call', 'function_call', 'local_shell_call'):
            body = p.get('input') or p.get('arguments') or json.dumps(p.get('action') or {}, ensure_ascii=False)
            rows.append(('АГЕНТ→ИНСТРУМЕНТ', f"[ВЫЗОВ ИНСТРУМЕНТА {p.get('name', pt)}] {clip(str(body), RESULT_CAP)}"))
        elif t == 'response_item' and pt in ('custom_tool_call_output', 'function_call_output'):
            out = p.get('output')
            out = out if isinstance(out, str) else json.dumps(out, ensure_ascii=False)
            rows.append(('РЕЗУЛЬТАТ', f"[РЕЗУЛЬТАТ] {clip(out, RESULT_CAP)}")); n_tool += 1
    return rows, n_op, n_ag, n_tool, (ts[0] if ts else None), (ts[-1] if ts else None)


def clip(s: str, cap: int) -> str:
    s = redact(s.rstrip())
    return s if len(s) <= cap else s[:cap] + f"\n… [усечено, всего {len(s)} симв.]"


def render_block(b: dict) -> str | None:
    t = b.get('type')
    if t == 'text':
        return clip(b.get('text', ''), TEXT_CAP)
    if t == 'tool_use':
        inp = json.dumps(b.get('input', {}), ensure_ascii=False)
        return f"[ВЫЗОВ ИНСТРУМЕНТА {b.get('name','?')}] {clip(inp, RESULT_CAP)}"
    if t == 'tool_result':
        c = b.get('content', '')
        if isinstance(c, list):
            c = '\n'.join(x.get('text', '') for x in c if isinstance(x, dict))
        return f"[РЕЗУЛЬТАТ] {clip(str(c), RESULT_CAP)}"
    return None


def main() -> None:
    arg = sys.argv[1] if len(sys.argv) > 1 else None
    path = resolve_transcript(arg)

    rows, n_op, n_ag, n_tool, ts_first, ts_last = [], 0, 0, 0, None, None
    cx = _codex()
    if cx and cx.is_codex(path):
        # Codex: голос оператора только event_msg/user_message; вставки движка (AGENTS.md,
        # контекст IDE) в дайджест не идут вовсе (codex-transcript.md, C.11).
        rows, n_op, n_ag, n_tool, ts_first, ts_last = codex_rows(cx.load(path) or [], cx)
    with open(path if not rows else os.devnull, encoding='utf-8') as fh:
        for line in fh:
            try:
                o = json.loads(line)
            except Exception:
                continue
            typ = o.get('type')
            if typ not in ('user', 'assistant'):
                continue
            ts = o.get('timestamp')
            if ts:
                ts_first = ts_first or ts
                ts_last = ts
            msg = o.get('message', {})
            content = msg.get('content', [])
            if isinstance(content, str):
                content = [{'type': 'text', 'text': content}]
            for b in content:
                if not isinstance(b, dict):
                    continue
                rendered = render_block(b)
                if not rendered or not rendered.strip():
                    continue
                bt = b.get('type')
                if typ == 'user' and bt == 'text':
                    # отсекаем инъекции харнесса — это не голос оператора
                    if rendered.lstrip().startswith('<system-reminder>'):
                        label = 'СИСТЕМА (reminder)'
                    else:
                        label = 'ОПЕРАТОР'; n_op += 1
                elif typ == 'user' and bt == 'tool_result':
                    label = 'РЕЗУЛЬТАТ'; n_tool += 1
                elif typ == 'assistant' and bt == 'tool_use':
                    label = 'АГЕНТ→ИНСТРУМЕНТ'
                elif typ == 'assistant':
                    label = 'АГЕНТ'; n_ag += 1
                else:
                    label = typ
                rows.append((label, rendered))

    print(f"# Дайджест сессии для аудита /retro\n")
    print(f"- Транскрипт: `{os.path.basename(path)}`")
    print(f"- Реплик оператора: {n_op} | ответов агента: {n_ag} | результатов инструментов: {n_tool}")
    print(f"- Период: {ts_first or '?'} → {ts_last or '?'}")
    print(f"\n> Гейт значимости: если реплик оператора < 2 и вызовов инструментов нет —")
    print(f"> сессия пустая, разбор не нужен (сообщи это оператору и остановись).\n")
    print("---\n")
    for label, text in rows:
        print(f"### {label}\n{text}\n")


if __name__ == '__main__':
    main()
