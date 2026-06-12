---
name: placeholder-ok
description: Demonstrate safe environment variable placeholders for MCP authentication.
---

# Placeholder OK

Use `Bearer ${GITHUB_PAT}` in templates and keep real values outside the repository.

Example configuration:

```toml
bearer_token_env_var = "GITHUB_PAT"
```
