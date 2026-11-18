#!/usr/bin/env python3
"""Установить проверенные хуки sysadmin только в указанный проект infra."""
import argparse
import json
import os
from pathlib import Path
import shlex
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = 'r="$(git rev-parse --show-toplevel 2>/dev/null)"; '


def render():
    config = json.loads((ROOT / ".codex" / "hooks.json").read_text(encoding="utf-8"))
    for groups in config["hooks"].values():
        for group in groups:
            for handler in group["hooks"]:
                command = handler["command"]
                if handler["type"] != "command" or not command.startswith(REPO_ROOT):
                    raise ValueError("Неизвестный формат запуска хука в .codex/hooks.json")
                handler["command"] = f"r={shlex.quote(str(ROOT))}; " + command[len(REPO_ROOT):]
    return json.dumps(config, indent=2, ensure_ascii=False) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("infra", type=Path)
    parser.add_argument("--check", action="store_true", help="Только сверить установленный файл")
    args = parser.parse_args()
    try:
        infra = args.infra.resolve(strict=True)
        if infra == ROOT or not (infra / ".git").exists():
            raise ValueError("Укажи отдельный Git-проект infra")
        config_dir = infra / ".codex"
        target = config_dir / "hooks.json"
        if config_dir.is_symlink() or target.is_symlink():
            raise ValueError(f"Ожидается обычный путь в проекте, получена ссылка: {target}")
        content = render()
        if target.exists() or args.check:
            if target.read_text(encoding="utf-8") != content:
                raise ValueError(f"Содержимое отличается от шаблона. Существующий файл сохранён: {target}")
            print(f"Защиты совпадают с шаблоном: {target}")
        else:
            config_dir.mkdir(exist_ok=True)
            # Сначала записать весь JSON, затем опубликовать его без перезаписи.
            with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=config_dir) as stream:
                stream.write(content)
                stream.flush()
                os.link(stream.name, target)
            print(f"Подключены защиты: {target}")
    except (OSError, ValueError, KeyError) as exc:
        print(exc, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
