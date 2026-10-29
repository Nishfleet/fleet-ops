"""A retired git checkout is deleted only behind a check that its work survives
elsewhere (fleet-ops#10540). The play deletes a retired path blindly, so the
guard is what keeps an unpushed commit, a stash or an edit from going with it.
The checks read the play itself, because the unit job installs no Jinja and no
ansible; the runs that prove the refusal are quoted in the pull request.
"""
import ansible_host

HOLDS = "Note which retired git checkouts hold work that exists nowhere else"
GUARD = "Refuse to delete a retired git checkout that holds work nothing else has"
NOTE = "Note which retired git checkouts are still on the box"
DELETE = "Remove retired host files"
TOOLING = "/workspaces/tooling/"


def play() -> dict:
    return ansible_host.play()


def tasks() -> list:
    return play()["tasks"]


def names() -> list:
    return [task.get("name") for task in tasks()]


def guard_reads() -> list:
    ordered = names()
    if NOTE not in ordered or HOLDS not in ordered:
        return []
    return [
        task["register"]
        for task in tasks()[ordered.index(NOTE) + 1 : ordered.index(HOLDS)]
        if "register" in task
    ]


def decision() -> str:
    note = next(task for task in tasks() if task.get("name") == HOLDS)
    return next(iter(note["ansible.builtin.set_fact"].values()))


def test_no_working_tree_under_tooling_is_retired_without_the_guard():
    guarded = set(play()["vars"]["retired_git_checkouts"])
    assert guarded, "retired_git_checkouts is empty, so the guard refuses nothing"
    unguarded = [
        path
        for path in play()["vars"]["retired"]
        if TOOLING in path and "/" not in path.split(TOOLING, 1)[1].strip("/") and path not in guarded
    ]
    assert not unguarded, f"retired without the checkout guard: {unguarded}"


def test_every_guarded_checkout_is_also_retired():
    never_deleted = set(play()["vars"]["retired_git_checkouts"]) - set(play()["vars"]["retired"])
    assert not never_deleted, f"guarded but never deleted: {sorted(never_deleted)}"


def test_the_guard_runs_before_the_delete():
    assert GUARD in names(), f"{GUARD!r} is gone; the delete is blind again"
    assert names().index(GUARD) < names().index(DELETE)


def test_every_read_the_guard_makes_reaches_the_decision():
    reads = guard_reads()
    assert reads, "the guard reads nothing, so it cannot tell a dirty checkout from a clean one"
    unused = [read for read in reads if read not in decision()]
    assert not unused, f"read but not used, so a delete ignores it: {unused}"


def test_a_read_that_reports_work_is_counted():
    assert "selectattr('stdout')" in decision(), (
        "a read finding output no longer counts, so a dirty checkout is deleted"
    )


def test_a_read_that_cannot_run_is_counted():
    assert "rejectattr('rc', 'equalto', 0)" in decision(), (
        "a read that exits non-zero no longer counts, so a path git cannot read is deleted"
    )


def test_no_read_stops_the_play_before_the_guard():
    reads = set(guard_reads())
    raw_failures = [
        task.get("name")
        for task in tasks()
        if task.get("register") in reads and task.get("failed_when") is not False
    ]
    assert not raw_failures, f"a failed read ends the play with a raw git error: {raw_failures}"


def test_the_refusal_names_the_paths():
    guard = next(task for task in tasks() if task.get("name") == GUARD)
    assert "retired_checkouts_holding_work" in guard["ansible.builtin.assert"]["fail_msg"]
