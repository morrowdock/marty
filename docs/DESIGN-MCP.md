# Design note: the Marty MCP tool set

Status: implemented in `marty-mcp` 0.2.0. Engine pin: MartyGraphics `main` at
`38f3863d5ed27c94fccf44b5f117a43938b79455` (PR #20 lessons, PR #21 open vocabulary 1: facts,
placeholders, truth tiers, frame lints, strict profile, PR #30: the report and render plan as
library API, PR #31: annotations: labels, arrows, measured dimensions, and PR #32: explainer
documents, and PR #34: per-step framing with `focus`, and the `mannequin` and
`centrifugalCompressor` components, PR #35: the presented-only explainer legend, and PR #36:
the adaptive board pane, mannequin anchor descriptions and the annotation visibility
detail, PR #37: unblocked focus, story move cuts, `microTurbojet` and the `parts.resolved`
detail, PR #39: step `pose`, `hide`/`show`, instance ids in step lists, PR #40: strict label and pointer
anchors with `anchorIssues`, PR #43: anchor `suggest`/`noSuggest`, limit details and `repair` lines, PR #44: routed story camera moves and strict arrow visibility with `arrowIssues`, PR #45: the story slides the explainer board pane in and out, PR #46: `backLeft`/`backRight` camera presets and bare `{"part"}` anchors at the part centre). Marty's `render` does not write the CLI's `loop.mp4` or `story.mp4`; use
`marty-solid render` for them. `render` draws the
annotation overlay on the hero and step stills, as `marty-solid render` does.

## Goal

Give any model, through any MCP client, the same small set of engine tools.
The model writes and changes scene documents. The engine checks them, refuses
what is wrong with a stable reason, and renders what is right. The tools add
no judgment of their own: every number in a result comes from the engine.

## Rules for every tool

1. **Deterministic.** The same input at the same engine pin gives the same
   bytes of output. JSON keys are sorted. Results contain no clock time,
   random value or absolute path. The only exception is `render`: it returns
   the absolute path of its output directory (a client needs it to open the
   files) and a measured time (`timing` in the result, and
   `renderSecondsPerFrame` in the engine's `manifest.json`). Image digests are stable on one machine only: Metal output
   can differ between GPUs and operating system versions.
2. **Bounded.** A request line is at most 1 MiB. A document is at most the
   engine limit (64 KiB). A component definition is at most 16 KiB, and a
   request carries at most 8 of them. A patch is at most 16 KiB. A line over
   1 MiB is refused before it is parsed. A document, component or patch sent
   as a string is measured as sent, before it is parsed. One sent as a JSON
   object is parsed with the request and then measured in its canonical
   (compact, sorted-key) form; `source.bytes` in a result is that canonical
   size.
3. **No network and no shell.** The server reads JSON-RPC from standard input
   and writes to standard output. It never opens a socket and never runs a
   process. Model text is only data for the engine parser.
4. **Writes only to its own directory.** `render` writes into a new
   subdirectory `render-<digest>` of the output root: `--output-dir`, or by
   default `~/Library/Caches/marty-mcp/renders` (`--no-render` turns `render`
   off). A tool argument can never choose a path. The digest covers the engine
   pin, Marty's render format version, the document, the components, the size
   and the loop flag, so the same request reuses the same directory. A
   process that is killed during a render can leave a `.partial-*` directory;
   it is safe to delete.
5. **Refusal is a result, not an error.** A document that the engine refuses
   gives `ok: false` with `reason` (a stable dotted token, for example
   `constraint.gearMesh.distance`) and `part`. A tool error (`isError: true`)
   means that the request itself was wrong, for example a missing argument.
6. **Small context.** Results are compact. Large data (the full document, the
   snapshot) is returned only when the caller asks for it.

## Documents by reference

A document can be up to 64 KiB, and a repair loop sends it many times. To keep
the context small, `check` returns `ref`, the SHA-256 of the canonical
document (`sha256:` followed by 64 hex digits). Formatting does not change a
`ref`. The server keeps the last 32 documents that it could read as JSON
(accepted or refused) in memory. A document that is not valid JSON, or is too
large, gets no `ref`. `render`, `patch` and `check` accept `ref` in place of
`document`. An unknown `ref` gives the tool error `cache.miss` (a name that
cannot be mixed up with the engine's own `ref.unknown.<id>`), and the caller
sends the full document again. The cache is only a speed-up: a result never
depends on what is in the cache.

## Tools

| Tool | Input | Result |
| --- | --- | --- |
| `catalog` | `compact` (default true) | Components (id, about, parameters with default and range, inner parts, anchors; about 4 KB for the 7 built-ins at this pin, and it grows with the library), plus a fixed part: primitive ids, camera presets and the format limits. |
| `explain` | `id` (component or primitive) | One entry: what it is, its keys or parameters, and one small example that the engine accepts. |
| `check` | `document` or `ref`; `components` (optional definitions); `strict` (default true) | `ok`, `reason`, `part`, `ref`, title, part count, triangles, steps (v2 captions filled from facts), solved ratios, mesh and gear checks, `strict`, `file` (lines and SHA-256 of the canonical JSON), `engine`, and the engine's honesty data: `version`, `warnings`, `facts` (value, unit, text, tier, source), `legend`, `stepTiers`, `stepFacts`, `partTiers`, `motionTiers`, `notChecked`, `sectionTriangles`, `readBack` (in accepted reports and in reports refused by a post-compile check; an engine parse refusal has only `ok`, `reason`, `part`, `strict`, `file`, `engine` and `ref`; an input refusal such as `json` or `assembly.bytes` has only `ok`, `reason`, `part`, `strict`; a `components` refusal (`component.bytes`, `json` or a registration refusal) has `ok`, `reason`, `part` and `component` (its index), in `check` and `patch` alike). 0.2.0 replaces 0.1.0's `source` object with `file`. |
| `component_check` | `definition`; `with` (optional values) | `ok`, `reason`, `part`, the catalog entry, a ready `use` entry and the instance checks. |
| `patch` | `document` or `ref`; `patch` (the engine format, below); `components` (optional); `strict` (default true) | The `check` result of the patched document, its new `ref`, and the patched document when `return_document` is true. |
| `render` | `document` or `ref`; `components`; `size` (default 1280x800, at most 1920x1200); `loop` (default false) | `ok`, the output directory, the file names (hero, exploded, one still per step, optional loop GIF, snapshot, manifest) and their SHA-256 digests. |
| `lesson_check` | `lesson` (a lesson document, MartyGraphics docs/LESSONS.md) | All or nothing, in a fresh engine session: `ok`, or the reason with `beat`, `statement`, `command`, `detail`. Accepted: each beat's line with `{placeholders}` filled from engine values, and the final `board` (beat cursor, engine values with their formatted text, controls). |
| `lesson_stream` | `chunk` (statement text, any split, at most 32 KiB); `session` (optional); `end` (optional) | The session id, this call's events (`accepted`, `refused` with reason and location, `lineQueued` with filled text, `beatPresented`, `streamEnded`, ...), the `board`, beats waiting, unfinished bytes and `exhausted`; `truncatedEvents` when more than 512 events; `reason: lesson.stream.exhausted` when statements were sent to a stream that was already exhausted. `ok` is false when this call had a refusal or its statements were dropped. |

**Patch format.** `patch` uses the engine's own patch,
`MGSolidParser.applying(_:to:)`. Its keys are `params`, `parts` (merge fields
by part id; for a plain part, `null` removes a field; `instance.part` merges into that `use`
entry's `set`; the instance id edits the `use` entry itself), `constraints`
and `steps` (each replaces the whole list) and `title`. Other keys are refused
with `patch.unknown.<key>`. The engine patches only a compiled document, so the
base must be accepted. A refused base gives `ok: false` with `stage: "base"`
and the base's own reason; a refused patch gives `stage: "patch"`.

**Primitives.** The engine has no public list of primitive kinds and their
keys. Marty keeps that list, taken from docs/SOLID-3D.md at the pin, and tests
hold it to the engine: every example must be accepted; for shapes, and for the
drives and constraints with object bodies (`follow`, `crankSlider`,
`crankRod`, `gearMesh`), every missing required key must be named in the
refusal, an unknown key must be refused, and every optional key must be known
to the parser.

**Render refuses what check refuses.** `render` runs the same report as
`check` and renders only an accepted document, so it also refuses
`check.meshOpen` and `check.gearsInterpenetrate`. The engine's own CLI render
does not run those two checks.

**Explainers.** A document with `kind: "explainer"` (MartyGraphics PR #32: a
2D board and/or a 3D solid on one beat timeline, one id namespace, one legend)
is checked by `MGExplainerReport` (exactly `marty-solid check [--strict]` on
it), with Marty's `ref`. For the Marty loop, Marty also copies the 3D view's
`facts`, `ratios`, `readBack` and part ids, and the beat captions and tiers
as `steps` and `stepTiers`, to the top level. `patch` (the engine has no patch
format for explainers) and `render` (render it with `marty-solid render`) give
the tool errors `patch.explainer` and `render.explainer`. Marty's 64 KiB
document limit applies to explainers too (the engine allows 128 KiB).

**Lessons.** Both lesson tools use the engine's own session
(`MGLessonSession`) with immediate pacing and a manual clock, so results hold
no time and are deterministic. `lesson_check` reports each beat's line as the
learner hears it (`lineDue`, filled from the presented state). The server
keeps at most 8 stream sessions; the least recently used is dropped, and an
unknown or dropped id gives the tool error `lesson.session.unknown`. The
engine's own budgets apply (32 KiB and 256 statements per stream, 24 beats, 12
commands and 8 checks per beat). After a budget refusal (reported in that
call's events, for example `lesson.bytes`) the engine ignores the stream until
it ends. Later calls that send statements then give `ok: false` with
`lesson.stream.exhausted` (also when the call has `end: true`, which then
starts over); an empty chunk, or one of only spaces, tabs, CR and LF, gives
`ok: true` with `exhausted: true`. Marty always passes input to the engine
and reads `exhausted` from what the engine did, so a fresh stream that the
engine starts is never blocked. One call returns at most 512
events (`truncatedEvents` counts the rest). The opt-in `rotate2d` template
(`MGGeometryPack`) is registered on the first lesson call. Lessons are 2D in
this engine phase; solid lessons are not in the engine yet.

Later tools, when the engine supports them:

- None at this pin. Solid lessons and further open-vocabulary phases come
  with later engine releases.

**Strict by default.** `check` and `patch` use the engine's strict profile
unless `strict: false` is sent, because the tools are for model authors (the
engine's docs name strict the default for model harnesses). Strict also
refuses `joint.idle.<id>` and `frame.axis.off.<id>`; the refusal order is the
CLI's (open mesh, gear overlap, then the strict warning). The full honesty
data is in every accepted or post-check-refused report, also when strict
refuses, so the author can repair from it. `render` and `component_check` use
the plain profile.
The Swift API (`MartyEngine.check` / `patch`) defaults to the plain profile;
the MCP tools and the Marty loop pass `strict: true` explicitly.

**Patch reports.** `patch` compiles once and reports on the patched document
(`MGSolidParser.applying`, then `MGSolidReport.make`), so its `file` and `ref`
describe the patched document. Unlike `marty-solid check BASE --patch PATCH`
(`MGSolidReport.check(data:patch:)`, which compiles again and reports with the
base's `file`), it has no `patch` object (`applied`, `fields`, `changed`,
`refusedAt`). A refusal before the patched document exists has `stage`
(`base` or `patch`): an engine refusal there has the same shape as a `check`
refusal of the base (`file` and `strict` of the base, `engine`), with `stage`
and `baseRef` in place of `ref`; an input refusal (`assembly.bytes`,
`patch.bytes`, `json`) has only `ok`, `reason`, `part`, `strict` and `stage`;
`cache.miss` is a tool error. A patched
document that compiles but fails a report check (open mesh, gear overlap,
strict) is a normal report with `ok: false`, its own `ref` and no `stage`.
Until a feature is in the pinned engine, the server does not offer the tool or
the field. The server never imitates an engine feature.

## What the engine owns

The check report, the render sequence and the manifest are engine library code
(MartyGraphics PR #30): `MGSolidReport.make` / `refused` give exactly what
`marty-solid check [--strict]` prints, and `MGSolidRenderPlan` gives the stills,
loop frames, snapshot and manifest of `marty-solid render`. Marty calls them and
adds only `ref`, `partIds` and its own `engine.revision`; its `file` describes
the canonical JSON it checked. Captions and image files are drawn by the host,
as in the CLI. A test compares Marty's `check` with the engine's committed CLI
golden reports for every example model, in both profiles.

## Transport

- JSON-RPC 2.0, one message per line on standard input and output (MCP stdio
  transport). Logs go to standard error only.
- Methods: `initialize`, `notifications/initialized`, `ping`, `tools/list`,
  `tools/call`. Other requests give `-32601`. An unknown tool name in
  `tools/call` gives `-32602`. A `null` argument means "not given". Unknown notifications (for
  example `notifications/cancelled`) are ignored.
- Protocol versions: the server answers with the client's version when it
  supports it (2025-11-25 or 2025-06-18), else with 2025-11-25. Both use the
  same messages for a tools-only server. 2025-03-26 is not offered: it
  requires JSON-RPC batches and has no `structuredContent`.
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
  The same input in two processes must give the same bytes (`render` is
  not part of this test).
- `render` tests run only when a Metal device is present.
