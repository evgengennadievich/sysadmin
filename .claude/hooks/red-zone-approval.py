"""Проверить и однократно погасить согласие C.3 перед запуском Bash."""
import hashlib
import json
import os
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from approval_format import PUSH_PHRASE, red_approval
from codex_transcript import is_operator, is_subagent_meta


def claude_message(record):
    if (record.get("type") != "user" or record.get("isMeta")
            or record.get("sourceToolUseID") or record.get("isSidechain")):
        return None
    message = record.get("message", {})
    if message.get("role") != "user":
        return None
    content = message.get("content")
    if isinstance(content, list):
        if any(block.get("type") == "tool_result" for block in content):
            return None
        # Вложения и составные сообщения отменяют предыдущее согласие.
        content = content[0].get("text") if len(content) == 1 and content[0].get("type") == "text" else ""
    if isinstance(content, str) and content.lstrip().startswith((
            "<command-name>", "<local-command-", "<command-message>",
            "<system-reminder>", "Base directory for this skill")):
        return None
    return content or "", record.get("uuid"), record.get("sessionId")


def approved(event, path):
    session = event.get("session_id")
    if not session or event.get("agent_id") or event.get("agent_type"):
        return False
    args = event["tool_input"]
    cmd = args["command"]
    cwd = args.get("workdir") or args.get("cwd") or event["cwd"]
    if (not os.path.isabs(cwd) or not cmd or len(cmd.splitlines()) != 1
            or any(c in cmd + cwd for c in "\r\n\0")):
        return False
    expected = red_approval(cmd, cwd)
    last = None
    with open(path, encoding="utf-8") as stream:
        codex = None
        for line in stream:
            record = json.loads(line)
            if codex is None:
                codex = record.get("type") == "session_meta"
            if record.get("type") == "session_meta":
                meta = record["payload"]
                if not codex or meta.get("id") != session or is_subagent_meta(meta):
                    return False
            elif codex and is_operator(record):
                payload = record["payload"]
                content = payload.get("message") or ""
                # VS Code иногда добавляет видимый пробел в начало. Текст самой
                # команды сравниваем буквально, включая экранирование и регистр.
                if content.startswith("&#x20;"):
                    content = content[6:]
                if any(payload.get(k) for k in ("images", "local_images", "audio", "local_audio")):
                    content = ""
                last = content, record.get("timestamp"), session
            elif not codex:
                if record.get("isSidechain") or record.get("agentId"):
                    return False
                message = claude_message(record)
                if message is not None:
                    last = message
    if not last or not last[1] or last[2] != session:
        return False
    if last[0] not in (expected, expected + "\n" + PUSH_PHRASE):
        return False
    # Один файл на сообщение, даже при одновременных вызовах или перезапуске.
    key = hashlib.sha256(json.dumps([session, last[1]]).encode()).hexdigest()
    folder = Path.home() / ".claude" / "state" / "red-zone-approvals"
    folder.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (folder / key).open("xb"):
        pass
    return True


if __name__ == "__main__":
    try:
        ok = approved(json.load(sys.stdin), sys.argv[1])
    except (OSError, ValueError, TypeError, AttributeError, KeyError):
        ok = False
    sys.exit(0 if ok else 1)
