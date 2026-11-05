from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent


def tasks(items):
    for t in items or []:
        if isinstance(t, dict):
            yield t
            for key in ("block", "always", "tasks", "handlers", "pre_tasks", "post_tasks"):
                yield from tasks(t.get(key))


def test_no_play_task_ignores_its_own_failure() -> None:
    bad = [
        f"{path.name}: {task.get('name')}"
        for path in [ROOT / "ansible/host.yml", *sorted((ROOT / "ansible/tasks").glob("*.yml"))]
        for task in tasks(yaml.safe_load(path.read_text()))
        if task.get("ignore_errors") is True
    ]
    assert not bad, bad
