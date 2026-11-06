# The Marty loop (reference agent)

Status: early preview, 2026-11-06. Prompts `marty-prompts/1`. Engine pin as in
`Package.swift`.

`marty ask` and `marty bench` run one reference agent on the engine. The
agent works in the same process as the engine (`MartyEngine`, the same code that
the MCP server uses), so a run needs no MCP client.

## Steps

1. **Plan.** The model gets the question and the compact engine catalog. It
   answers with a JSON plan: whether the subject is in scope, 2 to 6 teaching
   beats, the component and primitive ids that it wants, and what the model
   cannot show (`honesty`). The loop keeps at most 6 ids that the catalog knows
   and records the ids it dropped.
2. **Author.** The model gets a short format guide, the `explain` entries of the
   chosen ids (components without their full definitions) and one small
   accepted example. It answers with `{"document": ..., "components": [...]}`.
3. **Check.** The engine checks the document. An accepted document gets a `ref`.
4. **Repair.** A refused document goes back to the model with the exact reason,
   the part, and, for common reasons, a one-line fact that restates the engine
   rule (for example the centre-distance formula). At most 3 repairs.
5. **Render** (with `--render`). Stills for every step, a snapshot and a
   manifest, through the engine renderer.
6. **Teach.** The checked steps are the beats. `lesson.json` holds each beat's
   text, its still, the solved ratios and the honesty note. Marty adds no
   number to the lesson that the engine did not report.
7. **Follow-up** (with `--follow-up` or in `bench`). The model gets the checked
   document and the engine report, and answers with an engine patch (or `null`
   when nothing must change). The engine checks the patch, with at most 3
   repairs. Then the model writes a short answer from the engine reports before
   and after the change.

Model text is only parsed as JSON and given to the engine. It is never run.

## Model adapters

| Adapter | Use |
| --- | --- |
| `claude-cli:<model>` | The local Claude Code CLI in print mode (`claude -p`), with the account that is logged in there. Every call is a new process in a new empty directory, with no tools, no MCP servers, no slash commands and no session persistence. The prompt goes in on standard input. |
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
| `render`, `lesson` | Render directory and file digests; `lesson.json`. |
| `followUp` | The question, its attempts, whether the model changed, the report after the change and the answer. |
| `calls` | Every model call: phase, attempt, prompt files with sizes and digests, reply file, seconds, adapter facts (tokens, cost equivalent) and the engine outcome. |
| `seconds`, `modelSeconds`, `contextBytes` | Wall time, model time and prompt sizes. |

The prompts and replies are files in `calls/` next to the receipt. A run
directory can hold model text. Do not publish it unless it was reviewed.
