# OpenMinis Code Analysis Guidelines

This file defines how to analyze, comment on, and modify code in this repository. Follow these rules unless the user gives more specific instructions in the current conversation.

## Project Defaults

- The forked app is named **MinisX**; use this name for user-facing app labels and discussion.
- The minimum supported system is **iOS 26.0**, including app extensions and simulator builds. The SDK or simulator runtime may be newer; using iOS 27 for validation does not raise the minimum supported version.

## Task Execution

- Within the confirmed goal and authorization, independently complete necessary reading, implementation, fixes and validation. Resolve reversible local implementation choices without asking again.
- Ask when missing information would materially change the goal, scope or acceptance criteria, or when new authorization is required. If one step is blocked, continue useful work that does not depend on it.
- Implementing an already approved plan does not require repeated rule approval. New or materially changed rules affecting future tasks still require the review described under Development Harness. Existing tool and environment permission boundaries continue to apply.

## Reader Background

The detailed teaching guidance in Reader Background, Explanation Style and Swift Topics That Need Explanation applies when the user requests code explanation, analysis or learning. For implementation, review and progress reports, explain only what is needed to assess the work; do not teach every language feature encountered.

- Assume the reader knows basic C++ syntax but is not familiar with Modern C++, Swift, SwiftUI, or iOS development.
- Use clear and direct language. Explain what the code actually does before introducing technical terms.
- Explain a technical term in one sentence when it first appears. Do not assume the reader already knows it.
- Do not use advanced Modern C++ concepts to explain Swift unless the C++ concept is also explained.
- Compare Swift with C++ only when the comparison makes the code easier to understand. Prefer basic concepts such as classes, objects, pointers, value copies, and callbacks.
- Do not use analogies in place of technical explanations. When a Swift or iOS concept has no direct C++ equivalent, state the difference clearly.

## Explanation Style

For complex code, prefer the following order:

1. Explain what the code is responsible for.
2. Explain what happens immediately before and after it in the current execution flow.
3. Explain the Swift, Objective-C, or iOS syntax needed to understand it.
4. Explain object lifetime, threads, asynchronous tasks, state updates, and possible side effects.
5. Explain why OpenMinis uses this implementation and what must remain true when the code changes.

Keep these categories separate:

- Language syntax: rules from Swift or Objective-C itself.
- Platform behavior: rules from SwiftUI, UIKit, the iOS sandbox, permissions, background execution, and related frameworks.
- Project logic: rules defined by OpenMinis for agents, sessions, tools, providers, and synchronization.

Answer simple questions directly. Do not force every answer into the full structure above.

## Swift Topics That Need Explanation

When explaining code at the user's request, explain the actual effect of relevant features in that code instead of only naming them:

- Value semantics and reference semantics for `struct` and `class`.
- Optionals, `if let`, `guard let`, and `nil`.
- Protocols, extensions, generics, and type constraints.
- Closure parameters, return values, captures, and `@escaping`.
- ARC, strong references, `weak`, `unowned`, and `deinit`.
- `async`, `await`, `Task`, actors, and `@MainActor`.
- Property wrappers such as `@State`, `@Binding`, `@Published`, and `@Environment`.
- SwiftUI `body`, state-driven updates, and View lifecycle.
- Bridging between Swift, Objective-C, and C interfaces.

## Analysis Scope

- The primary analysis target is `src/ios`.
- Focus first on `Agent`, `Providers`, `NativeOffloads`, `iSH`, `Views`, `Shared`, and the app extensions.
- When the iOS sandbox or native dependencies matter, also inspect `deps/ish`, build scripts under `deps`, `src/shared`, and `docs/specs`.
- Do not mix Android implementation details into an iOS explanation unless the execution path genuinely crosses platforms or a comparison is explicitly useful.
- Do not target `Vendor`, resource files, or generated files for comments unless the user explicitly asks for them.

## Using CodeGraph

- Prefer CodeGraph for structural questions such as symbol definitions, callers, callees, execution paths, and change impact when it is available and its index applies to the current code. If unavailable or insufficient, continue with direct source reading and searches.
- Include `src/ios`, a full file name, or an unambiguous Swift symbol in queries so that similarly named Android code is not returned first.
- Use `rg` for literal searches such as strings, log messages, and existing comment text.
- Avoid repeating verified CodeGraph results without a reason. Source changes, stale indexes or conflicting evidence justify direct verification.
- Read files named in synchronization warnings directly; read other related files when the task requires them.

## Source Comments

- Write source comments in Chinese by default, using direct and concise wording.
- Comments should explain reasons, constraints, invariants, side effects, thread requirements, permission boundaries, data contracts, edge cases, or compatibility workarounds.
- Do not add comments that only repeat variable names, function names, or simple control flow.
- Do not refactor code merely to make it easier to comment on, and do not change runtime behavior as part of a comment-only task.
- Understand the full function and its call relationships before adding a comment, and make sure the comment matches the implementation.
- When an existing comment is stale, update or remove it instead of adding another explanation beside it.
- Keep long teaching explanations in the analysis. Source comments should contain only information needed to maintain the code.

## Git Workflow

- Perform personal analysis and comment work on the `ios-annotated` branch.
- For other development, use the branch established for the task. If none is established, continue on the appropriate current development branch; do not put personal changes on `main`.
- Keep `main` aligned with the official `upstream/main`. Do not add personal changes to `main`.
- `origin` points to the personal fork, and `upstream` points to the official read-only mirror.
- Confirm the current branch and uncommitted changes before modifying files or switching branches. Do not automatically move or discard existing changes to satisfy a branch convention.
- Do not create commits or push to a remote unless the user explicitly asks.
- When the user asks for commits, split them into small commits by analysis area instead of combining many unrelated comments.
- To synchronize upstream changes, fetch `upstream` and then rebase `ios-annotated` onto the updated `upstream/main`.
- When resolving conflicts, verify that affected comments are still correct for the new implementation. Do not preserve text without checking the changed code.

## Changes and Validation

- Modify only the files and areas requested by the user.
- Run at least `git diff --check` after changing comments or documentation.
- A full build is usually unnecessary for comment-only changes. Run an appropriate check if a comment can affect syntax, generated documentation, or compilation.
- When runtime behavior changes, run tests or builds appropriate to the affected area and clearly report any validation that could not be performed.
- Choose checks sufficient for the goal and relevant risks. Once they pass, do not repeat or broaden testing unless new changes, failures or unresolved concerns justify it. Record unavailable checks explicitly; unrelated tests do not substitute for them.
- At the end of the task, explain what changed, what was validated, and whether any questions still require the user's judgment.

## Project Skills

Use the shared skills below when the task fits; read the linked SKILL.md before applying it. If automatic discovery is unavailable, load it directly. For new development, use plan-task to settle material goals, choices and acceptance before implementation. Reuse explicit prior approval; ordinary code questions do not start a planning workflow.

| Skill | Use when |
| --- | --- |
| [plan-task](.agents/skills/plan-task/SKILL.md) | Clarifying a development goal, researching relevant constraints, comparing viable approaches and confirming the implementation and acceptance plan |
| [resume-task](.agents/skills/resume-task/SKILL.md) | Resuming an existing task and verifying its records against current Git and code state |
| [review-task](.agents/skills/review-task/SKILL.md) | Preparing, performing or resolving a review against fixed code and confirmed requirements |

The user-facing guide is [项目技能使用说明](docs/harness/skills-guide.md). These skills use the Development Harness below for records, checkpoints and acceptance.

## Development Harness

- Keep the compact Spec index below in project context; load Spec bodies only as needed, normally by complete section. Record mandatory sections and optional references in the task and pass them to delegates and reviewers. Retain scope, definitions, exceptions and dependent sections; use full text for short documents or when context is uncertain. See `docs/harness/spec-context.md` for section selection and version binding.
- For complex or cross-session development, maintain a task record under `docs/tasks/active/` using `docs/harness/record-formats.md`. Name task titles and record files/directories `YY-mm-dd Name` using the creation date; retain the name when archiving. Small self-contained edits do not require a task record.
- When resuming, locate the relevant task, read its intent, decisions, next action and pending approvals, then verify the actual branch, HEAD and working-tree state. Resolve stale records before continuing; do not overwrite work to match a record.
- Keep task checkpoints current after meaningful progress, changed decisions, blockers and handoffs. Track implementation and verified acceptance separately.
- The main agent owns intent, integration and acceptance, and handles small edits or work requiring continuous shared context. Use subagents for bounded work that can progress and be verified independently when the expected benefit exceeds handoff cost. Supply scope, constraints, acceptance criteria and write boundaries; avoid overlapping concurrent edits. Delegation is not mandatory for every task.
- For behavior changes, bug fixes and cross-module refactors, the main agent checks the implementation and available tests before requesting independent Pi review. Bind each review to fixed code, Git state and requirements. Preserve the original report and record the disposition of findings separately.
- A failed, incomplete or stale review is not a passing review. Record unavailable validation and pending review explicitly; do not mark the task complete while required acceptance remains unmet.
- Pi conclusions are review input, not acceptance decisions. The main agent verifies findings against confirmed intent, code and relevant validation, records evidence for accepting or rejecting them, and determines whether acceptance criteria are met. Neither a blocking label nor no findings decides acceptance automatically; unresolved material concerns remain open, and goal or scope tradeoffs go to the user.
- Automatically correct current task records after significant misalignment. Before changing rules, specifications or skills that affect future tasks, present the concrete change, reason, scope and validation plan for user approval. Pending proposals are not active instructions.
- Shared skills and records must remain usable by Codex and Pi. Keep tool-specific execution and project-specific settings outside portable instructions where practical.

## Spec Index

| Document | Read when working on |
| --- | --- |
| `docs/specs/debug-server-api.md` | Debug server connection/protocol, provider management, chat automation or browser/log debugging |
| `docs/specs/ios-sandbox-ish-summary.md` | iSH integration, mounts, native offloads or Agent command execution |
| `docs/specs/minis-url-scheme.md` | `minis://` URLs, session path resolution, tool result references or chat attachment rendering |

These upstream documents mix descriptions, contracts and proposed enhancements. Check the selected section's status against current code; do not treat a planned feature or implementation description as an unconditional requirement. Update this index when adding or changing the scope of a Spec.
