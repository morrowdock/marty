# Design note: the Marty MCP tool set

Status: draft, 2026-11-06. Engine pin: MartyGraphics `main` at
`76104deae44a186ccf29a43db9e091f088f12103`.

## Goal

Give any model, through any MCP client, the same small set of engine tools.
The model writes and changes scene documents. The engine checks them, refuses
what is wrong with a stable reason, and renders what is right. The tools add
no judgment of their own: every number in a result comes from the engine.

## Rules for every tool

1. **Deterministic.** The same input at the same engine pin gives the same
   bytes of output. JSON keys are sorted. Results contain no clock time,
   random value or absolute home path. The only exception is `render`, which
   reports a measured render time in a separate `timing` field.
2. **Bounded.** A request line is at most 1 MiB. A document is at most the
   engine limit (64 KiB). A component definition is at most 16 KiB, and a
   request carries at most 8 of them. A patch is at most 16 KiB. Larger input
   is refused before it is parsed.
3. **No network and no shell.** The server reads JSON-RPC from standard input
   and writes to standard output. It never opens a socket and never runs a
   process. Model text is only data for the engine parser.
4. **Writes only to its own directory.** `render` writes into a new
   subdirectory of the output root that the server got at launch
   (`--output-dir`). A tool argument can never choose a path.
5. **Refusal is a result, not an error.** A document that the engine refuses
   gives `ok: false` with `reason` (a stable dotted token, for example
   `constraint.gearMesh.distance`) and `part`. A tool error (`isError: true`)
   means that the request itself was wrong, for example a missing argument.
6. **Small context.** Results are compact. Large data (the full document, the
   snapshot) is returned only when the caller asks for it.

## Documents by reference

A document can be up to 64 KiB, and a repair loop sends it many times. To keep
the context small, `check` returns `ref`, the SHA-256 of the canonical
document (`sha256:` followed by 64 hex digits). The server keeps the last 32
accepted or refused documents in memory. `render`, `patch` and `check`
accept `ref` in place of `document`. An unknown `ref` gives the tool error
`ref.unknown`, and the caller sends the full document again. The cache is
only a speed-up: a result never depends on what is in the cache.

## Tools

| Tool | Input | Result |
| --- | --- | --- |
| `catalog` | `compact` (default true) | Components (id, about, parameters with default and range, inner parts, anchors), primitive kinds, materials, camera presets and the format limits. About 4 KB when compact. |
| `explain` | `id` (component or primitive) | One entry: what it is, its keys or parameters, and one small example that the engine accepts. |
| `check` | `document` or `ref`; `components` (optional definitions); `strict` (optional) | `ok`, `reason`, `part`, `ref`, title, part count, triangles, steps, solved ratios, mesh and gear checks, source size and SHA-256. |
| `component_check` | `definition`; `with` (optional values) | `ok`, `reason`, `part`, the catalog entry, a ready `use` entry and the instance checks. |
| `patch` | `document` or `ref`; `patch`; `components` (optional) | The `check` result of the patched document, its new `ref`, and the patched document when `return_document` is true. |
| `render` | `document` or `ref`; `components`; `size` (default 1280x800, at most 1920x1200); `loop` (default false) | `ok`, the output directory, the file names (hero, exploded, one still per step, optional loop GIF, snapshot, manifest) and their SHA-256 digests. |

Later tools, when the engine supports them:

- **Facts, tiers and read-back** (MartyGraphics PR #21, open-vocabulary
  phase 1). `check` adds `facts` (the solved values that captions can cite),
  `tiers` (Solved, Built or Described for each part), `warnings` (frame
  lints) and `readBack` (each part's world position, axis and parent frame in
  plain words). `strict: true` maps to the engine's strict mode.
- **Lessons** (MartyGraphics PR #20). `lesson_check` checks a lesson
  document and returns its beats. `lesson_stream` takes statements one at a
  time and returns, for each, accepted or refused with a reason, and the
  timing events. The session state lives in the server under a session id,
  with a bound on sessions and statements.

Until a feature is in the pinned engine, the server does not offer the tool or
the field. The server never imitates an engine feature.

## What the engine should own

`marty-solid check` builds its report (mesh closure, the gear sweep and the
refusal order) in the example CLI, not in the `MartyGraphics` library. Marty
must copy that logic, and a copy can drift. Request to the engine coordinator:
move the report into the library (for example `MGSolidReport.make(doc)`), so
the CLI and Marty use one implementation. Until then, Marty keeps its copy
small and tests it against the same example models as the CLI.

## Transport

- JSON-RPC 2.0, one message per line on standard input and output (MCP stdio
  transport). Logs go to standard error only.
- Methods: `initialize`, `notifications/initialized`, `ping`, `tools/list`,
  `tools/call`. Other methods give `-32601`.
- Protocol versions: the server answers with the client's version when it
  supports it (2025-06-18 or 2025-03-26), else with 2025-06-18.
- Results have both `content` (one text item with the JSON) and
  `structuredContent` (the same JSON as an object).
- Requests are handled one at a time, in order, on the main thread. Rendering
  needs the main thread, and one request at a time keeps results reproducible.
- No third-party MCP library. The protocol subset is small, and a
  dependency would add code that we must review and pin.

## Tests

- Unit tests for each tool on the engine's own example models (planetary,
  slider-crank, the component versions), refusal tokens, size limits and the
  `ref` cache.
- Protocol tests that start the built server as a fresh process, send
  `initialize`, `tools/list` and `tools/call`, and compare the results.
  The same input in two processes must give the same bytes.
- `render` tests run only when a Metal device is present.
