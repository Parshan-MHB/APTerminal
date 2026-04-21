# APTerminal Handbook

This document is the single primary reference for APTerminal.

Use it for:

- product scope
- architecture and boundaries
- security model
- protocol overview
- configuration
- development setup
- verification and release checks
- limitations and troubleshooting

The protocol-specific wire contract remains separate in:

- [shared/protocol/Docs/protocol-v1.md](../shared/protocol/Docs/protocol-v1.md)

The implementation-level connection walkthrough remains separate in:

- [connection-security-diagram.md](connection-security-diagram.md)

## Product Shape

APTerminal is a two-app system:

- `mac-companion`
  - owns PTY-backed terminal sessions
  - stores trust state
  - exposes the host listener
- `ios-client`
  - pairs with the Mac
  - lists sessions
  - renders terminal output and sends input
  - enforces local app locking on the phone

The product is intentionally terminal-native. It is not a general remote-access tool, cloud service, or screen-sharing system.

## Supported V1 Scope

V1 includes:

- managed PTY shell sessions created by the Mac app
- local discovery through Bonjour on LAN
- private internet connectivity through a private overlay such as Tailscale
- trusted-device pairing and revocation
- reconnect with proof-of-possession
- session create, list, attach, detach, rename, resize, and close
- iPhone app lock using Face ID or passcode
- paste guardrails and metadata-only audit logging

V1 excludes:

- direct public internet exposure of the raw host listener
- managed relay or cloud coordination service
- browser client
- Accessibility automation
- Screen Recording
- Full Disk Access as a product requirement
- transcript persistence by default
- arbitrary takeover of existing Terminal or iTerm windows

## Core Product Boundaries

Treat these as hard constraints unless the product scope changes intentionally:

- no public raw listener exposure
- no cloud relay in V1
- private-overlay remote access only
- PTY-managed sessions are the primary terminal model
- terminal content must not be written to audit logs
- broad macOS permissions stay out of scope

## Architecture

### Shared Code Strategy

- Use a root Swift package for protocol and shared modules.
- Keep the macOS and iPhone apps as native Apple targets under `apps/`.
- Keep SwiftUI and platform adapters outside the shared package.

### Main Modules

#### macOS Host Side

- `APTerminalPTY`
  - PTY allocation
  - child process lifecycle
  - terminal byte streams
- `APTerminalCore`
  - session management
  - host settings
  - logging and app-level coordination helpers
- `APTerminalSecurity`
  - pairing and trust stores
  - signing keys
  - audit storage
- `APTerminalTransport`
  - framed transport
  - buffer limits
  - connection lifecycle
- `APTerminalHost`
  - authenticated host runtime
  - request handling
  - rate limiting
  - launch policy enforcement

#### iPhone Side

- `APTerminalClient`
  - connection manager
  - trusted host registry
  - terminal rendering and input helpers
- `apps/ios-client`
  - app lock UX
  - pairing UX
  - session list and terminal presentation

### Application Structure Rules

- Keep domain logic out of SwiftUI views.
- Keep stateful coordination in services, actors, or app models.
- Keep session identity separate from transport connection identity.
- Keep control-plane messages separate from terminal byte streams.

## Connection Model

Two host modes are supported:

- `lan`
  - discovery: Bonjour
  - endpoint preference: private LAN addresses
- `internet-vpn`
  - transport path: Tailscale or another private overlay
  - discovery: no Bonjour advertisement
  - endpoint preference: explicit overlay-approved endpoint, then detected private-overlay address

Shared rules:

- transport uses `Network.framework`
- after `hello`, both peers establish an app-layer encrypted secure session before pairing, auth, session control, or terminal streaming
- every reconnect re-establishes the secure session and then requires a server challenge plus signed proof-of-possession
- the Mac host evaluates the selected connection mode, picks an approved bind endpoint, and refuses to start if that mode has no valid endpoint
- explicit internet endpoints are accepted only when they match an approved overlay address or trusted tailnet hostname
- the Mac security UI surfaces blocking exposure errors and public-address warnings from the same evaluation
- the host signing key is pinned from bootstrap and checked on later connections
- unauthenticated peers must not gain session metadata
- the host listener is not intended for direct public internet exposure

## Pairing And Trust Model

Pairing flow:

1. The Mac creates a short-lived pairing token.
2. The Mac generates a bootstrap payload containing endpoint metadata, host signing key, connection mode, endpoint kind, and expiry.
3. The iPhone scans the QR or imports the payload.
4. The iPhone generates a device signing keypair.
5. The peers establish an app-layer secure session anchored to the pinned host signing key.
6. The iPhone sends the signed pairing request inside that secure session.
7. The Mac validates token freshness and stores the trusted device record.
8. Future reconnects require secure-session re-establishment plus challenge-based proof-of-possession with the paired key.

Important trust rules:

- copied device IDs are insufficient
- stale or replayed proofs are rejected
- revoked trust requires explicit re-pairing
- trust records expire and must be surfaced clearly in both apps
- single-use bootstrap mode is supported
- preview privilege is separate from ordinary pairing trust and is stored per trusted device per connection mode
- preview privilege is granted and revoked locally on the Mac

## Session Model

Each managed session tracks:

- stable `SessionID`
- title
- shell path
- working directory
- rows and columns
- pid when available
- created time
- last activity time
- lifecycle state
- preview excerpt

Launch behavior is host-controlled:

- default launch path is the configured login shell
- remote clients cannot request arbitrary binaries unless explicitly allowed by host policy
- working directories are bounded by host policy
- remote session creation is audited

Preview behavior is separately controlled:

- authenticated devices always receive managed session metadata
- managed `previewExcerpt` content is returned only when the device has preview privilege for the current mode and the host allows managed content previews
- external Terminal or iTerm previews are listed and attachable only when:
  - the host has external previews enabled
  - the device has preview privilege for the current mode
- the Apple Events-backed external preview provider is activated when the host locally enables external previews; remote listing and attach still require preview privilege
- preview privilege is independent from ordinary connect or PTY session control

## Protocol Overview

The protocol is versioned from the start. The full contract lives in [protocol-v1.md](../shared/protocol/Docs/protocol-v1.md).

High-level message categories:

- connection and identity
  - `hello`
  - `secureSessionAccept`
  - `secureSessionReady`
  - `authChallengeRequest`
  - auth challenge and proof messages
- pairing
  - `pairRequest`
  - `pairResponse`
- session control
  - `listSessions`
  - `createSession`
  - `attachSession`
  - `detachSession`
  - `renameSession`
  - `closeSession`
  - `resizeSession`
- terminal data
  - input stream frames
  - output stream frames
- failures
  - structured protocol errors

Protocol rules:

- framing is explicit and deterministic
- malformed or oversized frames are rejected fail-closed
- secure-session frames use per-direction keys, integrity protection, and monotonic sequence enforcement
- plaintext `hello` carries only minimal identity material for secure-session setup; full host identity and mode metadata are delivered in encrypted `secureSessionReady`
- control messages remain typed and structured
- terminal byte streams remain separate from control messages
- protocol changes must update this handbook and the shared protocol doc

## Security Model

### Security Goals

Protect against:

- unauthorized peers on LAN
- unauthorized peers across an untrusted internet path
- replay of stale pairing artifacts
- replay of stale reconnect proofs
- excessive data retention
- accidental destructive input
- compromised trusted device causing broad host process launch

### Security Posture

The system is designed as:

- local-first
- least-privilege
- device-paired
- encrypted in transit
- low-retention by default
- private-overlay remote access only in V1

### Trusted Boundaries

Trusted:

- the user’s Mac
- explicitly paired iPhones
- Keychain-backed secret storage

Untrusted:

- other devices on the LAN
- other devices on the internet
- stale bootstrap artifacts
- stale auth challenges
- any raw public-internet path to the listener

### Main Risks And Controls

Unauthorized LAN or overlay connection:

- pairing gate
- trusted device registry
- reconnect proof-of-possession
- no anonymous session listing

Replay of pairing or reconnect material:

- short-lived bootstrap tokens
- single-use token behavior
- per-connection challenge nonces
- freshness window checks

Abusive peers:

- hard maximum inbound frame size
- hard maximum buffered undecoded bytes
- request rate limiting
- attach and create throttling

Transcript leakage:

- no transcript persistence by default
- no terminal content in audit logs
- only minimal preview state retained when needed
- preview content leaves the Mac only for devices with explicit preview privilege in the current mode

Compromised trusted device causing arbitrary launch:

- host-side launch allowlist and profiles
- login-shell default
- bounded working-directory policy
- audit logging for remote session creation

Broad permissions expanding blast radius:

- no Accessibility in V1
- no Screen Recording in V1
- no Full Disk Access requirement in V1

### Allowed Audit Events

- device paired
- device revoked
- preview access granted
- preview access revoked
- preview access denied
- preview access used
- connection accepted or denied
- auth challenge issued
- auth proof accepted or rejected
- session attached or detached
- remote session created
- external preview enabled or disabled
- external preview attached

Disallowed by default:

- full command history
- full terminal output
- environment dumps
- secrets
- copied clipboard payloads

## Permissions

### macOS App

Allowed in V1:

- local network usage
- Bonjour service declaration
- standard user process execution for managed shell sessions

Not allowed in V1:

- Screen Recording
- Accessibility
- Full Disk Access as a product requirement

### iPhone App

Allowed in V1:

- local network usage
- Bonjour service declaration
- camera for QR pairing
- LocalAuthentication for app lock

Not allowed in V1:

- microphone
- photo library access by default
- push notification dependency
- background remote-execution entitlement model

## Configuration

Configuration is split into:

- compile-time operational defaults in [APTerminalConfiguration.swift](../Sources/APTerminalProtocol/APTerminalConfiguration.swift)
- mutable host settings in `~/Library/Application Support/APTerminal/host-settings.json`

Current host settings schema:

```json
{
  "hostDeviceID": "optional-stable-device-id",
  "hostPort": 61197,
  "connectionMode": "lan",
  "explicitInternetHost": null,
  "idleLockTimeoutSeconds": 300,
  "allowViewOnlyMode": true,
  "lanPairingTokenLifetimeSeconds": 86400,
  "internetPairingTokenLifetimeSeconds": 1800,
  "singleUseBootstrapPayloads": true,
  "allowExternalTerminalPreviews": true,
  "allowManagedSessionContentPreviews": true,
  "sessionLaunchProfiles": [],
  "allowedWorkingDirectories": [],
  "displayedAuditEventLimit": 100,
  "pasteGuardPolicy": {
    "maximumPlaintextLength": 2048,
    "multilineLineThreshold": 4,
    "escapeSequenceWarningEnabled": true
  },
  "transport": {
    "heartbeatIntervalSeconds": 15,
    "idleTimeoutSeconds": 45,
    "maximumPendingTerminalBytes": 8388608,
    "maximumInboundFrameBytes": 1048576,
    "maximumBufferedInboundBytes": 2097152
  },
  "externalPreview": {
    "chunkBytes": 4096,
    "snapshotBytes": 262144,
    "snapshotLines": 4000,
    "refreshIntervalMilliseconds": 400
  }
}
```

Configuration notes:

- `connectionMode` is `lan` or `internet-vpn`
- `explicitInternetHost` is optional and overrides detected overlay selection only when it is an approved overlay endpoint
- older settings using `pairingTokenLifetimeSeconds` are read as a backward-compatible LAN lifetime
- external previews default to enabled on LAN and disabled in internet mode unless explicitly overridden
- managed session content previews can be disabled independently from external Terminal or iTerm previews

Other managed paths:

- `~/Library/Application Support/APTerminal/trusted-hosts.json`
- `~/Library/Application Support/APTerminal/audit.log`

## Development Setup

Requirements:

- Apple Silicon Mac
- macOS 14 or newer
- Xcode 17 or newer
- Swift 6 toolchain
- full Xcode installation for app targets and SwiftPM test execution

Recommended environment:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -version
swift test
```

The native Xcode project is generated from [project.yml](../project.yml).

After cloning the repo, run `make generate` before opening the project in Xcode.

Regenerate after target or dependency changes:

```sh
xcodegen generate
```

Common local commands:

```sh
make generate
make build-package
make test
make build-mac
make package-mac-app
make build-ios
make build-all
```

Preview hardening release validation is tracked in:

- [preview-security-validation-checklist.md](preview-security-validation-checklist.md)

Stable schemes:

- app schemes
  - `MacCompanion`
  - `iOSClient`
- shared framework schemes
  - `APTerminalProtocol`
  - `APTerminalProtocolCodec`
  - `APTerminalSecurity`
  - `APTerminalPTY`
  - `APTerminalCore`
  - `APTerminalTransport`
  - `APTerminalHost`
  - `APTerminalClient`

### Device Testing

LAN testing:

1. Put the Mac and iPhone on the same Wi-Fi network.
2. Run `MacCompanion` on the Mac.
3. Run `iOSClient` on a real iPhone.
4. Accept local-network permission prompts.
5. Generate a fresh pairing payload.
6. Pair and verify session attach and input.

Private-overlay testing:

1. Install and sign into Tailscale on both devices.
2. Confirm both devices are in the same tailnet.
3. Switch the Mac to `Private Internet (Tailscale)` mode.
4. Confirm the selected endpoint is the expected overlay address.
5. Generate a fresh bootstrap payload.
6. Pair and verify reconnect, trust expiry display, and session attach behavior.

## Verification And Test Strategy

Highest-priority coverage:

- trust establishment and revocation
- reconnect authentication
- PTY lifecycle and session isolation
- transport parsing and backpressure
- paste and input guardrails
- iPhone local security behavior
- private-overlay failure recovery

Required unit coverage:

- protocol message encoding and decoding
- frame encoding and accumulation
- pairing token validation, expiry, and reuse rejection
- trusted-host and trusted-device persistence
- audit storage and trimming
- terminal input encoding and terminal buffer parsing
- structured logging formatting

Required integration coverage:

- unauthorized clients cannot enumerate sessions
- revoked devices cannot reconnect
- wrong-key, stale, replayed, and mismatched reconnect proofs are rejected
- reconnect after server restart restores session access
- session isolation remains correct
- PTY output, resize, and exit behavior
- oversized and malformed frames disconnect safely
- flooding control messages is rate-limited

Required local verification commands after meaningful changes:

```sh
swift test
xcodebuild -project APTerminal.xcodeproj -scheme MacCompanion -configuration Debug -destination 'platform=macOS' build
xcodebuild -project APTerminal.xcodeproj -scheme iOSClient -configuration Debug -destination 'generic/platform=iOS' build
```

Manual hardware verification before release:

- pair a fresh iPhone and attach to a new shell session
- switch between multiple sessions with no cross-talk
- background and foreground the iPhone app and confirm lock behavior
- verify paste warnings and view-only mode behavior
- revoke a trusted device and confirm reconnect is denied
- verify the private-overlay path on real devices

## Release Readiness

Before labeling V1 release-ready:

- package tests pass
- Mac app build passes
- iPhone app build passes in an environment with working iOS toolchain and asset compilation support
- permission audit still matches this handbook
- revoke and unauthorized access tests pass
- physical-device validation is completed and recorded
- troubleshooting and known limitations are current

Release checks:

- terminal content is absent from audit logs
- paired-device trust is required for session enumeration
- stale pairing tokens and stale reconnect proofs are rejected
- reconnect does not corrupt running sessions
- no unintended broad permissions were introduced

## Known Limitations

- local network and private-overlay internet mode only
- no public raw host-listener exposure
- no managed relay or APTerminal cloud service
- no arbitrary Terminal or iTerm takeover
- terminal emulation covers a practical ANSI subset, not every terminal behavior
- view-only mode is a local app-mode guard, not a separate host-side privilege boundary
- the supported remote path still benefits from a private overlay, but transport confidentiality and integrity no longer depend on the overlay alone
- the host app now fails closed when the selected mode has no approved bind endpoint
- physical-device validation is still required before calling the build release-ready

## Troubleshooting

### Build Issues

`swift test` fails after switching toolchains:

- make full Xcode the active developer directory
- run `xcodebuild -version`

Xcode project is out of date:

- regenerate with `xcodegen generate`

Signing fails on iPhone builds:

- confirm the selected team is valid
- reselect team and bundle identifier in Xcode if needed

### LAN Issues

The phone cannot find the Mac:

- confirm both devices are on the same Wi-Fi network
- confirm local network prompts were accepted
- check the Mac `Security` screen for a non-loopback LAN address

Pairing falls back to `127.0.0.1`:

- the Mac did not detect a reachable LAN address
- reconnect Wi-Fi or Ethernet
- regenerate the pairing payload after network state stabilizes

### Private Internet Issues

Private Internet mode does not connect:

- confirm both devices are in the same tailnet
- confirm the Mac mode is `Private Internet (Tailscale)`
- confirm the selected endpoint is the intended overlay address
- verify any explicit internet endpoint is still overlay-approved

Pairing works on LAN but not over the overlay:

- regenerate the bootstrap payload after switching modes
- confirm the payload expiry has not passed
- if single-use bootstrap mode is enabled, generate a fresh payload
- confirm tailnet ACLs allow the iPhone to reach the APTerminal port

Trusted reconnect is rejected:

- check whether trust expired or was revoked
- re-pair if the host identity or signing key changed
- confirm the Mac and iPhone clocks are reasonably accurate

### Session Issues

Input is blocked:

- check whether view-only mode is enabled
- confirm the app is unlocked
- confirm the session is still attached and not exited

Session disappears after reconnect:

- the remote shell may have exited
- refresh the session list
- create a new managed session if needed

### Audit Log Questions

Expected audit records:

- pairing events
- auth challenge issued
- auth proof accepted or rejected
- revoke events
- connection accepted or denied
- session attach or detach
- remote session creation
- external preview enable, disable, or attach

Unexpected and should be treated as a bug:

- terminal transcript content
- pasted commands
- shell environment dumps
- secrets from terminal output

## Versioning And Documentation Rules

Repository versioning uses semantic versioning:

- `MAJOR.MINOR.PATCH`

Pre-1.0 rules:

- breaking changes are allowed but must be documented
- protocol changes must update [protocol-v1.md](../shared/protocol/Docs/protocol-v1.md)
- security boundary changes must update this handbook and the relevant plan docs

Code-style guidance:

- prefer compiler cleanliness first
- use explicit Swift over style churn
- keep files focused
- use 4-space indentation
- avoid style-only diffs that bury behavior changes

If `swift-format` or `swiftlint` are adopted later, keep the ruleset small and durable.
