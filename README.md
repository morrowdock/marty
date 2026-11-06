# Marty

Marty is an AI teacher built on the
[MartyGraphics](https://github.com/morrowdock/martygraphics) engine.

**Status: early preview.** Interfaces and formats can change. Do not depend on
them yet.

## Goal

None of this works yet. This is what Marty is being built to do.

You ask a learning question, for example "How does a planetary gearbox
reduce speed?". Marty will then:

1. Plans a short lesson.
2. Finds parts in the MartyGraphics component library.
3. Writes a 3D scene document (and defines a missing component when it must).
4. Asks the engine to check the scene. The engine solves the motion, checks
   every number and refuses a wrong scene with an exact reason.
5. Repairs the scene from those reasons (at most 3 times).
6. Renders the scene and teaches it beat by beat.
7. Answers follow-up questions, such as "What if the sun gear had more teeth?".

The engine is the source of truth. It never guesses. Marty is the teacher on
top of it. The aim is that any model (Claude, GPT, Gemini or a small local
model) can drive Marty, because correctness comes from the engine and not from
the model. This is not tested yet.

## Parts of this repository

| Part | Status |
| --- | --- |
| MCP server (`marty-mcp`): engine tools for any MCP client | Designed ([docs/DESIGN-MCP.md](docs/DESIGN-MCP.md)) |
| Marty loop: plan, author, check, repair, render, teach | Planned |
| Bench: development questions for prompt-to-3D lessons | Planned |

The design of the MCP tool set is in [docs/DESIGN-MCP.md](docs/DESIGN-MCP.md).

## Requirements

- macOS 14 or later, Swift 6 (Xcode 16 or later).
- No API key or paid service is necessary. After SwiftPM fetches the
  dependencies, build and test need no network access.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Every commit needs a DCO sign-off.
Report security problems as [SECURITY.md](SECURITY.md) tells you.

## License

Apache License 2.0. See [LICENSE](LICENSE).
