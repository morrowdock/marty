# Test fixtures

These five documents are copied unchanged from the MartyGraphics example models at the
pinned engine commit `76104deae44a186ccf29a43db9e091f088f12103`
(`Examples/Solid3D/Sources/MartySolid3D/Models/`), Apache-2.0, original synthetic
teaching models.

`lessons/rotation.lesson.json` and `lessons/rotation.statements.ndjson` are copied unchanged
from the engine's `docs/fixtures/v1/` at 31a47ba141a208eaf76b38fc9df5cecc7703487e (Apache-2.0,
original synthetic lesson).

The solid engine did not change between 76104dea and the current pin 31a47ba (PR #20 touched
only the lesson and 2D files), so these golden files still apply.

`cli-76104dea/*.check.json` is the output of the engine's own `marty-solid check`
at the same commit (binary sha256 `7b5a4491b35f154b...`) for each model.
`testReportMatchesTheEngineCLI` compares Marty's `check` report with it field by
field (numbers within 1e-9 relative).
