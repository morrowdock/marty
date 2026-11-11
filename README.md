# Marty

Marty turns a learning question into a checked 3D lesson. A model plans the
lesson and writes it as [MartyGraphics](https://github.com/morrowdock/martygraphics)
JSON; the engine checks it and refuses a wrong one with an exact reason; the
model repairs it. With `--render`, Marty renders stills of a checked assembly;
explainer lessons (stills and story video) are rendered with MartyGraphics'
`marty-solid render`.

**Status: early preview.** Interfaces and formats can change. Do not depend on
them yet. The first tagged release is [v0.2.0](CHANGELOG.md), the version that `marty-mcp --version` reports.

## Real output: one question, three tries, one checked lesson

<p align="center">
  <a href="https://github.com/morrowdock/martygraphics/blob/933db57c6beb9863f543c4519d35ece84952ebb3/docs/assets/jet-suit-ai/story.mp4"><img src="https://raw.githubusercontent.com/morrowdock/martygraphics/933db57c6beb9863f543c4519d35ece84952ebb3/docs/assets/jet-suit-ai/poster.png" width="640" alt="AI-written lesson, beat 2: a grey schematic pilot with two gold engines on each forearm and one on the back, a yellow up arrow on each engine and a down arrow labelled Weight of pilot, suit and fuel."></a>
</p>

**Asked: "How does the Gravity jet suit work?"** One `marty ask` run with
Claude Opus 5.5 and web research on (run `r2j-opus-1`, 2026-11-09, Marty
`f2d7c5a`, engine `dfc521a`). The lesson is shown **unedited**.

| Try | Engine result |
| --- | --- |
| 1, author | Refused: `text.number.beat.1`. Beat 1 said "the newer **Mk4**"; the strict text rule counts the "4" as a number that the engine did not check. |
| 2, repair 1 | Marty applied 4 of the engine's own checked suggestions, then the engine refused `annotation.anchor.hidden.lShaft`: a shaft label was hidden behind the combustor. |
| 3, repair 2 | **Accepted** by `marty-solid check --strict`. `marty-solid render` (MartyGraphics `dfc521a`) then rendered 9 beats and a 78-second story video. |

**What is wrong with it.** An independent fact check by two AI models with
web access found **1 wrong sentence and 12 corrections**. The wrong sentence
says the hot gas spins the turbine "at 1 turn per input turn". The engine
solved only the 1:1 shaft link, not the gas flow; it does not check what a
sentence means. **How often it works.** The same question ran 4 times: 3
lessons were accepted and 1 of 4 (this one) met our showcase bar.

[Prompt and every try](https://github.com/morrowdock/martygraphics/blob/933db57c6beb9863f543c4519d35ece84952ebb3/docs/assets/jet-suit-ai/PROMPT.md) ·
[Fact check](https://github.com/morrowdock/martygraphics/blob/933db57c6beb9863f543c4519d35ece84952ebb3/docs/assets/jet-suit-ai/FACT-CHECK.md) ·
[Story video (MP4)](https://github.com/morrowdock/martygraphics/blob/933db57c6beb9863f543c4519d35ece84952ebb3/docs/assets/jet-suit-ai/story.mp4) ·
[Lesson JSON](https://github.com/morrowdock/martygraphics/blob/933db57c6beb9863f543c4519d35ece84952ebb3/docs/assets/jet-suit-ai/lesson.json) ·
[Render receipt](https://github.com/morrowdock/martygraphics/blob/933db57c6beb9863f543c4519d35ece84952ebb3/docs/assets/jet-suit-ai/provenance.json)

## What Marty does

The MCP server and the reference loop work (early preview). The
[development bench](bench/README.md) is used to improve Marty, so its results
are not held-out evidence.

You ask a learning question, for example "How does a planetary gearbox
reduce speed?". Marty will then:

1. Plan a short lesson.
2. Find parts in the MartyGraphics component library.
3. Write a 3D scene document (and define a missing component when it must).
4. Ask the engine to check the scene. The engine solves the motion, checks
   every number and refuses a wrong scene with an exact reason.
5. Repair the scene from those reasons (at most 3 times).
6. Render the scene and teach it beat by beat.
7. Answer follow-up questions, such as "What if the sun gear had more teeth?".

Before the plan, a research step (on by default) builds a small fact table
from web search, and Marty checks each cited quote on the page itself
([details](docs/LOOP.md)).

The engine is the source of truth. It never guesses. Marty is the teacher on
top of it. The aim is that any model (Claude, GPT, Gemini or a small local
model) can drive Marty, because correctness comes from the engine and not from
the model. This is not tested yet.

## Parts of this repository

| Part | Status |
| --- | --- |
| MCP server (`marty-mcp`): engine tools for any MCP client | Early preview: `catalog`, `explain`, `check`, `component_check`, `patch`, `render`, `lesson_check`, `lesson_stream` ([setup](docs/MCP-CLIENTS.md)) |
| Marty loop (`marty ask`, `marty bench`): plan, author, check, repair, render, teach, follow-up ([docs](docs/LOOP.md)) | Early preview |
| Bench: the 50-question development set ([bench](bench/README.md)) | Early preview |

The design of the MCP tool set is in [docs/DESIGN-MCP.md](docs/DESIGN-MCP.md).

## Try it

```sh
git clone https://github.com/morrowdock/marty.git
cd marty
swift build -c release
B="$(swift build -c release --show-bin-path)"
"$B/marty" ask "How does a planetary gearbox reduce speed?" --out NEW_DIR --model claude-haiku-5-5
```

`marty ask` writes the checked lesson JSON and a run receipt into `NEW_DIR`.
`--render` adds stills for an assembly only; Marty refuses to render an explainer
(`render.explainer`). For explainer stills and the story video, run `marty-solid
render` from
[MartyGraphics](https://github.com/morrowdock/martygraphics/blob/main/Examples/Solid3D/README.md)
on the lesson. `marty ask` uses the local Claude Code CLI (`claude -p`) and the
account that is logged in there; it needs no API key. To use the engine tools from your own
MCP client instead, see [docs/MCP-CLIENTS.md](docs/MCP-CLIENTS.md).

## Requirements

- macOS 14 or later, Swift 6 (Xcode 16 or later).
- No API key or paid service is necessary. After SwiftPM fetches the
  dependencies, build and test need no network access.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Every commit needs a DCO sign-off.
Report security problems as [SECURITY.md](SECURITY.md) tells you.

## How it was made

AI agents (mainly Claude Opus 5.5) wrote this code and its docs under the
direction of Collin Craig. Changes land through pull requests that must pass
CI, with independent reviews by other AI models. The
jet-suit fact check is an AI model check, not a review by an engineer.

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE). The names
Morrowdock and Marty and the logos are not licensed; see
[TRADEMARKS.md](TRADEMARKS.md).
