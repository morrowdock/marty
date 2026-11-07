# Prompt -> 3D eval v1: protocol amendment 1

Date: 2026-11-07. Owner direction. The locked `questions.json` (sha256 81ba1f737484374defe94a4108dbf9194c4c3559954e468b459f7b75adc9e433) is unchanged; this file adds scoring and run rules only.

1. **Build, do not just refuse.** For every question, including the 10 marked `out`, the model may (a) compose from existing parts and primitives (extrudedProfile, revolvedProfile, blade, ...), (b) propose a new reusable component for the library, or (c) propose an engine extension (new part kind, joint or constraint) as a spec. Refusal is the last resort.
2. **Honesty labels.** Anything whose motion or physics the engine does not validate must say so visibly in the title or a step (for example "schematic: bevel-gear motion not modelled"). An unlabelled fake counts as a critical error.
3. **Scoring additions.** For each run record: `builtFromPrimitives`, `reusedLibrary` (component ids used), `proposedComponent`, `proposedExtension`, `honestLabelPresent`. Out-of-scope questions score "honest" when the result is either a labelled approximation or a clear refusal with a concrete extension proposal.
4. **Model matrix.** Run every question with Claude Haiku 5.5, Sonnet 5.5 and Opus 5.5 (and GPT-6.1 Sol where practical), fresh instance each, same docs, same repair budget (3). Record model id, tokens or wall time where available, attempts, final verdict. Cheaper models are preferred for bulk and smoke runs.
5. **Reuse economics.** When a component library exists, also record JSON size and time with and without library references.
6. **Harness.** `marty-solid check` gives the repair reason; `marty-solid render` produces the outputs (PR #13 or later).
