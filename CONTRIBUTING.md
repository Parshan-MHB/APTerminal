# Contributing

## Workflow

1. Create a focused feature branch from `main`.
2. Keep changes scoped to one concern.
3. Regenerate the Xcode project when target or project settings change.
4. Run the strongest local verification you can before opening a PR.
5. Open a pull request into `main`.
6. Merge only after required CI is green.
7. Merge with squash merge so each PR lands as one commit on `main`.

Direct pushes to `main` are not part of this repo workflow. The `main` branch is protected and changes should land through pull requests, including maintainers' own changes.
`main` also enforces linear history, so merge commits and rebase merges are not part of the repo workflow.

Suggested branch naming:

- `feature/<short-topic>`
- `fix/<short-topic>`
- `docs/<short-topic>`
- `refactor/<short-topic>`

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
- keep the PR focused enough to review cleanly
- do not open a PR until the branch is in a state that can pass required CI
- expect the PR to land with squash merge, not merge commit or rebase merge

## Before Opening A PR

- `make generate` if `project.yml` changed
- `make test`
- confirm the README and docs still match the implementation
- confirm the branch is not `main`
