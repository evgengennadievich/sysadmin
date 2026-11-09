#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Замок общей рабочей копии нескольких сессий агента (ADR-0041).

Несколько сессий работают в ОДНОЙ папке репозитория (infra, sysadmin) и коммитят в одну
ветку. Поимённый коммит защищает от чужих файлов только частично, а `git push` отправляет
ветку целиком. Ожоги: 02.09 и 03.09.2026 (чужое уехало в мой коммит), 27.10.2026 (чужой
индекс уехал в мой коммит), 09.11.2026 (push унёс чужие коммиты, в обе стороны).

Проверки на команды Bash с git (PreToolUse):
  1. push: в отправку не уходят коммиты, которые сделала НЕ эта сессия, пока оператор не
     написал фразу PUSH_PHRASE в своей ПОСЛЕДНЕЙ реплике. Запрет.
  2. commit без явных путей: в индексе нет файлов, не названных в этой же команде (иначе
     чужие подготовленные файлы уедут в мой коммит). Запрет; выход: `git commit -- <пути>`.
     Сюда же `--amend` поверх коммита, который сделала не эта сессия. Запрет.
  3. commit: строки, которых эта сессия не писала (нет ни в одном её вызове инструментов),
     показываются до коммита. Это «лежачий полицейский», а не запрет: авторство строки
     определяется приблизительно (вариант Б, решение Евгения 09.11.2026). Повтор той же
     команды с пометкой ACK_MARK проходит.
После выполнения (PostToolUse) сессия записывает свои новые коммиты в файл состояния.

Границы (что замок НЕ делает, записано в ADR-0041):
  - без python3 не работает (обёртка выходит молча);
  - коммит, сделанный не командой Bash с текстом «git commit» (скрипт через bash -s, ручной
    коммит в терминале), сессия своим не считает: его отправка потребует фразы оператора;
  - git внутри `ssh …` (репозитории на сервере) не проверяется;
  - сеть не трогает: устаревшие ссылки на сервер покажут лишние «чужие» коммиты, лечится
    отдельной командой `git fetch`.
Каноны фразы и пометки: .claude/agents/references/trust-zones.md, раздел P16. Тест:
.claude/hooks/tests/test-session-git-guard.sh (берёт каноны оттуда, а не из этого файла).
"""
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import time
import unicodedata

# Вывод читает движок, а не терминал: печатаем UTF-8 при любой кодовой странице консоли
# (правило 3д свода замков). Хук запускается с `python3 -I`, переменные PYTHON* при этом
# игнорируются, поэтому кодировку ставим здесь, а не в окружении.
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

PUSH_PHRASE = "отправляй вместе с чужими"
ACK_MARK = "SESSION_GIT_ACK=1"
MIN_LINE = 12        # строки короче не проверяем на авторство: слишком много совпадений
SHOW = 12            # сколько строк или коммитов показывать в сообщении

TOKEN = r'"[^"]*"|\'[^\']*\'|[^\s;&|()<>]+'
ASSIGN_RE = re.compile(r'(?:^|[\s;&|(])([A-Za-z_][A-Za-z0-9_]*)=(' + TOKEN + r')')
# Перед `git` допустим `/`: `/usr/bin/git push` иначе проходил мимо замка (фикстура обхода).
GIT_RE = re.compile(
    r'(?<![\w.-])git((?:\s+(?:-C\s+(?:' + TOKEN + r')|-c\s+(?:' + TOKEN + r')'
    r'|--?[A-Za-z][\w-]*(?:=(?:' + TOKEN + r'))?))*)\s+(commit|push|add)\b')
CD_RE = re.compile(r'(?<![\w-])cd\s+(' + TOKEN + r')')
SEG_END_RE = re.compile(r'&&|\|\||;|\||\n|\)')


def nfc(s):
    return unicodedata.normalize("NFC", s)


def norm(s):
    return re.sub(r"\s+", " ", nfc(s)).strip()


def state_dir():
    d = os.environ.get("SESSION_GIT_STATE_DIR") or os.path.join(
        os.path.expanduser("~"), ".claude", "state", "session-git")
    os.makedirs(d, exist_ok=True)
    return d


def safe_id(s):
    return re.sub(r"[^A-Za-z0-9_.-]", "_", s or "nosession")


def git(repo, *args):
    try:
        r = subprocess.run(["git", "-c", "core.quotePath=false", "-C", repo, *args],
                           capture_output=True, text=True, encoding="utf-8",
                           errors="replace", timeout=8)
    except Exception:
        return None
    return r.stdout if r.returncode == 0 else None


def deny(reason):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason}}, ensure_ascii=False))
    sys.exit(0)


# ── разбор команды ────────────────────────────────────────────────────────────

def unquote(tok):
    if len(tok) >= 2 and tok[0] == tok[-1] and tok[0] in "\"'":
        return tok[1:-1]
    return tok


def collect_vars(cmd):
    vals = {}
    for m in ASSIGN_RE.finditer(cmd):
        raw = m.group(2)
        if "$(" in raw or "`" in raw:
            continue
        vals[m.group(1)] = raw
    out = {}
    for _ in range(3):  # значения могут ссылаться друг на друга
        for k, raw in vals.items():
            out[k] = expand(raw, out)
    return out


def expand(tok, vars_):
    single = len(tok) >= 2 and tok[0] == "'" and tok[-1] == "'"
    s = unquote(tok)
    if single:
        return s

    def sub(m):
        name = m.group(1) or m.group(2)
        if name in vars_:
            return vars_[name]
        if name == "HOME":
            return os.path.expanduser("~")
        return m.group(0)
    s = re.sub(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)', sub, s)
    if s.startswith("~"):
        s = os.path.expanduser("~") + s[1:]
    return s


def segment_after(cmd, pos):
    m = SEG_END_RE.search(cmd, pos)
    return cmd[pos:m.start()] if m else cmd[pos:]


def split_args(text, vars_):
    try:
        toks = shlex.split(text, posix=True)
    except ValueError:
        toks = text.split()
    out = []
    for t in toks:
        if t.startswith("<<") or t in ("<", ">", ">>"):
            break
        out.append(expand(t, vars_) if "$" in t or t.startswith("~") else t)
    return out


def invocations(cmd, cwd):
    """Список вызовов git commit/push/add: (вид, позиция, каталог, аргументы)."""
    vars_ = collect_vars(cmd)
    found = []
    for m in GIT_RE.finditer(cmd):
        line_start = cmd.rfind("\n", 0, m.start()) + 1
        if re.search(r'(?<![\w-])ssh\b', cmd[line_start:m.start()]):
            continue  # git на сервере: не наша рабочая копия
        cm = re.search(r'-C\s+(' + TOKEN + r')', m.group(1) or "")
        if cm:
            d = expand(cm.group(1), vars_)
        else:
            cds = list(CD_RE.finditer(cmd[:m.start()]))
            d = expand(cds[-1].group(1), vars_) if cds else cwd
        if "$" in d:
            d = None
        elif not os.path.isabs(d):
            d = os.path.normpath(os.path.join(cwd, d))
        args = split_args(segment_after(cmd, m.end()), vars_)
        found.append((m.group(2), m.start(), d, args))
    return found, vars_


def toplevel(d):
    if not d or not os.path.isdir(d):
        return None
    top = git(d, "rev-parse", "--show-toplevel")
    return nfc(os.path.realpath(top.strip())) if top else None


def rel(top, base, p):
    # Оба пути приводятся к настоящему виду: git называет корень через realpath, а команда
    # могла прийти по ссылке (/var → /private/var на macOS). Без этого путь файла выходил
    # «за пределы репозитория», git diff не давал строк, и проверка чужих строк молча
    # пропускала коммит (поймано тестом [3] 09.11.2026 при первом прогоне).
    ap = p if os.path.isabs(p) else os.path.join(base or top, p)
    ap = os.path.realpath(os.path.normpath(ap))
    try:
        r = os.path.relpath(nfc(ap), nfc(os.path.realpath(top)))
    except ValueError:
        return nfc(p)
    return nfc(r)


# ── память сессии ─────────────────────────────────────────────────────────────

def commits_file(sid):
    return os.path.join(state_dir(), safe_id(sid) + ".commits")


def my_commits(sid, top):
    mine = set()
    try:
        with open(commits_file(sid), encoding="utf-8") as f:
            for line in f:
                parts = line.rstrip("\n").split("\t")
                if len(parts) == 2 and parts[0] == top:
                    mine.add(parts[1])
    except FileNotFoundError:
        pass
    return mine


def pending_file(sid):
    return os.path.join(state_dir(), safe_id(sid) + ".pending.json")


def cmd_key(cmd):
    return hashlib.sha256(cmd.encode("utf-8", "replace")).hexdigest()[:16]


def load_pending(sid):
    try:
        with open(pending_file(sid), encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def save_pending(sid, data):
    with open(pending_file(sid), "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)


# ── транскрипт ────────────────────────────────────────────────────────────────

def operator_messages(path):
    """Реплики оператора; вставки движка, вывод инструментов и субагенты отсечены
    тем же фильтром, что в замке красной зоны (C.11)."""
    msgs = []
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                if rec.get("type") != "user":
                    continue
                if rec.get("isMeta") or rec.get("sourceToolUseID") or rec.get("isSidechain"):
                    continue
                m = rec.get("message") or {}
                if m.get("role") != "user":
                    continue
                c = m.get("content")
                if isinstance(c, list):
                    if any(isinstance(b, dict) and b.get("type") == "tool_result" for b in c):
                        continue
                    c = " ".join(b.get("text", "") for b in c
                                 if isinstance(b, dict) and b.get("type") == "text")
                if not isinstance(c, str) or not c.strip():
                    continue
                if c.lstrip().startswith(("<command-name>", "<local-command-", "<command-message>",
                                          "<system-reminder>", "Base directory for this skill")):
                    continue
                msgs.append(c)
    except Exception:
        return None
    return msgs


def phrase_ok(transcript):
    if not transcript or not os.path.isfile(transcript):
        return False
    msgs = operator_messages(transcript)
    if not msgs:
        return False
    last = nfc(msgs[-1]).lower().replace("ё", "е")
    return PUSH_PHRASE.replace("ё", "е") in last


def own_corpus(transcript, cmd):
    """Всё, что эта сессия передавала в инструменты: команды, тексты Write, правки Edit."""
    parts = [cmd]

    def walk(v):
        if isinstance(v, str):
            parts.append(v)
        elif isinstance(v, dict):
            for x in v.values():
                walk(x)
        elif isinstance(v, list):
            for x in v:
                walk(x)
    if not transcript or not os.path.isfile(transcript):
        return None
    try:
        with open(transcript, encoding="utf-8", errors="replace") as f:
            for line in f:
                if '"tool_use"' not in line:
                    continue
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                if rec.get("type") != "assistant":
                    continue
                for b in (rec.get("message") or {}).get("content") or []:
                    if isinstance(b, dict) and b.get("type") == "tool_use":
                        walk(b.get("input"))
    except Exception:
        return None
    text = norm("\n".join(parts))
    return text, re.sub(r"\d", "", text)


def covered(s, text, max_pieces=3, min_piece=10, old=""):
    """Строка собрана не больше чем из max_pieces кусков, каждый есть в вызовах сессии.

    Частичная правка (Edit заменил кусок строки, sed поменял слово) даёт строку, которой
    целиком нет ни в одном вызове: начало из исходного файла, середина из правки. Без этой
    проверки замок останавливал собственную правку агента (проба по настоящему транскрипту
    09.11.2026: 1 строка из 598). Чужая строка о другом деле тремя длинными кусками из
    вызовов этой сессии не собирается. Жадно берём самый длинный кусок с текущего места.

    old: удалённые строки того же изменения. Правка части уже закоммиченной строки
    оставляет в ней прежний хвост; он есть в старой версии строки, а не в вызовах сессии,
    и без этого источника своя правка ядра выглядела чужой. Новых слов соседа в удалённых
    строках нет, поэтому чужая правка по-прежнему видна.
    """
    i, pieces = 0, 0
    while len(s) - i > 2:
        if pieces == max_pieces:
            return False
        lo, hi = 0, len(s) - i
        while lo < hi:
            mid = (lo + hi + 1) // 2
            frag = s[i:i + mid]
            if frag in text or (old and frag in old):
                lo = mid
            else:
                hi = mid - 1
        if lo < min_piece:
            return False
        i += lo
        pieces += 1
    return True


# ── проверки ──────────────────────────────────────────────────────────────────

VALUE_OPTS = {"-m", "-F", "-C", "-c", "-t", "--author", "--date", "--cleanup", "--fixup",
              "--squash", "--file", "--message", "--template", "--reuse-message",
              "--reedit-message", "--trailer"}


def parse_commit(args):
    paths, all_, amend, i, after_dd = [], False, False, 0, False
    while i < len(args):
        t = args[i]
        if after_dd:
            paths.append(t)
        elif t == "--":
            after_dd = True
        elif t in ("-a", "--all"):
            all_ = True
        elif t == "--amend":
            amend = True
        elif t in VALUE_OPTS:
            i += 1
        elif t.startswith("--"):
            pass
        elif re.fullmatch(r"-[A-Za-z]+", t):
            flags = t[1:]
            if "a" in flags.split("m")[0]:
                all_ = True
            if flags[-1] in "mFCct":
                i += 1
        elif t.startswith("-"):
            pass
        else:
            paths.append(t)
        i += 1
    return paths, all_, amend


def parse_add(args):
    out, after_dd = [], False
    for t in args:
        if after_dd or not t.startswith("-"):
            out.append(t)
        elif t == "--":
            after_dd = True
    return out


def check_commit(top, base, args, cmd, vars_, adds, sid, transcript):
    paths, all_, amend = parse_commit(args)
    if amend:
        head = (git(top, "rev-parse", "HEAD") or "").strip()
        if head and head not in my_commits(sid, top):
            subj = (git(top, "log", "-1", "--format=%h %s") or "").strip()
            deny("🟠 ЗАМОК ОБЩЕЙ ПАПКИ (ADR-0041): `git commit --amend` перепишет коммит, который "
                 "сделала не эта сессия:\n  " + subj + "\nВ общей папке последний коммит может "
                 "быть соседским. Сделай отдельный коммит, а не поправку.")
    if paths:
        commit_set = [rel(top, base, p) for p in paths]
    else:
        st = git(top, "diff", "--cached", "--name-status", "-M") or ""
        entries = []
        for line in st.splitlines():
            parts = line.split("\t")
            if len(parts) >= 2:
                entries.append([nfc(x) for x in parts[1:]])
        if all_:
            for p in (git(top, "diff", "--name-only") or "").splitlines():
                entries.append([nfc(p)])
        add_rel = [rel(top, base, p) for p in adds]
        text = nfc(cmd)

        def named(p):
            if p in add_rel or p in text or os.path.join(top, p) in text:
                return True
            return any(a.endswith("/") and p.startswith(a) for a in add_rel) or \
                any(os.path.isdir(os.path.join(top, a)) and p.startswith(a.rstrip("/") + "/")
                    for a in add_rel)
        unnamed = [e for e in entries if not any(named(p) for p in e)]
        if unnamed:
            lst = "\n".join("  " + " → ".join(e) for e in unnamed[:SHOW])
            deny("🟠 ЗАМОК ОБЩЕЙ ПАПКИ (ADR-0041): в индексе лежат файлы, которые эта команда "
                 "не называет:\n" + lst + "\n`git commit` без путей забрал бы их в твой коммит "
                 "под твоим сообщением; скорее всего их подготовила соседняя сессия (случай "
                 "27.10.2026).\nКак правильно: коммить свои файлы явными путями, "
                 "`git commit -m … -- <твои пути>`: git возьмёт только их и не тронет чужое в "
                 "индексе. Если файлы твои (например, `git mv` прошлым шагом), назови их в "
                 "команде; у переименования оба пути.")
        commit_set = sorted({p for e in entries for p in e} | set(add_rel))
    if ACK_MARK in cmd or not commit_set:
        return
    if not git(top, "rev-parse", "--verify", "-q", "HEAD"):
        return
    diff = git(top, "diff", "HEAD", "--no-color", "-U0", "-M", "--", *commit_set) or ""
    added = [l[1:] for l in diff.splitlines() if l.startswith("+") and not l.startswith("+++")]
    # Новые файлы до `git add` в diff не видны: без этого строки нового файла, добавляемого
    # той же командой, не проверялись вовсе (замечено на пробе по настоящему транскрипту).
    untracked = git(top, "ls-files", "--others", "--exclude-standard", "--", *commit_set) or ""
    for p in untracked.splitlines():
        fp = os.path.join(top, p)
        try:
            if os.path.getsize(fp) <= 2_000_000:
                with open(fp, encoding="utf-8", errors="replace") as f:
                    added.extend(f.read().splitlines())
        except OSError:
            pass
    added = [l for l in added if len(norm(l)) >= MIN_LINE and re.search(r"\w", l)]
    if not added:
        return
    corpus = own_corpus(transcript, cmd)
    if corpus is None:
        return  # нечем судить об авторстве: молчим, а не останавливаем всё подряд
    text, text_nd = corpus
    old = norm("\n".join(l[1:] for l in diff.splitlines()
                         if l.startswith("-") and not l.startswith("---")))
    sus = [l for l in added
           if norm(l) not in text and re.sub(r"\d", "", norm(l)) not in text_nd
           and not covered(norm(l), text, old=old)]
    if not sus:
        return
    lst = "\n".join("  | " + norm(l)[:140] for l in sus[:SHOW])
    more = "" if len(sus) <= SHOW else "\n  … ещё " + str(len(sus) - SHOW)
    deny("🟡 ЛЕЖАЧИЙ ПОЛИЦЕЙСКИЙ (ADR-0041): в коммит попадут строки, которых эта сессия не "
         "писала (их нет ни в одном её вызове инструментов), " + str(len(sus)) + " из "
         + str(len(added)) + ":\n" + lst + more + "\nЭто может быть незакоммиченная работа "
         "соседней сессии в общем файле (случай 03.09.2026) или строка, которую изменила "
         "подстановка (дата, вывод команды, замена sed).\nПроверь `git diff HEAD -- <путь>`. "
         "Чужое не коммить под своим сообщением: оставь соседу и напиши на доске СЕССИИ.md "
         "или спроси оператора. Своё или проверено: повтори ту же команду с префиксом "
         + ACK_MARK + ".")


def check_push(top, args, sid, transcript):
    remote, refspecs = None, []
    every = any(t in ("--all", "--mirror", "--branches") for t in args)
    for t in args:
        if t.startswith("-"):
            continue
        if remote is None:
            remote = t
        else:
            refspecs.append(t)
    branch = (git(top, "symbolic-ref", "--short", "-q", "HEAD") or "").strip()
    srcs = [branch] if branch else []
    if refspecs:
        srcs = []
        for r in refspecs:
            s = r.lstrip("+").split(":")[0]
            srcs.append(branch if s in ("", "HEAD") else s)
    if every:
        srcs = ["--branches"]  # `--all`/`--mirror` уносят все ветки, а не только текущую
    srcs = [s for s in srcs if s]
    if not srcs:
        return
    if remote is None:
        cfg = git(top, "config", "branch." + (branch or "main") + ".remote") or "origin"
        remote = cfg.strip() or "origin"
    out = git(top, "rev-list", *srcs, "--not", "--remotes=" + remote)
    if out is None:
        return
    outgoing = [h for h in out.split() if h]
    if not outgoing:
        return
    mine = my_commits(sid, top)
    foreign = [h for h in outgoing if h not in mine]
    if not foreign or phrase_ok(transcript):
        return
    lines = []
    for h in foreign[:SHOW]:
        lines.append("  " + (git(top, "log", "-1", "--format=%h %ad %s", "--date=format:%d.%m %H:%M", h)
                             or h[:7]).strip())
    more = "" if len(foreign) <= SHOW else "\n  … ещё " + str(len(foreign) - SHOW)
    deny("🟠 ЗАМОК ОБЩЕЙ ПАПКИ (ADR-0041): в отправку уходят коммиты, которые сделала не эта "
         "сессия (" + str(len(foreign)) + " из " + str(len(outgoing)) + "):\n" + "\n".join(lines)
         + more + "\n`git push` отправляет ветку целиком, и чужие коммиты ушли бы вместе с твоими "
         "(случай 09.11.2026).\nЧто делать: 1) давно не было `git fetch`? сделай его отдельной "
         "командой: часть «чужих» могла уже уйти на сервер; 2) чужие остались: напиши оператору, "
         "чьи они и что уйдёт вместе с твоими. Отправка пройдёт, когда оператор напишет «"
         + PUSH_PHRASE + "». Историю ради чистой отправки не переписывай.")


# ── вход ──────────────────────────────────────────────────────────────────────

def main():
    try:
        d = json.load(sys.stdin)
    except Exception:
        return
    if d.get("tool_name") not in (None, "Bash"):
        return
    cmd = (d.get("tool_input") or {}).get("command") or ""
    if "git" not in cmd:
        return
    cmd = nfc(cmd)
    sid = d.get("session_id") or ""
    transcript = d.get("transcript_path") or ""
    cwd = d.get("cwd") or os.getcwd()
    event = d.get("hook_event_name") or "PreToolUse"
    inv, vars_ = invocations(cmd, cwd)
    if not inv:
        return

    if event == "PostToolUse":
        pend = load_pending(sid)
        entry = pend.pop(cmd_key(cmd), None)
        if entry is None:
            return
        rows = []
        for top, before in entry:
            head = (git(top, "rev-parse", "HEAD") or "").strip()
            if not head or head == before:
                continue
            rng = git(top, "rev-list", before + ".." + head) if before else git(top, "rev-list", "-1", head)
            for h in (rng or "").split():
                rows.append(top + "\t" + h)
        if rows:
            with open(commits_file(sid), "a", encoding="utf-8") as f:
                f.write("\n".join(rows) + "\n")
        save_pending(sid, pend)
        return

    adds_by_top, record = {}, []
    for kind, pos, base, args in inv:
        top = toplevel(base) if base else None
        if kind == "add":
            if top:
                adds_by_top.setdefault(top, []).extend(
                    os.path.join(base, p) if not os.path.isabs(p) else p for p in parse_add(args))
            continue
        if kind == "push":
            if not top:
                deny("🟠 ЗАМОК ОБЩЕЙ ПАПКИ (ADR-0041): не могу определить, из какого репозитория "
                     "идёт `git push` (каталог: " + str(base) + "). Без этого не проверить, чьи "
                     "коммиты уходят. Повтори с явным путём: `git -C <абсолютный путь> push`.")
            check_push(top, args, sid, transcript)
            continue
        if kind == "commit" and top:
            check_commit(top, base, args, cmd, vars_, adds_by_top.get(top, []), sid, transcript)
            record.append([top, (git(top, "rev-parse", "-q", "--verify", "HEAD") or "").strip()])
    if record:
        pend = load_pending(sid)
        pend[cmd_key(cmd)] = record
        save_pending(sid, pend)


if __name__ == "__main__":
    main()
