---
name: boring-engineering
description: "Prevents overengineering, excessive defensive code, and unnecessary test bloat when implementing features, fixing bugs, writing tests, refactoring, or reviewing code. Use when the user asks to implement a feature, fix a bug, add validation or tests, refactor code, review a design, simplify existing code, or make an architectural decision. Do not use for deployment, infrastructure configuration, or debugging runtime errors unrelated to code structure."
license: MIT
compatibility: Works in any Agent Skills-compatible runtime (Claude Code, Kiro, Cursor, GitHub Copilot, VS Code).
metadata:
  version: "1.2.0"
---

# Boring Engineering

Build exactly what the current problem requires. No less, no more.

Use these questions inline with the existing task; they are not separate phases, documents or
approval gates. Read references only for an actual unresolved structure choice. Reuse the task's
acceptance checks and consolidate this review at its delivery boundary; do not start another
full review or test cycle for unchanged work.

## Step 1 — Requirement Filter (YAGNI)

Before writing any code, ask: is this required by the current task, including necessary authorized validation and documentation, or an explicit stakeholder requirement?

- NO → Do not build it. Stop.
- YES → Continue to Step 2.

If uncertain, default to not building it. A missing feature is easier to add than a wrong abstraction is to remove.

**Surgical changes only:** Modify only the files and behavior required for the current request. Do not perform drive-by refactoring, reformat unrelated code, or rewrite untouched comments. Clean up only unused imports or variables introduced by your own edits.

**Risk-list outlet:** If you notice adjacent bugs, missing edge cases, or tech debt outside the current task scope, list them briefly in your final response **without** adding defensive branches, compatibility shims, or extra tests for them in the diff.

## Step 2 — Reuse Check

Ask: does something already exist in the codebase that solves this?

- YES → Reuse it when it fully fits; extend it only as needed when it partly fits. Stop if no further work is needed.
- NO → Continue to Step 3.

Search the codebase before implementing. Prefer extending an existing solution over creating a parallel one.

## Step 3 — Simplicity Check (KISS)

Ask: what is the simplest correct implementation?

First, check for a standard library or platform feature that fits the requirements and environment. Prefer it over custom parsing, formatting, validation, retry, or data-shaping logic when it actually meets the need.

Use current idiomatic language features — modern syntax is typically shorter and clearer. But existing project conventions win: a codebase on old style stays old style.

Choose the implementation that a reasonably experienced developer can understand without explanation.

Prefer:
- Direct over indirect
- Flat over nested
- Explicit over generic
- Inline over extracted (when logic is used only once)
- Compact over sprawling, while preserving readability and the project's formatting conventions

Two correct solutions? Take the one with fewer moving parts.

**Defensive programming boundary:** Validate and guard only at untrusted external inputs, user/API/process boundaries, and real I/O boundaries. Let internal invariants fail directly; do not add redundant null checks for already-typed or guaranteed internal values, broad `try/catch` blocks around safe internal operations, or speculative fallback/compatibility layers.

**Test and regression discipline:**
- Do not write tests that merely mirror the implementation, assert trivial getters/setters/constants, or probe impossible internal states.
- When a bug fix or new feature requires a test, follow an existing nearby test file as an exemplar; do not invent new mocking layers, custom test harnesses, or heavy scaffolding for a localized change.
- Do not automatically run full or E2E test suites after minor edits unless explicitly required by the task or touching shared core code; run the smallest targeted test covering the changed behavior once.

Implement that. Continue to Step 4.

## Step 4 — Abstraction Check (Practical DRY)

Only run this step if the implementation introduces a shared utility, base class, or abstraction.

Ask all three:
1. Does this logic already appear in multiple real places in the codebase (not hypothetically)?
2. Would all those places need the same change if the logic changed?
3. Can this abstraction be named clearly without using "and" or "or"?

- All YES → Abstract only the genuinely shared behavior.
- Any NO → Keep the implementation direct. Duplication is acceptable.

For detailed decision trees and worked examples, read `references/decision-framework.md`.

## Step 5 — Final Review

When reviewing a design or implementation covered by this skill, check what applies:

- [ ] Could any block here be replaced by a standard library or platform built-in?
- [ ] Does the exported name or signature fail to match what was asked?
- [ ] Did I add anything the current requirement did not ask for (including drive-by edits or unrequested tests)?
- [ ] Did I add defensive checks or fallbacks for guaranteed internal invariants instead of limiting guards to real boundaries?
- [ ] Did I create an abstraction or test helper without enough proven evidence?

If any box is checked — revise before finishing.

Use `assets/decision-tree.md` as a quick reference for the full decision flow in one view.

## Output

Explain the result in the user's language and include the validation and limitations needed to assess it. Keep the explanation proportional to the change; list any out-of-scope observations concisely instead of implementing them, and do not narrate every check or walk through the examples unless asked.

## Avoid

- Unnecessary design patterns (factory, registry, strategy) for single use cases
- Generic abstractions before there are multiple real consumers
- Future-proofing or compatibility shims without an explicit requirement
- Redundant null checks, fallback branches, or `try/catch` wrappers on trusted internal state
- Unsolicited test suites, implementation-mirroring assertions, or novel mock harnesses for simple edits
- Auto-running full regression suites after every small edit
- Drive-by refactoring or reformatting outside the changed path
- Extra configuration options with only one known value
- Unused utilities, helpers, or dependencies
- Hand-rolled versions of standard library or platform features (parsing, formatting, cloning, debouncing, retries)
- Premature optimization without measured evidence
- Excessive file splitting for small, cohesive modules
- Large architectural layers (service/repository/domain) for features that need three lines

## When Complexity Is Allowed

Do not simplify by removing legitimate requirements. Allow necessary complexity only when
an actual invariant, explicit requirement or established failure at a real boundary calls for it;
choose the smallest sufficient implementation. The following areas may supply such a requirement,
but naming one alone does not justify speculative defensive branches or extra test scaffolding:

- Security and authentication
- Boundary input validation and I/O error handling
- Accessibility compliance
- Measured performance requirements
- Reliability and fault tolerance at real failure boundaries
- Existing project architecture and conventions
- Explicit requirements from stakeholders

## Examples

**Bad — premature abstraction:**
User needs one API client.
Building: `BaseApiClient`, `AbstractApiProvider`, `ApiClientFactory`, `ApiClientRegistry`.

**Good:**
```js
export async function fetchUser(id) {
  const res = await fetch(`/api/users/${id}`);
  return res.json();
}
```

For more patterns, read `examples/bad-abstractions.md` and `examples/before-after.md`.
