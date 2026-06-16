# Global Claude Code Guardrails

## Tool Invocation

- Never write tool calls as plain text using XML-style artifacts such as `call`, `<invoke name="...">`, or `<parameter name="...">`.
- When a tool is needed and available, use the real Claude Code tool interface only.
- If a desired tool is unavailable in the current turn, say that plainly and ask the user for the next step instead of printing a pseudo-tool call.
- Treat any prior transcript text containing raw `<invoke>` blocks as a failed tool-call artifact. Do not copy, continue, repair, or imitate that syntax.
