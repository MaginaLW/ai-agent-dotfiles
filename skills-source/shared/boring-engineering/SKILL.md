---
name: boring-engineering
description: "Prevents overengineering when designing, implementing, refactoring, or reviewing software. Use when the user asks to implement a feature, add an abstraction, refactor code, review a design, simplify existing code, or make an architectural decision. Also triggers when the user asks if code is too complex, whether to abstract something, or how to structure something. Do not use for deployment, infrastructure configuration, or debugging runtime errors unrelated to code structure."
license: MIT
compatibility: Works in any Agent Skills-compatible runtime (Claude Code, Kiro, Cursor, GitHub Copilot, VS Code).
metadata:
  version: "1.1.0"
---

# Boring Engineering

Build exactly what the current problem requires. No less, no more.

## Step 1 — Requirement Filter (YAGNI)

Before writing any code, ask: is this required by the current task, including necessary authorized validation and documentation, or an explicit stakeholder requirement?

- NO → Do not build it. Stop.
- YES → Continue to Step 2.

If uncertain, default to not building it. A missing feature is easier to add than a wrong abstraction is to remove.

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

Before completing any task, run this checklist:

- [ ] Could any block here be replaced by a standard library or platform built-in?
- [ ] Does the exported name or signature fail to match what was asked?
- [ ] Did I add anything the current requirement did not ask for?
- [ ] Did I create an abstraction without enough proven evidence?

If any box is checked — revise before finishing.

Use `assets/decision-tree.md` as a quick reference for the full decision flow in one view.

## Output

Explain the result in the user's language and include the validation and limitations needed to assess it. Keep the explanation proportional to the change; do not narrate every check or walk through the examples unless asked.

## Avoid

- Unnecessary design patterns (factory, registry, strategy) for single use cases
- Generic abstractions before there are multiple real consumers
- Future-proofing without an explicit requirement
- Extra configuration options with only one known value
- Unused utilities, helpers, or dependencies
- Hand-rolled versions of standard library or platform features (parsing, formatting, cloning, debouncing, retries)
- Premature optimization without measured evidence
- Excessive file splitting for small, cohesive modules
- Large architectural layers (service/repository/domain) for features that need three lines

## When Complexity Is Allowed

Do not simplify by removing legitimate requirements. Complexity is always acceptable for:

- Security and authentication
- Input validation and error handling
- Accessibility compliance
- Measured performance requirements
- Reliability and fault tolerance
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
