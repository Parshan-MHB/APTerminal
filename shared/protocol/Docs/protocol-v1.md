# Protocol V1

This document defines the initial shared wire contract for APTerminal.

## Scope

Protocol V1 covers:

- peer identification
- secure session establishment
- trusted-device pairing messages
- reconnect authentication messages
- session lifecycle control messages
- terminal stream framing
- protocol errors

V1 supports LAN and the documented private-overlay path. It does not support raw public internet exposure.

## Versioning Strategy

- Every frame carries a protocol version in the frame header.
- V1 uses `ProtocolVersion.v1`.
- Future versions must be additive where possible.
- Unknown protocol versions must be rejected before session metadata or terminal data is exposed.

## Transport Framing

Every frame is length-prefixed through a fixed-size header.

Header layout:

- bytes `0...1`: protocol version as big-endian `UInt16`
- byte `2`: frame kind as `UInt8`
- bytes `3...6`: payload length as big-endian `UInt32`

Current header size: `7` bytes.

## Frame Kinds

- `control`
  - JSON-encoded control messages
- `terminalInput`
  - terminal input bytes and metadata
- `terminalOutput`
  - terminal output bytes and metadata
- `heartbeat`
  - reserved for connection liveness
- `secureTransport`
  - encrypted app-layer wrapper for control, terminal, and heartbeat payloads after secure-session setup

## Secure Session

After the initial plaintext `hello` exchange, V1 establishes an app-layer secure session:

1. Client sends `hello` with its device signing public key and only the minimum identity material needed to bind the secure-session offer.
2. Host replies with `hello` containing the host signing public key and a signed `secureSessionOffer`.
3. Client verifies the pinned host signing key and the signed offer.
4. Client sends `secureSessionAccept` with a fresh ephemeral key signed by its device signing key.
5. Both peers derive per-connection session keys through Curve25519 key agreement and HKDF.
6. Host sends encrypted `secureSessionReady`, including full host identity and mode metadata needed by the client UI.
7. All later control messages, terminal input/output, and heartbeat traffic ride inside `secureTransport` frames.

Security properties:

- each encrypted frame is authenticated with ChaCha20-Poly1305
- send and receive keys are direction-specific
- inbound secure frames must use the next expected sequence number
- replayed, reordered, corrupted, or undecryptable secure frames fail closed and disconnect the peer
- the secure session is bound to the pinned host signing key through the signed host offer

## Control Messages

Current V1 control messages:

- `hello`
- `secureSessionAccept`
- `secureSessionReady`
- `authChallengeRequest`
- `authChallenge`
- `authProof`
- `authResult`
- `pairRequest`
- `pairResponse`
- `listSessions`
- `sessionList`
- `createSession`
- `renameSession`
- `closeSession`
- `attachSession`
- `detachSession`
- `resizeSession`
- `lockSession`
- `error`

Control messages are encoded as:

- `id`
- optional `replyTo`
- `message`

Each control payload still contains:

- `kind`
- `payload`

## Session Contract

Each session summary includes:

- stable `SessionID`
- title
- shell path
- working directory
- state
- optional pid
- rows and columns
- created and last-activity timestamps
- preview excerpt

Session listing rules:

- managed session metadata is always listable after authentication
- managed `previewExcerpt` content is returned only when the trusted device has preview privilege in the current host mode and the host allows managed content previews
- external Terminal or iTerm preview sessions are listed only when the trusted device has preview privilege in the current host mode and the host allows external previews

## Terminal Byte Stream Rules

- Before secure-session setup, only `hello` and `secureSessionAccept` use plaintext `control` frames.
- The plaintext `hello` exchange carries only the minimum identity material needed for host pinning and secure-session establishment; full host identity, mode, endpoint kind, and preview-access metadata arrive inside encrypted `secureSessionReady`.
- After secure-session setup, terminal content rides inside encrypted `secureTransport` frames whose inner payload kind is `terminalInput` or `terminalOutput`.
- Terminal data remains separate from control-plane messages.
- Each terminal stream chunk includes:
  - `sessionID`
  - stream direction
  - monotonic sequence number
  - raw bytes

## Reconnect And Resume Rules

V1 keeps reconnect behavior simple:

- a client reconnects at the transport layer
- the client re-establishes the secure session
- the client re-requests an auth challenge and re-authenticates
- the client re-lists sessions
- the client re-attaches to the desired session
- `attachSession` may include `lastObservedOutputSequence`

Inference:

- V1 supports re-attachment to active sessions
- V1 does not promise lossless stream replay from arbitrary history

## Pairing Sequence

1. Mac creates a short-lived pairing token.
2. iPhone scans a QR code containing pairing bootstrap data, including the host public signing key.
3. iPhone completes the secure-session handshake and verifies the host signing key.
4. iPhone sends encrypted `pairRequest` with:
   - pairing token
   - device identity
   - device public key
   - signature proving possession of the private key for the supplied public key
5. Mac validates token freshness and trust ceremony state.
6. Mac responds with encrypted `pairResponse`.
7. Accepted devices become trusted for future authenticated connections.

## Device Identity Model

Each device identity includes:

- stable device ID
- human-readable device name
- platform
- app version

## Error Model

Current V1 protocol error codes:

- `unsupportedVersion`
- `malformedFrame`
- `malformedMessage`
- `unauthorized`
- `rateLimited`
- `forbidden`
- `pairingExpired`
- `sessionNotFound`
- `invalidState`
- `internalFailure`

Errors must not leak secrets, terminal transcripts, or internal storage details.

## Audit Event Types

Allowed audit events:

- `devicePaired`
- `deviceRevoked`
- `previewAccessGranted`
- `previewAccessRevoked`
- `previewAccessDenied`
- `previewAccessUsed`
- `connectionAccepted`
- `connectionDenied`
- `authChallengeIssued`
- `authProofAccepted`
- `authProofRejected`
- `sessionAttached`
- `sessionDetached`
- `remoteSessionCreated`
- `externalPreviewsEnabled`
- `externalPreviewsDisabled`
- `externalPreviewAttached`

Terminal content is explicitly out of scope for audit logging.

## Compatibility Rules

- New protocol versions may add message kinds and optional fields.
- Existing V1 message semantics must remain stable.
- Removing or changing the meaning of an existing V1 field requires a new protocol version.

## Example Control Message

```json
{
  "id": "13cb0e4d-b0b7-4a4e-9bdb-fbce845f5d25",
  "message": {
    "kind": "createSession",
    "payload": {
      "initialSize": {
        "columns": 120,
        "rows": 40
      },
      "shellPath": "/bin/zsh",
      "workingDirectory": "/Users"
    }
  }
}
```

## Hello Message Notes

- Host `hello` responses include the host public signing key and the signed secure-session offer.
- Encrypted `secureSessionReady` includes the full host identity, connection mode, endpoint kind, and preview-access modes currently granted to that trusted device.
- Clients should compare that key against:
  - the bootstrap payload during first pairing
  - the trusted-host registry on later reconnects
- Auth challenges are requested only after the secure session is established.
