# Test fixtures

These five documents are copied unchanged from the MartyGraphics example models
(`Examples/Solid3D/Sources/MartySolid3D/Models/`, unchanged from 76104dea through the current pin
d5f42c2e6124487d53f046171526d26d2128330d), Apache-2.0, original synthetic teaching models.

`lessons/rotation.lesson.json` and `lessons/rotation.statements.ndjson` are copied unchanged
from the engine's `docs/fixtures/v1/` at 31a47ba141a208eaf76b38fc9df5cecc7703487e (Apache-2.0,
original synthetic lesson).

Golden check reports are not copied: `testReportMatchesTheEngineCLI` reads the engine's own models
and its committed CLI golden files (`Examples/Solid3D/Tests/MartySolidCLITests/Golden`) from the
resolved package checkout at the pin, and compares Marty's `check` report (strict false and true)
with them field by field (numbers within 1e-9 relative).
