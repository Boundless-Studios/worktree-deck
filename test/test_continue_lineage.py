from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_continue_records_attributed_transition_before_push() -> None:
    text = (ROOT / "lib/continue-worktree.sh").read_text(encoding="utf-8")
    transition = text.index('WTD_BRANCH_TRANSITION_SINK} "$WTD_SESSION_ID"')
    push = text.index('git -C "$worktree_path" push -u origin')
    assert transition < push
    assert "refusing to push" in text[transition:push]
