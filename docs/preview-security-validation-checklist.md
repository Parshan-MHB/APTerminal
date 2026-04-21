# Preview Security Validation Checklist

Use this checklist before calling the current preview and remote-access model release-ready.

## LAN

- pair a new iPhone over LAN
- reconnect an already trusted iPhone
- verify managed session create, attach, input, resize, detach, and close
- verify managed `previewExcerpt` is hidden without preview privilege
- verify managed `previewExcerpt` is visible with preview privilege
- verify external Terminal/iTerm previews are visible only when enabled on the Mac and granted to the device

## Private Overlay

- enable `Private Internet` mode on the Mac
- confirm both devices are connected to the same private overlay
- generate a fresh pairing payload
- pair and reconnect successfully
- verify the Mac does not advertise Bonjour in private mode

## Revocation And Trust

- revoke a trusted device on the Mac
- confirm reconnect fails immediately
- confirm a fresh pairing ceremony is required after revocation

## Logging

- confirm trust and preview events appear in the audit log
- confirm terminal content does not appear in the audit log

## Host Lifecycle

- stop the host and confirm no APTerminal listener port remains open
- switch between LAN and Private Internet and confirm the host recovers cleanly
