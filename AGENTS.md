# OpenMinis Code Analysis Guidelines

This file defines how to analyze, comment on, and modify code in this repository. Follow these rules unless the user gives more specific instructions in the current conversation.

## Reader Background

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

When the following features appear, explain their actual effect in the current code instead of only naming the feature:

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

- Prefer CodeGraph for structural questions such as symbol definitions, callers, callees, execution paths, and change impact.
- Include `src/ios`, a full file name, or an unambiguous Swift symbol in queries so that similarly named Android code is not returned first.
- Use `rg` for literal searches such as strings, log messages, and existing comment text.
- When CodeGraph has returned the current source and structural relationships, do not repeat the same verification with `rg`.
- If the index reports files that have not synchronized yet, read only the files named in that warning.

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
- Keep `main` aligned with the official `upstream/main`. Do not add personal changes to `main`.
- `origin` points to the personal fork, and `upstream` points to the official read-only mirror.
- Confirm the current branch before modifying files. If it is not `ios-annotated`, switch branches or explain the situation to the user first.
- Do not create commits or push to a remote unless the user explicitly asks.
- When the user asks for commits, split them into small commits by analysis area instead of combining many unrelated comments.
- To synchronize upstream changes, fetch `upstream` and then rebase `ios-annotated` onto the updated `upstream/main`.
- When resolving conflicts, verify that affected comments are still correct for the new implementation. Do not preserve text without checking the changed code.

## Changes and Validation

- Modify only the files and areas requested by the user.
- Run at least `git diff --check` after changing comments or documentation.
- A full build is usually unnecessary for comment-only changes. Run an appropriate check if a comment can affect syntax, generated documentation, or compilation.
- When runtime behavior changes, run tests or builds appropriate to the affected area and clearly report any validation that could not be performed.
- At the end of the task, explain what changed, what was validated, and whether any questions still require the user's judgment.
