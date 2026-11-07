# Prompt -> 3D eval v1: protocol amendment 3

Date: 2026-11-06 (folder dates 2026-11-07). Status: in force from this date. questions.json is unchanged (sha256 81ba1f73...).

1. **Publication of results.** A recorded result may be published in the public README, docs/SHOWCASE.md and the website as a "From a prompt" example. The publication shows the exact prompt, the model id, every attempt with its exact refusal reason, the wall time, the engine commit and checker binary hashes, and the independent grader's verdict.
2. **Published questions leave the held-out set.** Engine builders read the README. After a question's prompt is published, results for it in later rounds are reported separately as "published" and are not counted in held-out totals. Published so far: Q14 (2026-11-06).
3. **Readable copy.** A published JSON may also be shown re-wrapped (one part per line) for reading. The re-wrapped copy must parse to the identical JSON value as the model's bytes, must pass the same checker with the same report, and both sha256 values are recorded. The renders may come from the readable copy.
4. **Grading before publication.** Only results that an independent grader marked PASS on mechanics, explanation and honesty may be published.
