# Security Policy

## Reporting a vulnerability

If you have found a security issue in this project, you can report it in either
of two ways.

**Publicly**, by opening an issue, if the problem is low risk and does not put
anyone's data or infrastructure at risk by being discussed in the open.

**Privately**, through GitHub's Security tab using "Report a vulnerability", if
the issue could be used against a running instance before a fix is available.
Private reports are preferred for anything involving authentication, token
handling, or access to a user's RomM server.

Please include what you were doing, what happened, and the app and iOS versions
if relevant. A proof of concept is helpful but not required.

## Scope

This project is an iOS client for a self-hosted RomM instance. Issues in RomM
itself should be reported to the RomM project rather than here.

Areas of particular interest:

- Handling of device authorization tokens and Keychain storage
- Anything that could expose a server URL, token, or credentials in logs,
  crash reports, or URL parameters
- Webview configuration that could allow untrusted content to reach native code

## Supported versions

This project is pre-release. Only the latest commit on `main` is supported.
