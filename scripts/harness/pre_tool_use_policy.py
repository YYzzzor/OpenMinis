"""Small PreToolUse policy for model delegation and patch file roles."""
import json
import re
import sys
from pathlib import Path, PurePosixPath


PATCH_FILE = re.compile(r"^\*\*\*\s+(?:(?:Update|Add|Delete) File:|Move to:)\s*(.+?)\s*$", re.MULTILINE)
MAIN_DOCS = {
    "AGENTS.md",
    "docs/harness/design.md",
    "docs/harness/operations.md",
    "docs/harness/skills-guide.md",
    "docs/harness/record-formats.md",
    "docs/harness/spec-context.md",
    "docs/harness/validation.md",
    ".agents/skills/plan-task/SKILL.md",
    ".agents/skills/resume-task/SKILL.md",
    ".agents/skills/review-task/SKILL.md",
    "docs/harness/collaboration.md",
    "docs/harness/code-guidance.md",
    ".agents/skills/archive-task/SKILL.md",
}


def _document_path(path):
    if path in MAIN_DOCS:
        return True
    parts = PurePosixPath(path).parts
    if len(parts) == 3 and parts[0] == "docs" and parts[1] == "specs" and path.endswith(".md"):
        return True
    if parts[:2] in (("tasks", "active"), ("tasks", "archive")) and path.endswith((".md", ".json")):
        if "reviews" in parts:
            return PurePosixPath(path).name in {
                "request.md", "scope.md", "resolution.md", "manifest.json", "status.json",
                "dispatch-blocked.md",
            }
        return True
    return False


def _repo_relative(raw_path, cwd):
    candidate = Path(raw_path.strip())
    root = Path(cwd).resolve()
    if not candidate.is_absolute():
        candidate = root / candidate
    try:
        return candidate.resolve().relative_to(root).as_posix()
    except (OSError, ValueError):
        return None


def _patch_paths(tool_input, cwd):
    patch = tool_input.get("command", "")
    if not isinstance(patch, str):
        return []
    raw_paths = PATCH_FILE.findall(patch)
    return [_repo_relative(path, cwd) for path in raw_paths]


def reason_for(event):
    """Return a denial reason, or None when this event may continue."""
    tool = event.get("tool_name")
    args = event.get("tool_input") or {}

    if tool in {"spawn_agent", "Agent", "collaboration.spawn_agent"}:
        name = args.get("task_name", "")
        model = args.get("model")
        effort = args.get("reasoning_effort")
        if isinstance(name, str) and name.startswith("review_"):
            if (model, effort, args.get("fork_turns")) != ("gpt-6.1-sol", "high", "none"):
                return (
                    "Independent reviews require task_name starting with 'review_', model "
                    "'gpt-6.1-sol', reasoning_effort 'high', and fork_turns 'none'. "
                    "Correct the parameters and retry automatically; do not ask the user or "
                    "stop for this recoverable parameter error."
                )
        else:
            turns = args.get("fork_turns")
            valid_turns = turns == "none" or (
                isinstance(turns, str) and re.fullmatch(r"[1-9][0-9]*", turns) is not None
            )
            if (model, effort) != ("gpt-6-luna", "xhigh") or not valid_turns:
                return (
                    "Code delegation requires model 'gpt-6-luna', reasoning_effort 'xhigh', "
                    "and fork_turns 'none' or a positive integer string. Correct all three "
                    "parameters and retry automatically; do not ask the user or stop for this "
                    "recoverable parameter error."
                )
        return None

    if tool in {"apply_patch", "Edit", "Write"}:
        model = event.get("model")
        paths = _patch_paths(args, event.get("cwd", "."))
        if not paths or any(path is None for path in paths):
            return (
                "The patch target could not be identified as a repository-relative file. "
                "Use explicit Update/Add/Delete File paths and retry automatically."
            )
        if model == "gpt-6-luna":
            return None
        if model == "gpt-6-astra" and all(_document_path(path) for path in paths):
            return None
        return (
            "Only gpt-6-luna may patch code or configuration. The main gpt-6-astra session "
            "may patch approved planning, rule, task, and review documents. Correct the "
            "assignment or target paths and retry automatically; do not ask the user or stop."
        )

    return None


def main():
    try:
        event = json.load(sys.stdin)
    except (json.JSONDecodeError, UnicodeDecodeError):
        reason = "Could not read the PreToolUse event; correct the tool request and retry automatically."
    else:
        reason = reason_for(event)

    if reason:
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason,
            }
        }, ensure_ascii=False))


if __name__ == "__main__":
    main()
