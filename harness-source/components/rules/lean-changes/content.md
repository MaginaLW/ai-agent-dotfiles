## Lean Changes & Test Discipline

- Implement only the requested behavior; no unrequested refactoring, abstractions, or compatibility shims.
- Restrict defensive validation and error handling to untrusted inputs and external/I/O boundaries.
- Do not add tests that mirror implementation details or invent new mock harnesses; follow nearby existing tests.
- Never auto-run full or E2E suites after minor edits; run only the smallest targeted test once.
- List any unrelated risks or edge cases briefly in the final summary without editing code or tests for them.
