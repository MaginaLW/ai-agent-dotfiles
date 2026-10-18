# Branch disposition (2026-10-18)

Owner authorized proceeding with this step on 2026-10-18: the local deletions (T1/T2 of the
v2 plan `tmp/optimization-plan-20261018.md`). The remote branch deletion (T3) and any push
remain separately gated. No push, merge, live Apply or gc is part of this task.

Background: the fifth-round close-out deliberately kept its branches for recoverability; this
task reverses that 2026-10-16/18 decision under the owner's authorization (decision recorded
in `tmp/grok16/execution-result.md` and `tmp/publish-fifth-20261018/README.md`). The plan went
through a three-way Grok review (fact recomputation, approach, adversarial; evidence in
`tmp/grok18/`) and each claim below was re-verified by the main agent before execution.

## Evidence captured immediately before deletion

| Ref | Full tip SHA | Integration evidence |
|---|---|---|
| `refs/heads/codex/fifth-dangerous-paths` | `7ff905d24f80834d84bdd8a97c83d36ffeb7798c` | `git cherry -v main` prints 1 `-` line; verbatim patch-id `9972cf47` equals main commit `c1e401b2` (an ancestor) |
| `refs/heads/codex/fifth-profile-docs` | `3f4545f0c0b6f07f119c48160192a5e3d0aaa92f` | 2 `-` lines (`9349f65`, `3f4545f`); patch-ids equal main commits `4f9a7bd1` and `6226e8aa` |
| `refs/heads/codex/fifth-scan-report` | `f7b4454a9f3a2b873590a6d9878a8cb5f50d7ff9` | 1 `-` line; patch-id `fbaad7d5` equals main commit `40d60cf6` |
| `refs/heads/codex/fifth-optimization-20261016` | `c0d8e94f48087eeaed027409bcbb8cc59138ab07` | `git merge-base --is-ancestor <sha> main` exits 0; it is `main^2` |

Raw proof at capture time:

    $ git cherry -v main codex/fifth-dangerous-paths
    - 7ff905d24f80834d84bdd8a97c83d36ffeb7798c Extract dangerous tracked path predicate and cover policy cases
    $ git cherry -v main codex/fifth-profile-docs
    - 9349f6508fbfb25b6775298296ab757a42a4bb1c Remove unused RequiredEnv profile key
    - 3f4545f0c0b6f07f119c48160192a5e3d0aaa92f Document profile inheritance and sync recovery boundaries
    $ git cherry -v main codex/fifth-scan-report
    - f7b4454a9f3a2b873590a6d9878a8cb5f50d7ff9 fix: preserve keyword hint counts in scan reports

Cherry line counts equal `git rev-list --count main..<ref>` (1/2/1, all `-`), `git log --merges
main..<ref>` is empty for all three, tips match the recorded full SHAs, and none of the refs is
checked out in any worktree.

Deletion commands (expected-SHA form: a moved tip fails instead of being deleted silently):

    git update-ref -d refs/heads/codex/fifth-dangerous-paths  7ff905d24f80834d84bdd8a97c83d36ffeb7798c
    git update-ref -d refs/heads/codex/fifth-profile-docs     3f4545f0c0b6f07f119c48160192a5e3d0aaa92f
    git update-ref -d refs/heads/codex/fifth-scan-report       f7b4454a9f3a2b873590a6d9878a8cb5f50d7ff9
    git update-ref -d refs/heads/codex/fifth-optimization-20261016 c0d8e94f48087eeaed027409bcbb8cc59138ab07
    git config --remove-section branch.codex/fifth-optimization-20261016

Remote `refs/heads/codex/fifth-optimization-20261016` on origin stays at
`c0d8e94f48087eeaed027409bcbb8cc59138ab07` until its own authorization.

Recovery: before object pruning, restore a deleted local ref with
`git update-ref refs/heads/<name> <full-sha>`. The three staging commits' file content is also
in main as the commits named above; `c0d8e94` is permanently reachable as `main^2`. No gc runs
in this task.

Progress: preconditions checked (clean tree, single checkout, tips unchanged, proofs re-run);
deletions and close-out pending.
