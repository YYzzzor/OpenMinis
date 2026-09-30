# MinisX project guidance

These are persistent project defaults. More specific user instructions take precedence; read linked guidance only when the task needs it.

## Project Defaults

- The app is **MinisX**, primarily under `src/ios`; minimum iOS version is **26.0** for the app and extensions. A newer test runtime does not raise the deployment target.
- `main` is the MinisX development baseline, not a mirror of upstream. Verify the actual branch and working tree and preserve unrelated changes.

## Task Execution

- Continue independently within the confirmed goal. For substantial new work or material scope changes, use `plan-task`; a specific direct edit request can already supply authorization. Do not ask again for approved work.
- Stay in this conversation. New visible conversations, worktrees, commits and pushes require the applicable explicit user authorization. See [execution boundaries](docs/harness/collaboration.md#task-execution) and [Git workflow](docs/harness/collaboration.md#git-workflow) when relevant.
- Keep implementation and verification proportional to the task: avoid unnecessary process, overengineering, speculative defensive code and repeated checks without a new reason. Report what was actually verified and what remains unknown.
- For very simple UI tweaks, prefer one small guided step at a time for the user to apply and observe; no coding delegate, task record or independent review is needed for guidance alone.

## Codex Model Delegation

- Main session: requirements, planning, coordination, evidence and final acceptance; it may maintain policy/task/review documents. All agent-authored code edits, including small fixes, comments, configuration and tests, go to **`gpt-6-luna` / `xhigh`**. If unavailable, report it; do not silently substitute or take over coding.
- When code review is needed, use a **fresh `gpt-6.1-sol` / `high`** session, `task_name=review_*`, `fork_turns=none`, read-only. Do not repeat a full review in the main session. **Pi is paused.**
- Explicitly set delegation parameters. Correct recoverable parameter mismatches and retry automatically without asking the user or ending the task. For code delegates, use `fork_turns=none` or a supported positive integer string.
- Before delegating, read [model responsibilities and handoff](docs/harness/collaboration.md#codex-model-delegation); before reviewing, use `review-task`. These defaults do not change the active main model.

## Reader Background

- The user knows basic C++ but is learning Swift/iOS. Explain relevant terms plainly when explanation is requested; avoid a tutorial during routine implementation updates.
- For code explanation, comments, CodeGraph use or Canvas collaboration, read the relevant section of [code guidance](docs/harness/code-guidance.md). Source comments default to concise Chinese explaining intent and constraints.

## Project Skills

Read the matching skill when needed; ordinary questions and trivial edits do not activate a full workflow. If automatic discovery is unavailable, open the linked SKILL.md directly.

| Skill | Use when |
| --- | --- |
| [plan-task](.agents/skills/plan-task/SKILL.md) | Clarifying substantial new work and acceptance; include a useful runtime diagram, preferably a sequence diagram for interactions |
| [ios-ui-design](.agents/skills/ios-ui-design/SKILL.md) | Native iOS design decisions or Canvas collaboration |
| [resume-task](.agents/skills/resume-task/SKILL.md) | Continuing a selected existing task against current code and records |
| [review-task](.agents/skills/review-task/SKILL.md) | Necessary independent code review and disposition |
| [archive-task](.agents/skills/archive-task/SKILL.md) | Closing a recorded task or checking whether a resumed task can be archived |

## Development Harness

- Discover current tasks in `tasks/active/`; do not scan `tasks/archive/` as background context. Read a specific archived record only for an explicit request or an identified evidence need.
- At task wrap-up, use `archive-task` to judge readiness and archive eligible project records autonomously. No background scan or archive Hook is installed.
- For task/checkpoint/review formats, use [record-formats.md](docs/harness/record-formats.md); for Harness maintenance, see [design](docs/harness/design.md) and [collaboration details](docs/harness/collaboration.md#development-harness).
- Validate documentation changes with `git diff --check`; choose meaningful tests for code changes without redundant full builds. Further boundaries are in [validation guidance](docs/harness/collaboration.md#changes-and-validation).

## Spec Context

- Find applicable documents through the generated [Spec index](docs/specs/index.md); descriptions are maintained in each source Spec, not here.
- For planning or resuming work, use the bounded route-and-body reader in [Spec context](docs/harness/spec-context.md). Select complete sections with their scope, prerequisites and exceptions; expansion labels describe only the current output.
- [Resource efficiency](docs/specs/resource-efficiency.md) applies throughout development and every review. Pure documentation may be marked not applicable; tool resource costs still matter.
- After implementation and validation, maintain affected Specs using [Spec authoring](docs/harness/spec-authoring.md), or record why no update is needed before task archival.

Distinguish confirmed requirements, implementation descriptions and future plans. An upstream Draft or example is not automatically a current requirement or proof of working behavior.
