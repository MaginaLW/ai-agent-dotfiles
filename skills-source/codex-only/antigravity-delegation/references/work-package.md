# Work package and private installation

The production entry is `scripts/invoke.mjs --package <absolute-json> [--preflight]`.
A reviewed continuation adds `--resume-successor <absolute-review-json>`.
It loads `routes.json` and `deployment.json` from the one private `agent-delegation` directory
under `LOCALAPPDATA`. Caller arguments cannot select a different route or state directory.
The preflight is read-only and launches neither agy nor the Windows ownership helper.

`routes.json` contains only distinct `primary` and `fallback` objects, each with a model ID.
The actual IDs and reasoning levels stay in private configuration. Validate them against the
frozen CLI model catalog; an unknown role/model, unavailable ID or duplicate mapping must fail.
A running package keeps its frozen mapping even if the user later edits the private routes.

`deployment.json` names the reviewed installation:

```json
{
  "enabled": false,
  "channel": "native-agy",
  "consumerUseAcknowledged": false,
  "bridgeRoot": "<absolute-bridge-checkout>",
  "agyPath": "<absolute-agy-executable>",
  "catalogPath": "<absolute-frozen-catalog-json>",
  "stateRoot": "<private-agent-delegation-directory>/state",
  "settingsPath": "<absolute-reviewed-session-settings-json>"
}
```

`settingsPath` is required and binds the reviewed session settings for this package.
Task settings must keep extra credits disabled, preserve native permissions and expose only
the reviewed fixture/plugin/tool set. Do not assume a settings field enforces a capability:
verify the actual permission and capability behavior in the appropriate acceptance stage.
Installation defaults are disabled. Enabling the entry, installing a new skill and setting
agy's global default require the applicable reviewed deployment authorization. Preserve the
previous default for revocation. Do not copy a consumer subscription into an API/enterprise claim.

Before calling, save a small JSON work package in the task's ignored output directory. Bind:

- A unique ID, goal, project workspace and exact writable scope; record existing WIP.
- Acceptance commands, required Skill paths, MCP servers, native plugins and tool allowlist.
- Read-only analysis or the authorized implementation permissions, including external-action limits.
- One primary call, zero or one quota fallback, the package timeout and stop conditions.
- The SHA-256 of the raw route-file bytes, confirmed by preflight; retain package, catalog and settings digests with receipts.

The runner validates this work-package shape (all paths are absolute and examples are placeholders):

```json
{
  "id": "<unique-package-id>",
  "target": "<goal and necessary context>",
  "workspace": "<absolute-project-checkout>",
  "writeScope": ["<task-owned-relative-path>"],
  "existingWip": ["<preserved-existing-change>"],
  "acceptanceCommands": ["<authorized-test-command>"],
  "capabilities": { "skills": [], "mcp": [], "plugins": [] },
  "permissions": { "mode": "workspace-write", "allowedTools": [] },
  "budget": { "primary": 1, "fallback": 1, "timeoutMs": 180000 },
  "stopConditions": ["<task-specific-stop>"],
  "configSha256": "<preflight-route-sha256>"
}
```

Every capability entry is `{ "path": "<absolute-file>", "sha256": "<frozen-file-sha256>" }`.
Set `budget.fallback` to `0` when fallback is not authorized; that package cannot continue to a successor.
Use `permissions.mode: "read-only"` with an empty `writeScope` for analysis. The reviewed
session settings must match the package's allowed-tool list. The catalog is
`{ "models": [{ "id": "<available-cli-model-id>" }] }` and remains private.
Keep goal, scope, budget and permission decisions in
that package; do not put credentials, unrelated chat history or complete personal configuration
in prompts. Prompt instructions alone are not a sandbox or proof of tool permission.

The managed host writes intent and Windows process/Job binding before resume, and preserves
original cleanup evidence. A hard host interruption leaves unknown ownership and blocks new
work and fallback. The existing native helper retains an interrupted tree; disappearance of
its root or Job name is not cleanup proof. Never clear the state or select a fresh state root
to make execution possible.

A quota successor needs the original quota receipt, confirmed cleanup, an inspected diff/test
snapshot and a remaining-work package. It consumes the one fallback budget of that original
package. Do not implement continuation by issuing another primary request or resubmitting the
original goal. Keep the original `--package` and add `--resume-successor <absolute-review-json>`:

```json
{
  "receiptSha256": "<primary-receipt-sha256>",
  "reviewedProgress": "<observed-completed-operations-diff-tests-and-side-effects>",
  "remainingTask": "<only-the-remaining-authorized-work>"
}
```

A stale receipt, unknown cleanup, repeated fallback or changed package/config must be rejected.
