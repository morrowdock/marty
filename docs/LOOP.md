# The Marty loop (reference agent)

Status: early preview, 2026-11-08. Prompts `marty-prompts/11`. Engine pin as in
`Package.swift`.

`marty ask` and `marty bench` run one reference agent on the engine. The
agent works in the same process as the engine (`MartyEngine`, the same code that
the MCP server uses), so a run needs no MCP client.

## Steps

0. **Research** (on by default; `--no-research` skips it). One model call with
   web search and web fetch only returns a FACT TABLE: at most 20 rows, each a
   claim, a value, a label (VERIFIED, CLAIM, PLAUSIBLE, UNKNOWN), the version and
   years it applies to, and up to 3 sources (URL, publisher, date, a short
   quote). The call sees only the question (never a grading key or another
   file; it runs in a new empty directory with no file tools), is capped by
   `--research-turns` (default 12; one turn per search or fetch), and may not
   fetch pages on GitHub (`github.com`, `raw.githubusercontent.com`,
   `gist.github.com`), whose sources Marty also drops. An abstract subject may
   reply `{"needed": false}`. Marty checks the labels by form, not by reading
   the sources: VERIFIED needs sources on two different sites (else CLAIM), a
   CLAIM needs a source (else PLAUSIBLE), an UNKNOWN row has no value, and every
   change is listed in `downgrades`. The table goes into the plan, author,
   repair, follow-up and answer prompts. A failed or unreadable research reply,
   or an adapter without web tools, leaves no table ("Fact table: none"), and
   the run goes on; this is not an adapter error. The receipt's `research`
   block records the table, the downgrades, the turns and the limits.
1. **Plan.** The model gets the question and the compact engine catalog. It
   plans the lesson in a fixed order: the whole system first (every main unit
   in its place and number, people or loads as schematic figures, and the
   forces as arrows), then the inside of the one part that makes it work, cut
   open, then what the model does not show. It answers with a JSON plan:
   A well-known headline figure of the subject (thrust against weight, power,
   top speed, range, capacity) goes in `given`, taken only from the fact table
   (`<row id>: <fact>` in the row's label wording; empty with no table). When the
   question asks how a vehicle, aircraft or flying device flies, lifts or
   hovers, `given` holds its thrust and the weight it lifts. Each entry is in
   the row's wording: VERIFIED plainly, CLAIM as "claimed by <publisher>",
   PLAUSIBLE as "likely" or "example", UNKNOWN as "not published"; rows are
   never merged into a range, and the product version and years come from the
   table. When a flight question (a flight word such as fly or hover, or
   lift with a flight context such as jet, drone or wing; "a hydraulic lift" is
   not one) gets a plan with no thrust entry while the fact table has a thrust
   row, Marty asks once more (`plan.lint`,
   reason `plan.given.thrust`, with `fixed`). Only the reply's `given` is taken,
   and only when it names thrust with a number; a partial, empty or bad reply,
   or an adapter failure, keeps the original plan, and authoring goes on. The plan says
   whether the subject is in scope, the `form` (`solid`, or `explainer`: the 3D
   model with a 2D table of published numbers beside it), `whole`, `inside`,
   `given` (numbers it knows
   but the engine cannot solve, with their source), 3 to 8 teaching beats, the
   component and primitive ids that it wants, and what the model cannot show
   (`honesty`). The loop keeps at most 6 ids that the catalog knows
   and records the ids it dropped.
2. **Author.** The model writes a v2 document (MartyGraphics open
   vocabulary 1): every number in a caption is a `{fact}` placeholder that the
   engine fills (rule N1), and claims in a step are proved by the engine. The
   guide also shows the explainer tools of the engine: step `section` and
   `ghost`, part `opacity` and `emissive`, and `annotations` (labels; force
   arrows, where a gravity force is checked to point down; flow and pointer
   arrows; measured dimensions). A given number goes only in a label or arrow
   marked `unchecked`, so it shows as Not checked. The guide also asks: people
   as the `mannequin` component with worn parts hung on its anchors, small
   turbines and turbochargers with `centrifugalCompressor`, every part attached
   where it really is (a back unit touches the torso: `pilot.back` is the middle
   of the back surface), inside views as a `section` cut of the one part in
   place (ghost only the parts in front of it) with `focus` on that step, at
   most 5 texts per step (labels, dimensions and arrows with text; an
   `annotate` list on every step), one thrust arrow per thrust unit shown with
   both ends on that unit and no text (one label names them), force arrows
   that start outside the body, a steering pose with the arms unequal and
   "schematic" in the text, facts beyond the engine (a figure, date, product
   name or version, load share) only from the fact table, in an unchecked label
   or a noted table row whose text or note starts with its row id ("F3
   <publisher> <year>") in the row's wording (UNKNOWN only as "not published"),
   and no share or comparison without a row, a `{fact}` or a hedge. Each inside
   label is anchored on the named inner part, not on the casing or body, and an
   inside whose real parts are not public is labelled "<class>-style <kind>
   (example)" with "Not confirmed <brand> hardware". The same general honesty rules apply to
   every subject: a load share is quoted with its source, never invented; no
   performance figure is derived from the simple model; the product version and
   years are named; an inside whose real parts are not public is labelled on
   screen as a schematic example, not confirmed hardware; the physics words are
   exact (a hover balances the upward parts of the thrusts against the weight,
   and the side forces and turning moments; fuel burns with the oxygen in the
   compressed air; thrust is the reaction to the gas accelerated out of the
   nozzle); and the part that really moves is named. The engine has no per-step
   pose at the pin, so a pose holds for every step. Small jet engines use the
   `microTurbojet` component (11 parts; five and a mannequin fit the 96-part
   limit; `cutaway` opens one), named as a schematic example. The guide also
   names the engine limits of the pin: `highlight` counts every part of a
   component toward 16 ids (so it highlights `<id>.casing`), a spin arrow is
   drawn at the whole model's size, explode on a component needs `explode` on
   its inner parts, and a pose and what is shown hold for every step. The prompts hold no
   subject-specific facts. Each label or arrow is
   defined once, and every defined id is in some step's `annotate` list (strict
   refuses an unlisted one, `annotation.unused`). In an explainer the table is
   added by a beat command in the first beat that needs it, and a later beat may
   remove it (the engine's legend keeps what the learner was shown). When the plan chose the
   explainer form, the author prompt also gets the explainer section and a small
   accepted explainer (a table with a noted given number, which shows as Given,
   beside the 3D model); other prompts stay smaller. It gets a short format guide, the `explain` entries of the
   chosen ids (components without their full definitions) and one small
   accepted example. It answers with `{"document": ..., "components": [...]}`.
3. **Check.** The engine checks the document in its strict profile (also
   refuses idle joints and turn axes that miss their part). An accepted
   document gets a `ref`. Then Marty lints it: a step or beat that shows more
   than 5 texts (labels, dimensions and arrows with text; an arrow without text
   does not count), and a sentence in a say or an annotation text that compares
   sizes or shares (most, all of, more than) with no hedge, no `{fact}`
   placeholder and no given figure (each listed id counts once, as the engine
   shows it), and a given figure (an unchecked label or arrow, or a noted table
   row with a typed number, with a basis or an unchecked note) that merges two figures into one range (a span of
   years is fine) or names a source with no year (unless "reported" or "assumed
   example"). A lint problem asks for one repair at most (attempt reason
   `marty.lint`, `engineOk` true), when one is left. The engine-accepted
   document with the fewest findings is kept (a later one wins a tie), and it
   stands, with `lint` and `lintAttempt` in the receipt, when no attempt is
   clean.
4. **Repair.** A refused document goes back to the model with the exact reason,
   the part, and, for common reasons, a one-line fact that restates the engine
   rule (for example the centre-distance formula). A caption or claim refusal
   also gets the list of facts the engine solved for the model (when the
   refusal comes before the report, Marty checks the same document without its
   steps and with a plain title to get them). A frame, idle-joint or `expect`
   refusal also gets the engine's read-back (for `expect`, from the same
   document without its `expect` entries, also those in component `set` entries,
   and without its steps and with a plain title; component definitions are v1
   and cannot hold `expect`). A visibility refusal (`annotations.visible`,
   `step.annotate.count`, `view.annotate.count`) also gets the engine's
   visibility detail in words: which annotation, how many show, the limit, the
   cause and the step or beat; the attempt in the receipt keeps the detail
   (also in follow-up repairs). A `parts.resolved` refusal gets the engine's
   limit detail the same way (the resolved count, the limit and the component
   instances that add the most parts; attempt key `limit`). A `parts.count`
   refusal from component expansion has no detail at the pin and gets a hint. Only what the engine returned is
   attached; at most 80 facts and 48 read-back lines. At most 3 repairs. A
   follow-up patch refused for a caption or a claim gets the facts of the
   changed model (the same patch with steps cleared).
5. **Render** (with `--render`). Stills for every step, a snapshot and a
   manifest, through the engine renderer. It does not write `story.mp4`: use
   `marty-solid render` for the story video (its writer is not library API at
   the pin). A render that fails (for example
   with no Metal device) is recorded in the receipt; the checked lesson still
   stands.
6. **Teach.** The checked steps are the beats. `lesson.json` holds each beat's
   engine-filled text, its tier (the engine's `stepTiers`), its still, the
   engine facts and ratios, the legend line, the honesty note and a `sources`
   entry that says where each comes from. In a v2 document every number in a
   caption is an engine fact (rule N1), except a step marked `unchecked`; the
   words are the model's. Marty adds no number of its own.
7. **Follow-up** (with `--follow-up` or in `bench`). The model gets the checked
   document and the engine report, and answers with an engine patch (or `null`
   when nothing must change). The engine checks the patch, with at most 3
   repairs. The engine replaces a part field as a whole, so Marty merges a
   patch's `with` into the instance's current `with` first (only the asked
   parameter changes; `null` removes a parameter; a patch that also changes
   `use` to another component is not merged). A patch that changes only `title` and `steps` is refused
   (`followup.textOnly`): it would narrate a change that the engine never
   solved. Then the model writes a short answer from the engine reports before
   and after the change, the accepted change itself, and whether the solved
   ratios changed. The answer is model text and is marked so
   (`answerSource`). `modelled` says whether the engine solved the change (or
   none was needed). When the engine refused every change, the model still
   answers, with a separate system prompt: it says plainly that the model
   cannot show the what-if, gives no number beyond the report before and does
   no arithmetic. When no patch even reached the engine (only `json` or
   `followup.textOnly` problems), the prompt says "no change could be checked"
   instead of "the engine refused". An empty follow-up (the out-of-scope bench questions have
   none) means no follow-up turn. A what-if may move a part (a mannequin arm
   angle, a part's `rot`). A patch cannot change annotations: an arrow end on a
   part moves and turns with that part (and with the parts it hangs on), and an
   end at a world point stays where it is. The engine checks a gravity arrow
   again in the changed model. Marty lists the other force arrows that the
   accepted change may have moved (an end or `on` part on a changed part or on a
   part hung below one, where an edit of an inner part of a component moves
   the whole instance; every force arrow when params, constraints or joints
   changed) in `forceArrowsMoved`, and only then does the answer prompt ask the
   model to say that their direction is schematic. An explainer has no engine
   patch format, so its follow-up sends the whole changed explainer
   (`{"document": …}`, or `{"document": null}` for no change; any other value is
   repaired), which must stay an explainer (`followup.kind`) and is checked in
   strict mode (at most 3 repairs). A change of words only is refused as
   `followup.textOnly`: the model content compared is the solid (without its
   title and annotation text), the board keys other than its title (template,
   params and the rest), the board items other than text items, and the beats'
   model ops in order (an absent or empty `ops` adds nothing; `title` and
   `camera` ops, ops on text items, sets of a `text` or `label` key, and the
   `label` and `text` of an item are words). The answer prompt gets the accepted change with values before and
   after: the solid parts, the other solid keys, the board keys and items and the beat
   ops that changed. A modelled answer also gets the document's given figures
   (unchecked labels and arrows, and rows of noted explainer tables, with their
   source; a table whose cells a later beat sets is listed again, marked with
   that beat, after any header change; at most 12); a refused answer does not.
   Numbers from the structured values keep their short text (integers exactly,
   a float as its shortest round-trip text with any exponent written out), and
   matching ignores thousands commas and trailing decimal zeros. The answer prompt says that a
   claim about sizes, shares or comparisons must come from a given figure or an
   engine number, or be hedged. A sentence with "most", "the majority", "all
   of", "more than" or a similar word, with no hedge (about, in this schematic)
   and no number that is also in the evidence (the given figures shown, the
   engine fact texts and ratios, numbers set in the change; never raw JSON),
   gets one rewrite request; `answerLint` records the sentences and whether the
   rewrite cleared them. A rewrite that fails in the adapter keeps the first
   answer (`fixed` false). In
   an explainer, a force arrow whose direction the model
   sets may be marked `unchecked: "schematic direction"`; an arrow whose
   definition changed is listed in `forceArrowsMoved`.

Model text is only parsed as JSON and given to the engine. It is never run.

## Exit codes

`marty ask`: 0 accepted, 1 not accepted, 2 usage, setup or a run that threw
(for example the `claude` command is missing; then there is no receipt), 3 a
model call failed in the adapter (the output line lists `adapterErrors`).
`marty bench`: 0, or 1 when any row is an error row (a missing `claude` command
is an error row too; see bench/README.md); 2 for usage or setup errors before
the first question, or a summary that could not be written.

## Model adapters

| Adapter | Use |
| --- | --- |
| `claude-cli:<model>` | The local Claude Code CLI in print mode (`claude -p`), with the account that is logged in there. Every call is a new process in a new empty directory, with no tools (the research call: only the built-in WebSearch and WebFetch, allowed without a prompt, WebFetch denied on the blocked domains, `--max-turns`), no MCP servers, no slash commands, no user/project/local settings (so no hooks or plugins) and no session persistence. The child gets only an allowlist of variables: HOME, PATH, USER, LOGNAME, TMPDIR, the locale, the subscription login (`CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CONFIG_DIR`), proxies and CA certificates. No `ANTHROPIC_*` variable passes, so an exported `ANTHROPIC_API_KEY` is never used. Managed (administrator) settings still apply. The prompt goes in on standard input. The timeout (default 900 s) is on the child's exit. After it: SIGTERM, then SIGKILL after 5 s if the child still runs, then up to 5 s more for it to exit (at most timeout + 10 s in all). After a normal exit, Marty waits at most 5 s for the pipes to close and then uses what it read (a pipe that a grandchild keeps open is abandoned). The CLI adds its own fixed context: about 640 tokens in a probe on 2026-11-06. That figure, and that no CLAUDE.md or memory loads in the empty working directory, rest on that measurement, not on a documented guarantee. |
| `scripted` | Replays fixed replies (and, when given, fixed research replies). For tests, and to replay a recorded run. |

An adapter is one function: system prompt and user message in, text out. Other
models (an open-weight model, a future small Marty model) need only a new
adapter.

## Context size

The receipt records `contextBytes` for the plan and author prompts, and the
size and SHA-256 of every prompt. Tests fail when the plan prompt grows over
12,000 bytes or the author prompt over 13,000 bytes (the author prompt without component
entries: 12,000 bytes, and 14,500 bytes with the explainer form). For comparison, the
v1 eval harness sent about 25,600 bytes of engine docs in every call.

## Run receipt (`marty.run-receipt/v1`)

One `receipt.json` per run, with sorted keys:

| Key | Content |
| --- | --- |
| `format`, `prompts`, `model`, `engine` | Versions: receipt format, prompt set, adapter id, engine repository and commit. |
| `question`, `options`, `startedAt` | The input, the options (repairs, render, size) and the UTC start time. |
| `research` | The research phase: `ok`, `reason` when it failed (`research.unavailable`, `research.json`, an adapter reason), `needed`, the fact table `rows`, `downgrades`, `turns`, `webTools`, `maxTurns` and `blockedDomains`. |
| `plan` | The plan reply, the chosen ids and the dropped ids; `lint` when a flight question first had no thrust in `given`. |
| `attempts` | One entry per author or repair attempt: `ok`, `reason`, `part`, `ref`, `component`. |
| `accepted`, `final` | Whether a document was accepted, and its title, part ids, ratios, checks, `ref`, triangles and steps. |
| `render`, `lesson` | Render `ok`, `reason` (when it failed), directory, file digests and timing; `lesson.json`. |
| `adapterErrors` | Reasons of model calls that failed in the adapter (for example `adapter.timeout`). Present only when one failed. If the last plan call fails in the adapter (no plan was received), the run stops there. |
| `followUp` | The question, its attempts, `changed` (the engine accepted a patch), `modelled` (the engine solved the change, or none was needed), `ratiosChanged`, `forceArrowsMoved` (force arrows that the accepted change may have moved; their shown direction is schematic), the report after the change, the answer, `answerLint` (when a comparison without a figure was sent back once) and `answerSource`. `ok` means an answer was written: also an honest "this model cannot show it" when `modelled` is false. `ok` is false when no answer was written (for example an adapter failure). |
| `calls` | Every model call: phase, attempt, prompt files with sizes and digests, reply file, seconds, adapter facts (tokens, cost equivalent) and the engine outcome. |
| `seconds`, `modelSeconds`, `contextBytes` | Wall time, model time and prompt sizes. |

The prompts and replies are files in `calls/` next to the receipt. A run
directory can hold model text. Do not publish it unless it was reviewed.
