"""Проверки отказа и гонки на входе обработчика однократного согласия."""
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HOOK = Path(__file__).resolve().parents[1] / "red-zone-approval.py"


class ApprovalTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.log = self.root / "session.jsonl"
        self.cmd = "docker volume rm test-only"
        self.phrase = f"подтверждаю {self.cmd}, беру риск на себя, бэкап проверен\nкаталог /workspace"
        self.event = dict(session_id="s", cwd="/workspace", tool_input=dict(command=self.cmd))
        self.meta = dict(type="session_meta", payload=dict(id="s", source="vscode"))
        self.record(self.meta, self.operator(self.phrase))

    def record(self, *records):
        self.log.write_text("".join(json.dumps(r) + "\n" for r in records))

    def operator(self, message):
        return dict(timestamp="t1", type="event_msg", payload=dict(type="user_message", message=message))

    def allowed(self):
        proc = subprocess.run([sys.executable, str(HOOK), str(self.log)],
                              env=dict(os.environ, HOME=str(self.root)),
                              input=json.dumps(self.event), text=True, check=False)
        return proc.returncode == 0

    def test_race(self):
        with ThreadPoolExecutor(max_workers=6) as pool:
            self.assertEqual(sum(pool.map(lambda _: self.allowed(), range(6))), 1)

    def test_combined_git_approval(self):
        cmd = "git push --force-with-lease origin main"
        self.event["tool_input"]["command"] = cmd
        phrase = self.phrase.replace(self.cmd, cmd) + "\nотправляй вместе с чужими"
        self.record(self.meta, self.operator(phrase))
        self.assertTrue(self.allowed())

    def test_withdrawal(self):
        self.record(self.meta, self.operator(self.phrase), self.operator("Отмена"))
        self.assertFalse(self.allowed())

    def test_quoted(self):
        self.record(self.meta, self.operator("Мне прислали пример:\n" + self.phrase))
        self.assertFalse(self.allowed())

    def test_other_workdir(self):
        self.event["tool_input"]["workdir"] = "/different"
        self.assertFalse(self.allowed())

    def test_other_session(self):
        self.event["session_id"] = "other"
        self.assertFalse(self.allowed())

    def test_agent_using_parent_log(self):
        self.event["agent_id"] = "child"
        self.assertFalse(self.allowed())

    def test_corrupt_tail(self):
        with self.log.open("a") as stream:
            stream.write("{")
        self.assertFalse(self.allowed())

    def test_state_unavailable(self):
        (self.root / ".claude").touch()
        self.assertFalse(self.allowed())

    def test_fresh_approval_after_attempt(self):
        self.assertTrue(self.allowed())
        second = self.operator(self.phrase)
        second["timestamp"] = "t2"
        self.record(self.meta, self.operator(self.phrase), second)
        self.assertTrue(self.allowed())

    def test_claude_withdrawal(self):
        records = [dict(type="user", uuid=str(i), sessionId="s",
                        message=dict(role="user", content=t))
                   for i, t in enumerate((self.phrase, "Отмена"))]
        self.record(*records)
        self.assertFalse(self.allowed())


if __name__ == "__main__":
    unittest.main()
