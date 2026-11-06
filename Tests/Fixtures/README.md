# Test fixtures

These five documents are copied unchanged from the MartyGraphics example models at the
pinned engine commit `76104deae44a186ccf29a43db9e091f088f12103`
(`Examples/Solid3D/Sources/MartySolid3D/Models/`), Apache-2.0, original synthetic
teaching models.

`cli-76104dea/*.check.json` is the output of the engine's own `marty-solid check`
at the same commit (binary sha256 `7b5a4491b35f154b...`) for each model.
`testReportMatchesTheEngineCLI` compares Marty's `check` report with it field by
field (numbers within 1e-9 relative).
