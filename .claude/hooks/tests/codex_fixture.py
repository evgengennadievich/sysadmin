#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Сборщик фикстур записи Codex для test-codex-hooks.sh (ADR-0042).

Формат повторяет настоящую запись Codex CLI 0.169 (разбор 18.11.2026): первая строка
session_meta, реплика оператора — event_msg/user_message, вставки движка (AGENTS.md, контекст
IDE) — response_item с role "user", вызовы — custom_tool_call `exec` с JavaScript внутри.

Использование: codex_fixture.py <файл> <фраза> <вид записи>...
"""
import json
import sys


def meta(src="vscode"):
    return {"type": "session_meta", "payload": {"id": "s1", "cwd": "/tmp/p", "source": src}}


def op(t):
    return {"type": "event_msg", "payload": {"type": "user_message", "message": t}}


def inj(t):
    return {"type": "response_item", "payload": {"type": "message", "role": "user",
            "content": [{"type": "input_text", "text": t}]}}


def ag(t):
    return {"type": "response_item", "payload": {"type": "message", "role": "assistant",
            "content": [{"type": "output_text", "text": t}]}}


def ex(cmd):
    js = "text(await tools.exec_command({cmd:" + json.dumps(cmd, ensure_ascii=False) + "}))"
    return {"type": "response_item", "payload": {"type": "custom_tool_call", "name": "exec", "input": js}}


def res(t):
    return {"type": "response_item", "payload": {"type": "custom_tool_call_output", "output": t}}


def patch(path, success):
    return {"type": "event_msg", "payload": {"type": "patch_apply_end",
            "success": success, "changes": {path: {"type": "update"}}}}


def build(phrase, kinds):
    table = {
        "meta": lambda: meta(),
        "meta_sub": lambda: meta({"subagent": {"other": "guardian"}}),
        "op_ask": lambda: op("снеси старый том"),
        "op_ok": lambda: op(phrase),
        "op_ok_md": lambda: op("&#x20;" + phrase),
        "op_other": lambda: op("дальше по задаче"),
        "inj_agents": lambda: inj("# AGENTS.md instructions\n<INSTRUCTIONS>\n" + phrase + "\n</INSTRUCTIONS>"),
        "ag_phrase": lambda: ag(phrase),
        "res_phrase": lambda: res(phrase),
        "ex_restart": lambda: ex("ssh host 'docker compose up -d app'"),
        "ex_inventory": lambda: ex("bash infra/refresh.sh"),
        "ex_cat_inventory": lambda: ex("cat /x/infra/inventory/hosts/a/server.md"),
        "patch_inv": lambda: patch("/x/infra/inventory/hosts/a/server.md", True),
        "patch_inv_failed": lambda: patch("/x/infra/inventory/hosts/a/server.md", False),
        "patch_other": lambda: patch("/x/infra/notes.md", True),
    }
    return [table[k]() for k in kinds]


if __name__ == "__main__":
    out, phrase, kinds = sys.argv[1], sys.argv[2], sys.argv[3:]
    with open(out, "w", encoding="utf-8") as f:
        for i, r in enumerate(build(phrase, kinds)):
            r["timestamp"] = f"2026-11-18T10:00:{i:02d}Z"
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
