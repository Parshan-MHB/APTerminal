# Contributing

## Workflow

1. Fork the repo and create a focused branch.
2. Keep changes scoped to one concern.
3. Regenerate the Xcode project when target or project settings change.
4. Run the strongest local verification you can before opening a PR.

## Local Commands

```bash
make generate
make test
make build-mac
make package-mac-app
```

Use `make build-ios` when you need an iOS build check and your machine has the required simulator or device tooling.

## Engineering Expectations

- Keep security-sensitive behavior explicit.
- Do not add broad permissions casually.
- Keep terminal content out of logs and fixtures.
- Update docs when protocol, security, or repo workflow changes.
- Prefer small, reviewable commits over mixed refactors.

## Pull Requests

- explain the problem and the behavior change
- note any security or protocol impact
- include verification steps
- include screenshots for UI changes when relevant

## Before Opening A PR

- `make generate` if `project.yml` changed
- `make test`
- confirm the README and docs still match the implementation
