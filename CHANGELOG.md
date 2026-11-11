# Changelog

## Unreleased

Nothing yet.

## v0.2.0 — 2026-11-11

The first tagged release. **Early preview:** the tools, the loop and the receipt formats can still change. macOS 14+,
Swift 6 tools, Swift 5 language mode. The engine is pinned to MartyGraphics
[`38f3863`](https://github.com/morrowdock/martygraphics/commit/38f3863d5ed27c94fccf44b5f117a43938b79455). The version
is the one that `marty-mcp --version` reports; there was no 0.1.0 tag. Every change is a pull request in the
[history of `main`](https://github.com/morrowdock/marty/commits/main).

### What it does

- **`marty-mcp`**, an MCP server over standard input and output with the engine tools `catalog`, `explain`, `check`,
  `component_check`, `patch`, `render`, `lesson_check` and `lesson_stream`. It opens no network connection, runs no
  shell command and writes only into its output directory ([setup](docs/MCP-CLIENTS.md),
  [design](docs/DESIGN-MCP.md)).
- **`marty ask`**, a reference loop: research, plan, author, strict engine check, at most 3 repairs from the exact
  refusal reason, optional stills for an assembly (`--render`; an explainer is refused with `render.explainer`, so
  explainer stills and the story video come from MartyGraphics' `marty-solid render`), and a follow-up as an engine
  patch. Each run writes a receipt with the size and
  SHA-256 of every prompt ([docs/LOOP.md](docs/LOOP.md)).
- **Research with checks on form.** A bounded web-search step returns a fact table with labels (VERIFIED, CLAIM,
  PLAUSIBLE, UNKNOWN). Marty fetches each cited page itself, through a guarded fetch, and keeps a quote only when its
  words are on the page.
- **Honesty lints.** Numbers in shown text that do not come from the fact table, the question or the solved model
  (`fact.unsourced`), and answers that disagree with a posed view, trigger a bounded rewrite. A violation that remains
  is recorded in the receipt; the answer can still contain it. Repairs apply the engine's checked suggestions.
- **`marty bench`** and the 50-question development set `bench/dev-v1`. Infrastructure failures are error rows, never
  model results.

### Shown with real output

The jet-suit lesson in the [README](README.md): Claude Opus 5.5 through `marty ask`, refused twice with exact reasons,
accepted on the third try, shown unedited beside an AI fact check that found 1 wrong sentence and 12 corrections.

### Limits

- The only live-model adapter is the local Claude Code CLI (`claude -p`); a scripted adapter (`--scripted`) exists
  for tests. Other models can use the MCP server.
- The engine checks motion and layout, not the meaning of words. A lesson can be accepted and still be wrong.
- The bench is a development set used to improve Marty, not held-out evidence. Answers are not published unless an
  independent grader passed them.

### How it was made

AI agents (mainly Claude Opus 5.5) wrote the code and the docs under the direction of Collin Craig, through pull
requests that must pass CI, with independent reviews by other AI models.
