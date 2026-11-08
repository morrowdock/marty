# The Marty loop (reference agent)

Status: early preview, 2026-11-06. Prompts `marty-prompts/6`. Engine pin as in
`Package.swift`.

`marty ask` and `marty bench` run one reference agent on the engine. The
agent works in the same process as the engine (`MartyEngine`, the same code that
the MCP server uses), so a run needs no MCP client.

## Steps

1. **Plan.** The model gets the question and the compact engine catalog. It
   plans the lesson in a fixed order: the whole system first (every main unit
   in its place and number, people or loads as schematic figures, and the
   forces as arrows), then the inside of the one part that makes it work, cut
   open, then what the model does not show. It answers with a JSON plan:
   A well-known headline figure of the subject (thrust against weight, power,
   top speed, range, capacity) goes in `given` with its source. The plan says
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
   where it really is, inside views cut or ghosted in place with `focus` on that
   step, at most 5 labels or arrows per step (an `annotate` list on every step),
   force arrows that start outside the body, and each given figure shown with
   its source. When the plan chose the
   explainer form, the author prompt also gets the explainer section and a small
   accepted explainer (a table with a noted given number, which shows as Given,
   beside the 3D model); other prompts stay smaller. It gets a short format guide, the `explain` entries of the
   chosen ids (components without their full definitions) and one small
   accepted example. It answers with `{"document": ..., "components": [...]}`.
3. **Check.** The engine checks the document in its strict profile (also
   refuses idle joints and turn axes that miss their part). An accepted
   document gets a `ref`.
4. **Repair.** A refused document goes back to the model with the exact reason,
   the part, and, for common reasons, a one-line fact that restates the engine
   rule (for example the centre-distance formula). A caption or claim refusal
   also gets the list of facts the engine solved for the model (when the
   refusal comes before the report, Marty checks the same document without its
   steps and with a plain title to get them). A frame, idle-joint or `expect`
   refusal also gets the engine's read-back (for `expect`, from the same
   document without its `expect` entries, also those in component `set` entries,
   and without its steps and with a plain title; component definitions are v1
   and cannot hold `expect`). Only what the engine returned is
   attached; at most 80 facts and 48 read-back lines. At most 3 repairs. A
   follow-up patch refused for a caption or a claim gets the facts of the
   changed model (the same patch with steps cleared).
5. **Render** (with `--render`). Stills for every step, a snapshot and a
   manifest, through the engine renderer. A render that fails (for example
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
   instead of "the engine refused". Prompt set `marty-prompts/2`. An empty follow-up (the out-of-scope bench questions have
   none) means no follow-up turn. A what-if may move a part (a mannequin arm
   angle, a part's `rot`); a force arrow whose new direction the model sets is
   marked `unchecked: "schematic direction"`. An explainer has no engine patch
   format, so its follow-up sends the whole changed explainer, which the engine
   checks in strict mode (at most 3 repairs); a change of words only (the same
   board and solid) is refused as `followup.textOnly`.

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
| `claude-cli:<model>` | The local Claude Code CLI in print mode (`claude -p`), with the account that is logged in there. Every call is a new process in a new empty directory, with no tools, no MCP servers, no slash commands, no user/project/local settings (so no hooks or plugins) and no session persistence. The child gets only an allowlist of variables: HOME, PATH, USER, LOGNAME, TMPDIR, the locale, the subscription login (`CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CONFIG_DIR`), proxies and CA certificates. No `ANTHROPIC_*` variable passes, so an exported `ANTHROPIC_API_KEY` is never used. Managed (administrator) settings still apply. The prompt goes in on standard input. The timeout (default 900 s) is on the child's exit. After it: SIGTERM, then SIGKILL after 5 s if the child still runs, then up to 5 s more for it to exit (at most timeout + 10 s in all). After a normal exit, Marty waits at most 5 s for the pipes to close and then uses what it read (a pipe that a grandchild keeps open is abandoned). The CLI adds its own fixed context: about 640 tokens in a probe on 2026-11-06. That figure, and that no CLAUDE.md or memory loads in the empty working directory, rest on that measurement, not on a documented guarantee. |
| `scripted` | Replays fixed replies. For tests, and to replay a recorded run. |

An adapter is one function: system prompt and user message in, text out. Other
models (an open-weight model, a future small Marty model) need only a new
adapter.

## Context size

The receipt records `contextBytes` for the plan and author prompts, and the
size and SHA-256 of every prompt. Tests fail when the plan prompt grows over
9,000 bytes or the author prompt over 12,000 bytes. For comparison, the
v1 eval harness sent about 25,600 bytes of engine docs in every call.

## Run receipt (`marty.run-receipt/v1`)

One `receipt.json` per run, with sorted keys:

| Key | Content |
| --- | --- |
| `format`, `prompts`, `model`, `engine` | Versions: receipt format, prompt set, adapter id, engine repository and commit. |
| `question`, `options`, `startedAt` | The input, the options (repairs, render, size) and the UTC start time. |
| `plan` | The plan reply, the chosen ids and the dropped ids. |
| `attempts` | One entry per author or repair attempt: `ok`, `reason`, `part`, `ref`, `component`. |
| `accepted`, `final` | Whether a document was accepted, and its title, part ids, ratios, checks, `ref`, triangles and steps. |
| `render`, `lesson` | Render `ok`, `reason` (when it failed), directory, file digests and timing; `lesson.json`. |
| `adapterErrors` | Reasons of model calls that failed in the adapter (for example `adapter.timeout`). Present only when one failed. If the last plan call fails in the adapter (no plan was received), the run stops there. |
| `followUp` | The question, its attempts, `changed` (the engine accepted a patch), `modelled` (the engine solved the change, or none was needed), `ratiosChanged`, the report after the change, the answer and `answerSource`. `ok` means an answer was written: also an honest "this model cannot show it" when `modelled` is false. `ok` is false when no answer was written (for example an adapter failure). |
| `calls` | Every model call: phase, attempt, prompt files with sizes and digests, reply file, seconds, adapter facts (tokens, cost equivalent) and the engine outcome. |
| `seconds`, `modelSeconds`, `contextBytes` | Wall time, model time and prompt sizes. |

The prompts and replies are files in `calls/` next to the receipt. A run
directory can hold model text. Do not publish it unless it was reviewed.
