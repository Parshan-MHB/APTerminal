# APTerminal

[![CI](https://github.com/Parshan-MHB/APTerminal/actions/workflows/ci.yml/badge.svg?branch=main&event=push)](https://github.com/Parshan-MHB/APTerminal/actions/workflows/ci.yml?query=branch%3Amain)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/tag/Parshan-MHB/APTerminal?label=release)](https://github.com/Parshan-MHB/APTerminal/releases/latest)
[![Swift](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://www.swift.org/)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%2017%20%7C%20macOS%2014-blue.svg)](docs/technical-spec.md)

https://github.com/user-attachments/assets/677d928c-bf23-4248-a61d-968aa0a5be91

Secure, local-first terminal access from iPhone to Mac.

APTerminal is a two-app system:

- A macOS companion app that owns and manages terminal sessions.
- An iPhone app that discovers the Mac on the local network or connects through the supported private-overlay path and interacts with those sessions securely.

## Product Goal

Use an iPhone to:

- See multiple terminal sessions running on a Mac
- Switch between them quickly
- Type and interact with them with low latency
- Keep the security model tight enough that this does not turn into an unsafe remote shell product

## V1 Scope

V1 includes:

- PTY-managed shell sessions created by the Mac app
- Local network discovery with Bonjour
- Private internet access through Tailscale or another private overlay
- Encrypted device-to-device connection
- QR-based pairing
- Face ID / passcode lock on iPhone
- Session list and active terminal interaction
- Copy/paste and basic terminal controls

V1 excludes:

- Public raw internet exposure of the host listener
- Cloud relay
- Automatic control of arbitrary Terminal or iTerm windows
- Broad macOS permissions such as Accessibility and Screen Recording

## Repo Layout

- `apps/mac-companion/` macOS app
- `apps/ios-client/` iPhone app
- `shared/protocol/` shared message and protocol definitions
- `docs/` architecture, security, and delivery planning

## Common Commands

From the repo root:

```bash
make generate
make test
make build-mac
make package-mac-app
make build-ios
```

The Xcode project is generated and is not intended to be hand-edited or committed as source of truth.
After cloning the repo, run `make generate` before opening the project in Xcode.

## Quick Start

```bash
make generate
make test
make package-mac-app
```

Then:

1. Open `dist/APTerminal.app` on the Mac.
2. Build and run `iOSClient` from Xcode on a real iPhone.
3. Pair with the QR/bootstrap payload from the Mac app.

## Run The Mac App

Build a normal macOS app bundle without opening Xcode:

```bash
make package-mac-app
```

That creates:

```bash
dist/APTerminal.app
```

You can open that app from Finder. The macOS app is the host controller:

- when `APTerminal.app` is open, you can start or stop the host from the app
- `Security` shows the pairing payload, connection mode, endpoint, and recent audit events
- `Sessions` shows managed sessions and any separately enabled external previews once a paired device has preview privilege
- `Devices` is where preview privilege is granted or revoked per paired iPhone
- quitting the app stops the host

## Build Principles

- Local-first
- Secure-by-default
- Minimal permissions
- No APTerminal cloud relay in V1
- No public raw listener exposure
- PTY-native instead of pixel-streaming

## Current Status

The current codebase already includes:

- managed PTY sessions on macOS
- LAN and private-overlay connection modes
- encrypted device-to-device transport after `hello`
- trusted-device pairing, reconnect authentication, and revocation
- preview privilege controls for managed previews and external Terminal/iTerm previews

The remaining work is mainly:

1. real-device Mac and iPhone validation
2. release hardening and operational testing
3. any future optional work beyond the current private-overlay model

Core docs:

- [technical handbook](docs/technical-spec.md)
- [connection and security flow diagrams](docs/connection-security-diagram.md)
- [preview validation checklist](docs/preview-security-validation-checklist.md)
- [protocol v1](shared/protocol/Docs/protocol-v1.md)

## Community

- [Contributing](CONTRIBUTING.md)
- [Security Policy](SECURITY.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)
- [License](LICENSE)
