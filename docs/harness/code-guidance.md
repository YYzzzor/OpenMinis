# Code explanation and source guidance

Read only the sections relevant to code explanation, comments, structural investigation, or UI preview work. These are existing project preferences moved out of the always-loaded AGENTS.md.

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

## UI Preview Collaboration

- For UI adjustments, prefer Xcode Canvas previews of the production component with centrally located, clearly commented parameters the maintainer can edit to compare results. Preserve the maintainer's edits and apply confirmed values to the shared production implementation. Follow [ios-ui-design: Canvas collaboration](../../.agents/skills/ios-ui-design/SKILL.md#优先用-canvas-协作调整-ui) for the workflow and validation boundaries; use simulator or device checks for behavior previews cannot adequately verify. This is a preference, not a mandatory preview stage for every UI task.

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
