"""A retired git checkout is deleted only behind a check that its work survives
elsewhere (fleet-ops#10540). The play deletes a retired path blindly, so the
guard is what keeps an unpushed commit, a stash or an edit from going with it.
"""
import ansible_host

GUARD = "Refuse to delete a retired git checkout that holds work nothing else has"
DELETE = "Remove retired host files"
TOOLING = "{{ nish_home }}/workspaces/tooling/"


def test_no_working_tree_under_tooling_is_retired_without_the_guard():
    play = ansible_host.play()
    guarded = set(play["vars"]["retired_git_checkouts"])
    assert guarded, "retired_git_checkouts is empty, so the guard refuses nothing"
    unguarded = [
        path
        for path in play["vars"]["retired"]
        if path.startswith(TOOLING) and "/.git" not in path and path not in guarded
    ]
    assert not unguarded, f"retired without the checkout guard: {unguarded}"


def test_every_guarded_checkout_is_also_retired():
    play = ansible_host.play()
    never_deleted = set(play["vars"]["retired_git_checkouts"]) - set(play["vars"]["retired"])
    assert not never_deleted, f"guarded but never deleted: {sorted(never_deleted)}"


def test_the_guard_runs_before_the_delete():
    names = [task.get("name") for task in ansible_host.play()["tasks"]]
    assert GUARD in names, f"{GUARD!r} is gone; the delete is blind again"
    assert names.index(GUARD) < names.index(DELETE)
