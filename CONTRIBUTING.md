# Contributing

Small bug reports and focused pull requests are welcome during this early preview.

## Before you open a pull request

- Explain the behavior and give a synthetic reproduction.
- Run `swift build` and `swift test` on macOS. Tell us if you could not run them.
- Use only original, synthetic examples and questions.
- Do not submit personal data, learner data, private course material,
  credentials, API keys or private model prompts.
- Changes to the engine itself go to
  [MartyGraphics](https://github.com/morrowdock/martygraphics), not here.

## DCO sign-off

Every commit must include a Developer Certificate of Origin sign-off. By
signing, you certify the
[Developer Certificate of Origin 1.1](https://developercertificate.org/).

```sh
git commit -s
```

Use an email address you are comfortable publishing. A GitHub noreply address
is recommended. A sign-off is a certification, not a cryptographic signature.
CI refuses a pull request that has a commit without a sign-off.

## How changes land

- All changes go to `main` through pull requests.
- CI (build, test and the sign-off check) must pass. A repository rule on
  `main` enforces this.
- Pull requests are squash-merged. The squash commit keeps the commit
  messages, so the sign-off lines stay in the commit on `main`.

Follow [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). Report vulnerabilities as
[SECURITY.md](SECURITY.md) tells you.
