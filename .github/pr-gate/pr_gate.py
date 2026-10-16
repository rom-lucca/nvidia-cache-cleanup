"""PR pre-review gate.

Single-file, stdlib-only module so it can be vendored into any repository
(`.github/pr-gate/pr_gate.py`) and also run locally by Claude Code.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess  # noqa: S404 - only runs fixed git/gh commands
import sys
from collections.abc import Sequence
from pathlib import Path

COMMIT_TYPES = "feat|fix|refactor|test|docs|chore|perf|build|ci|style|revert"
BRANCH_TYPES = "feat|fix|hotfix|refactor|test|docs|chore|perf|ci|spike"
BOT_BRANCH_PREFIXES = ("dependabot/", "renovate/")
MAX_SUMMARY_LEN = 72

WORKFLOW_PATH = ".github/workflows/pr-gate.yml"
INSTRUCTIONS_PATH = ".github/copilot-instructions.md"
APPROVAL_FILE = "pr-gate-approved"
INSTALL_HINT = "python ~/.claude/pr-review-kit/src/install.py repo ."
BASE_CANDIDATES = ("origin/HEAD", "origin/main", "origin/master")
REVIEW_CONTEXT = "pr-reviewer"

_HEADER_RE = re.compile(rf"^(?:{COMMIT_TYPES})(?:\([a-z0-9._/-]+\))?!?: (?P<summary>.+)$")
_BRANCH_RE = re.compile(rf"^(?:{BRANCH_TYPES})/[A-Za-z0-9]+(?:[-.][A-Za-z0-9]+)*$")
_ARG = r"(?:\"[^\"]*\"|'[^']*'|\S+)"
# `git push` only at the start of a command or after a shell separator, so text such
# as `git commit -m "explain git push"` is not mistaken for a push.
_PUSH_RE = re.compile(
    rf"(?:^|[;&|(\n])\s*git(?:\s+-[Cc]\s+{_ARG})*\s+push\b(?P<args>[^;&|\n]*)", re.MULTILINE
)
_CD_RE = re.compile(rf"^\s*cd\s+(?P<path>{_ARG})\s*(?:&&|;)")
_DASH_C_RE = re.compile(rf"\bgit\s+-C\s+(?P<path>{_ARG})")
_REF_MAINTENANCE_FLAGS = frozenset({"--delete", "-d", "--tags"})


def check_title(title: str) -> list[str]:
    """Validate a Conventional Commits header (PR title or commit first line)."""
    match = _HEADER_RE.match(title)
    if not match:
        return [f"'{title}' is not '<type>(<scope>): <summary>' with type in {COMMIT_TYPES}"]
    summary = match.group("summary")
    errors = []
    if summary[0].isupper():
        errors.append(f"summary must start lowercase: '{summary}'")
    if summary.endswith("."):
        errors.append(f"summary must not end with a period: '{summary}'")
    if len(title) > MAX_SUMMARY_LEN:
        errors.append(f"header has {len(title)} chars (max {MAX_SUMMARY_LEN})")
    return errors


def check_branch(branch: str) -> list[str]:
    """Validate a Conventional Branch name; bot branches are exempt."""
    if branch.startswith(BOT_BRANCH_PREFIXES) or _BRANCH_RE.match(branch):
        return []
    return [f"branch '{branch}' is not '<type>/<kebab-case>' with type in {BRANCH_TYPES}"]


def check_commit(message: str) -> list[str]:
    """Validate a commit message by its first line; merge/revert commits are exempt."""
    header = message.splitlines()[0] if message else ""
    if header.startswith(("Merge ", 'Revert "')):
        return []
    return check_title(header)


def _run(*command: str, cwd: str | None = None) -> str:
    return subprocess.run(  # noqa: S603
        list(command),
        cwd=cwd,
        check=True,
        capture_output=True,
        text=True,
        encoding="utf-8",
    ).stdout


def _git(*args: str, cwd: str | None = None) -> str:
    return _run("git", *args, cwd=cwd)


def _gh(*args: str, cwd: str) -> bool:
    try:
        _run("gh", *args, cwd=cwd)
    except (subprocess.CalledProcessError, OSError):
        return False
    return True


def _commit_messages(base: str) -> list[str]:
    raw = _git("log", "--format=%B%x00", f"{base}..HEAD")
    return [m.strip() for m in raw.split("\x00") if m.strip()]


def _try_git(*args: str, cwd: str) -> str | None:
    try:
        return _git(*args, cwd=cwd).strip()
    except (subprocess.CalledProcessError, OSError):
        return None


def _unquote(value: str) -> str:
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def target_dir(command: str, cwd: str) -> str:
    """Directory a shell command's `git push` runs in (`cd X &&` and `git -C X`)."""
    directory = cwd
    if cd := _CD_RE.match(command):
        directory = os.path.join(cwd, _unquote(cd["path"]))
    if dash_c := _DASH_C_RE.search(command):
        directory = os.path.join(directory, _unquote(dash_c["path"]))
    return directory


def _push_dir_from_hook_input(stdin_text: str) -> str | None:
    """Repo directory of a reviewable `git push` in a hook payload, else None."""
    try:
        payload = json.loads(stdin_text)
        command = str(payload["tool_input"]["command"])
        cwd = str(payload.get("cwd") or os.getcwd())
    except (ValueError, KeyError, TypeError):
        return None
    push = _PUSH_RE.search(command)
    if push is None or _REF_MAINTENANCE_FLAGS & set(push["args"].split()):
        return None
    directory = target_dir(command, cwd)
    if not os.path.isdir(directory) or _try_git("rev-parse", "--git-dir", cwd=directory) is None:
        return None
    return directory


def _approval_path(directory: str) -> Path:
    return Path(directory, _git("rev-parse", "--git-path", APPROVAL_FILE, cwd=directory).strip())


def _approved_head(directory: str) -> str | None:
    """HEAD's SHA when the pr-reviewer agent approved exactly this commit."""
    head = _try_git("rev-parse", "HEAD", cwd=directory)
    approval = _approval_path(directory)
    approved = approval.read_text(encoding="utf-8").strip() if approval.exists() else ""
    return head if head and approved == head else None


def push_block_reason(directory: str) -> str | None:
    """Why pushing HEAD from `directory` must be blocked, or None to allow it."""
    base = next(
        (
            ref
            for ref in BASE_CANDIDATES
            if _try_git("rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}", cwd=directory)
        ),
        None,
    )
    if base is None:  # bootstrap: nothing on the remote to compare against yet
        return None
    if _try_git("rev-list", "--count", f"{base}..HEAD", cwd=directory) in (None, "0"):
        return None
    if _try_git("cat-file", "-e", f"HEAD:{WORKFLOW_PATH}", cwd=directory) is None:
        return (
            f"This repository has no PR gate ({WORKFLOW_PATH}). Install it on this branch "
            f"with `{INSTALL_HINT}`, commit it as 'ci(pr-gate): install pr pre-review gate', "
            "then run the pr-reviewer agent."
        )
    if _approved_head(directory) is None:
        head = _try_git("rev-parse", "HEAD", cwd=directory) or ""
        return (
            f"HEAD {head[:12]} has not been approved by the pr-reviewer agent. Run the "
            "pr-reviewer agent on this branch, fix every blocking finding (one commit per fix), "
            "and repeat until it approves; it records the approval itself."
        )
    return None


def cmd_hook(_args: argparse.Namespace) -> int:
    """Claude Code PreToolUse hook: exit 2 blocks an unreviewed `git push`."""
    directory = _push_dir_from_hook_input(sys.stdin.read())
    reason = push_block_reason(directory) if directory else None
    if reason is None:
        return 0
    print(f"pr-gate: push blocked. {reason}", file=sys.stderr)
    return 2


def cmd_post_push(_args: argparse.Namespace) -> int:
    """Claude Code PostToolUse hook: publish the approval as a commit status on GitHub."""
    directory = _push_dir_from_hook_input(sys.stdin.read())
    head = _approved_head(directory) if directory else None
    if directory is None or head is None:
        return 0
    published = _gh(
        "api",
        "-X",
        "POST",
        f"repos/{{owner}}/{{repo}}/statuses/{head}",
        "-f",
        "state=success",
        "-f",
        f"context={REVIEW_CONTEXT}",
        "-f",
        "description=Approved by the pr-reviewer agent before push",
        cwd=directory,
    )
    if not published:
        print(f"pr-gate: could not publish the {REVIEW_CONTEXT} status", file=sys.stderr)
    return 0


def cmd_approve(_args: argparse.Namespace) -> int:
    head = _git("rev-parse", "HEAD").strip()
    _approval_path(".").write_text(head + "\n", encoding="utf-8")
    print(f"pr-gate: approved {head}")
    return 0


def cmd_conventions(args: argparse.Namespace) -> int:
    branch = args.branch or _git("rev-parse", "--abbrev-ref", "HEAD").strip()
    errors = [f"branch: {e}" for e in check_branch(branch)]
    if args.title is not None:
        errors += [f"title: {e}" for e in check_title(args.title)]
    for message in _commit_messages(args.base):
        header = message.splitlines()[0]
        errors += [f"commit '{header}': {e}" for e in check_commit(message)]
    if errors:
        print("conventions: FAILED")
        for error in errors:
            print(f"  - {error}")
        return 1
    print("conventions: OK")
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="pr_gate", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    conv = sub.add_parser("conventions", help="check PR title, branch name and commits")
    conv.add_argument("--base", required=True, help="base ref, e.g. origin/main")
    conv.add_argument("--title", help="PR title (optional when running locally)")
    conv.add_argument("--branch", help="branch name (default: current branch)")
    conv.set_defaults(func=cmd_conventions)

    sub.add_parser("approve", help="record pr-reviewer approval of HEAD").set_defaults(
        func=cmd_approve
    )
    sub.add_parser("hook", help="PreToolUse hook: block unreviewed pushes").set_defaults(
        func=cmd_hook
    )
    sub.add_parser("post-push", help="PostToolUse hook: publish approval status").set_defaults(
        func=cmd_post_push
    )

    args = parser.parse_args(argv)
    result: int = args.func(args)
    return result


if __name__ == "__main__":
    sys.exit(main())
