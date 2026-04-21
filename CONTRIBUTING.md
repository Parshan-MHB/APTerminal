# Contributing

## Workflow

1. If you are an external contributor, work from a fork and open a pull request back to `main`.
2. If you are a maintainer, create a focused feature branch from `main`.
3. Keep changes scoped to one concern.
4. Regenerate the Xcode project when target or project settings change.
5. Run the strongest local verification you can before opening a PR.
6. Open a pull request into `main`.
7. Merge only after required CI is green.
8. Merge with squash merge so each PR lands as one commit on `main`.

Direct pushes to `main` are not part of this repo workflow. The `main` branch is protected and changes should land through pull requests, including maintainers' own changes.
`main` also enforces linear history, so merge commits and rebase merges are not part of the repo workflow.

## Access Model

- External contributors should use forks.
- Maintainers should use feature branches in the main repository.
- Do not grant write access to casual contributors. Without write access, GitHub already forces the fork-and-PR model in practice because contributors cannot create branches in the upstream repository.
- Anyone with write, maintain, or admin access can still create branches in the main repository. GitHub does not provide a clean repository-level switch that says "contributors must fork, but maintainers may branch here." The practical control is repo permissions.

Suggested branch naming for maintainer branches:

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
