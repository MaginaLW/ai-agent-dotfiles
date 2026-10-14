# Low-value cleanups from the 2026-10-13 review (2026-10-14)

Owner-approved cleanup of the remaining low-priority review findings: dead code (the unused
ExecutableSha256 return property, the unused -ExcludeNames parameter, the unread lock
ChecksumAsset fields, the misleading fixture profile), one over-wide test assertion, redundant
ignore lines, backup timestamps unified on UTC, git ls-files -z/UTF-8 handling for the syntax
gate, and the scan-secrets fallback skip list derived from the single exclusion source.
