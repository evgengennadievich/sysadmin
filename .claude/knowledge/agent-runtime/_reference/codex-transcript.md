---
knowledge_domain: agent-runtime
layer: reference
last_researched: 2026-11-18
ttl_days: 60
sources_checked:
  - "живые записи Codex CLI 0.169 (13 сессий, ~/.codex/sessions/2026/11/, проверено чтением .jsonl 2026-11-18)"
  - "developers.openai.com/codex/hooks.md — входные поля хуков, matcher, формат отказа"
  - ".claude/hooks/codex_transcript.py — реализация фильтра, .claude/hooks/tests/test-codex-hooks.sh"
---

# Запись сессии Codex: как отличить голос человека

Пара к `claude-code-transcript.md`: то же знание для Codex. Нужно всему, что принимает
решения по репликам человека: замкам, гейтам, разбору `$retro`. Ошибка здесь — дыра в
безопасности (конституция C.11), а не косметика.

## Где лежит

`$CODEX_HOME/sessions/ГГГГ/ММ/ДД/rollout-<время>-<id сессии>.jsonl` (`CODEX_HOME` по
умолчанию `~/.codex`). Хук получает путь в поле `transcript_path`, но документация Codex
прямо говорит: формат записи **не стабильный интерфейс** и может меняться. Поэтому разбор
собран в одном модуле (`.claude/hooks/codex_transcript.py`) и закрыт тестом на настоящей
записи.

Первая строка — `{"type":"session_meta","payload":{…}}`: `cwd`, `source`, `id`. По ней
запись Codex отличается от записи Claude Code (у той такой строки нет).

## Что выглядит репликой человека, но ею не является

| Запись | Что это | Голос человека? |
|---|---|---|
| `event_msg`, `payload.type = "user_message"` | то, что человек напечатал в интерфейсе | **да** |
| `response_item`, `payload.role = "user"`, текст начинается с `# AGENTS.md instructions` | текст AGENTS.md (в нём есть образец фразы красной зоны!) | нет |
| `response_item`, `role = "user"`, `<external_ide_context>` | открытые вкладки IDE | нет |
| `response_item`, `role = "developer"` | системные вставки движка | нет |
| `custom_tool_call_output`, `function_call_output` | вывод инструментов | нет |
| любая запись, если `session_meta.payload.source` содержит `subagent` | сессия субагента | нет: у субагента оператора нет |

**Главная ловушка.** Если искать фразу во всех записях с `role: "user"`, как привыкли по
Claude Code, замок красной зоны откроется **сам**: AGENTS.md содержит образец фразы
подтверждения, и Codex кладёт его в запись строкой роли `user` в начале каждой сессии.
Проверено подменой фильтра (18.11.2026): тест ловит это тремя провалами.

## Особенности текста реплики

Интерфейс VS Code кладёт реплику с экранированием markdown (`\,` `\*`) и HTML-сущностями
(`&#x20;` в начале). Перед поиском фразы текст чистится (`clean_text`), иначе фраза
оператора не находилась бы.

## Как в записи выглядят действия агента

- Режим кода: `response_item` / `custom_tool_call` с `name: "exec"`, внутри JavaScript;
  команды оболочки лежат строками после `cmd:` (`tools.exec_command({cmd:"…"})`), правки
  файлов — `apply_patch <<'PATCH' … PATCH` внутри команды.
- Классические вызовы: `function_call` (`arguments` — JSON) и `local_shell_call`.
- Применённая правка: `event_msg` / `patch_apply_end`, поле `changes` — словарь путей.
- Итог расхода: последний `event_msg` / `token_count`, поле `info.total_token_usage`.

## Входы хуков Codex (для замков)

Bash-команда: `tool_name: "Bash"`, текст в `tool_input.command` (так же, как у Claude Code).
Правка файла: `tool_name: "apply_patch"`, весь патч в `tool_input.command`
(`*** Update File: путь`, строки `+…`); полей `file_path` / `new_string` нет. Отказ —
тот же JSON `hookSpecificOutput.permissionDecision: "deny"`. Stop понимает
`{"decision":"block","reason":…}` и `stop_hook_active`. Переменной `CLAUDE_PROJECT_DIR` нет:
путь к хуку берётся от `git rev-parse --show-toplevel`.

**Граница.** Документация Codex: «некоторые специализированные пути инструментов могут
обходить хуки, считайте хуки полезным ограждением, а не полной границей». Замок красной
зоны под Codex — страховка, процедура §6.3 обязательна и без него.
