# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub's private vulnerability reporting:
open the repository's **Security** tab and choose **Report a vulnerability**, or go to
<https://github.com/mbieniooo/XM6-Connect/security/advisories/new>. Please do not open a public
issue for a security problem.

Include the version or commit, what an attacker can do, and the steps to reproduce it.

## What is in scope

XM6-Connect runs entirely on your Mac. It contains no networking code and makes no network
connections. Its only external connection is the Bluetooth link to your headphones.

The parts that accept input from other processes are:

- **The agent's local socket**, `~/Library/Application Support/XM6Connect/agent.sock`.
  - It is a Unix-domain socket that only your user account can open (mode `0600`).
  - Requests are single JSON lines of at most 16 KiB.
  - The agent accepts only a small fixed set of commands: status, refresh, reconnect, yield, hold,
    the noise-control, equalizer, speak-to-chat and listening-mode settings, and playback switching.
    It rejects any request with unknown fields or values outside the expected ranges.
  - A playback switch must name a device that the headphones themselves reported.
- **The `xm6connect://action/...` URL scheme.** The widget and the control send their actions to
  the menu-bar app through this scheme. The app accepts only the exact action URLs that it
  generates itself and ignores every other URL.
- **Darwin notifications** in the `user.uid.<your uid>.io.github.mbieniooo.xm6connect.` namespace.
  The agent listens for a fixed set of names in this namespace. Actions arriving this way and
  playback switches share a limit of 30 per minute.
- **The widget extension.** It runs in the App Sandbox, and its only file access outside the
  sandbox is read-only access to `~/Library/Application Support/XM6Connect/`.

By design, any process running as your own user can control the headphones through these
interfaces. A finding that needs only that access is not a vulnerability, unless it lets that
process do more than change headphone settings. Examples would be reading or writing files outside
the XM6-Connect folder, running code in the agent, or affecting another user account.

Problems in the headphones' firmware or in macOS itself are out of scope. Please report those to
Sony or Apple.
