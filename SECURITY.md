# Security policy

Kapture SCR is a private, offline screenshot tool. Its main promises are that it **cannot reach the network** and that it **only writes files where you allow it**. Reports that break either promise are the most valuable.

## Supported versions

| Version | Supported |
|---|---|
| 1.x (latest release) | Yes |
| 0.x | No. Please update. |

Fixes are released as a new version on the [releases page](https://github.com/jsujar/kapture_scr/releases). Older versions are not patched.

## Reporting a vulnerability

Please report privately, not in a public issue:

1. Open the repository's **Security** tab.
2. Click **Report a vulnerability** and describe the problem.

Include the Kapture SCR version (*Help › About Kapture SCR*, *Copy Details*), your macOS version, and steps to reproduce. A proof of concept helps, but please don't include other people's data.

This is a small, independent project. Reports are read and acknowledged as soon as possible, usually within a week, and you will be told what happens next. Once a fix is released, the report can be published as a security advisory with credit to you, if you want.

## In scope

- Any way for the app to send or receive data over the network, or to make another process do it for it.
- Escaping the App Sandbox, or reading or writing files outside the folder you chose and the app's own container.
- Captures, edits or clipboard contents ending up somewhere you didn't send them (other apps, logs, temporary files that are not deleted).
- Redaction that can be undone in an exported image (exports should contain only the final pixels).
- Problems with the code signature or the published checksums of a release.

## Out of scope

- Anything that needs an attacker who already controls your Mac or your user account.
- macOS features outside the app's control: Handoff, Universal Clipboard, backups of your capture folder, or other apps you drag captures into.
- The app not being notarized by Apple. This is known; see [Verify your copy](README.md#verify-your-copy) for how to check a download.

## How the promises are checked

- The app runs in the App Sandbox with no network entitlement, so macOS blocks every connection.
- [Automated tests](README.md#tests) check the entitlements, the source and the compiled binary for network access on every change.
- [CodeQL](.github/workflows/codeql.yml) scans the source on every change and every week.
- Every release lists the SHA-256 of the disk image and of the app, and *Help › About Kapture SCR* shows how to verify your copy.
