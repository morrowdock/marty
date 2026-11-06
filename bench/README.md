# Bench

Questions for measuring how well a model, driving Marty, turns a learning question
into a checked 3D lesson.

## dev-v1: development set

[`dev-v1/questions.json`](dev-v1/questions.json) holds the 50 questions of the
MartyGraphics "prompt-to-3D eval v1", copied byte for byte.

- SHA-256: `81ba1f737484374defe94a4108dbf9194c4c3559954e468b459f7b75adc9e433`
- 40 in-scope questions (gear trains, planetary sets, slider-cranks, rotors and
  blades, turbomachinery, machines) and 10 out-of-scope questions. For an
  out-of-scope question, the expected answer is an honest refusal or a clearly
  labelled schematic.
- Each question has a follow-up (a what-if change) and the machine checks that a
  correct model must pass.

**This is a development set, not held-out evidence.** It was pre-registered
before the engine work. Its results have been used to change the engine, the
docs and the prompts, and they will continue to be used that way. The file's own
`status` field still says "held out" because the bytes are unchanged; this
README replaces that status. Results on this set do not show how Marty does on
questions it has not seen. Held-out sets are kept private and are never
published here.

The protocol amendments of the original eval are copied unchanged:
[amendment 1](dev-v1/PROTOCOL-AMENDMENT-1.md),
[amendment 2](dev-v1/PROTOCOL-AMENDMENT-2.md),
[amendment 3](dev-v1/PROTOCOL-AMENDMENT-3.md). They contain no answers.

## Protocol (Marty loop)

- A fresh model process per question, in an empty working directory, with no
  tools. The context is only what the Marty loop sends (the receipt records the
  size and SHA-256 of every prompt).
- Plan, author, check with the engine, at most 3 repairs from the exact refusal
  reason, then the follow-up as an engine patch.
- Record everything: one receipt per question (`marty.run-receipt/v1`) and a
  summary with the questions' SHA-256 and the engine commit.

```sh
swift build -c release
B="$(swift build -c release --show-bin-path)"
"$B/marty" bench bench/dev-v1/questions.json --out NEW_DIR --model claude-haiku-5-5 --ids Q01,Q09
```

The `claude-cli` adapter uses the local Claude Code CLI (`claude -p`) and the
account that is logged in there. It needs no API key.

## What is published

The machine summary (accepted, attempts, reasons, time) is a fact of the run.
Model answers, grades and renders are published only when an independent
grader marked them PASS on mechanics, explanation and honesty (amendment 3).
