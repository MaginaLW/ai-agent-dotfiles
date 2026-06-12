# Merge Notes — hatch-pet

- Promoted from MAGINA-LAPTOP unknown Codex live skill / imported quarantine candidate after manual audit (2026-06-12).
- Canonical source: the 21-file variant (`imports/skills-inbox/magina-laptop/codex/hatch-pet`), byte-identical to the MAGINA-LAPTOP live `~/.codex/skills/hatch-pet`.
- A divergent 14-file variant (`hatch-pet-copy-1` / quarantine `platform-conflict` copy, richer SKILL.md but fewer scripts, brand-mascot focus) was reviewed and explicitly NOT promoted.
- Classified as codex-only because it depends on the Codex platform `.system/imagegen` system skill and packages pets under `${CODEX_HOME:-$HOME/.codex}/pets/`.
- No hard-coded secrets, machine-private paths, or account info found; API credentials are read from environment variables at runtime (`os.environ.get("OPENAI_API_KEY")`, `Authorization: Bearer {api_key}`).
- Runtime generated output excludes MERGE_NOTES.md via build-skills.ps1.
