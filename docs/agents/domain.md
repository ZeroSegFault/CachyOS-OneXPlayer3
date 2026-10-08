# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

**Layout: single-context.** The whole repository (OneXPlayer3 / CachyOS host configuration and research) is one context. There is no `CONTEXT-MAP.md` and no per-directory `CONTEXT.md`.

## Before exploring, read these

- **`CONTEXT.md`** at the repo root — the domain glossary.
- **`docs/adr/`** — read ADRs that touch the area you're about to work in.

If any of these files don't exist, **proceed silently**. Don't flag their absence; don't suggest creating them upfront. The `domain-modeling` skill (used by `grill-with-docs` and `improve-codebase-architecture`) creates them lazily when terms or decisions actually get resolved.

## File structure

```
/
├── CONTEXT.md
├── docs/adr/
│   ├── 0001-<decision>.md
│   └── 0002-<decision>.md
└── …
```

If the repo later grows distinct areas with conflicting vocabulary, rerun setup to switch to a multi-context layout (`CONTEXT-MAP.md` pointing at per-context `CONTEXT.md` files) rather than adding ad-hoc context files.

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined in `CONTEXT.md`. Don't drift to synonyms the glossary explicitly avoids.

If the concept you need isn't in the glossary yet, that's a signal — either you're inventing language the project doesn't use (reconsider) or there's a real gap to take to `domain-modeling`.

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than silently overriding:

> _Contradicts ADR-0007 (example decision) — but worth reopening because…_
