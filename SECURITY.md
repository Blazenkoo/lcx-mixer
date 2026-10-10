# Security

LCX Mixer runs entirely on your Mac. It has no server, no web app, no account and no telemetry, and it makes no network requests. That's a deliberate design rule: a live web component would add a way in for attackers and give users nothing in return.

## Reporting a problem

Please report security problems privately, through GitHub's **private vulnerability reporting**: on this repository's **Security** tab, choose **Report a vulnerability**. Don't open a public issue for them.

Fixes go into the latest release only; there are no older release lines.

## What the app exposes, and what protects it

| Surface | What it allows | What protects it |
| --- | --- | --- |
| Bridge socket | The browser extension talks to the app | The socket is a file in `~/Library/Application Support/LCXMixer`, a folder only your user account can open (`0700`); the socket itself is `0600`. A connection is accepted only from a process under the same user that is signed with the app's own code signature, checked through its audit token, so a reused process ID can't fool it. |
| Native messaging host | The browser starts the bridge (the same app executable, in bridge mode) | The host manifest allows exactly one extension ID. |
| Browser extension on all sites (`<all_urls>`) | Finding audio and video players on any page | The page scripts only read and set player volume, playback, speed and position. The extension sends nothing anywhere except to the app on your Mac, and site icons come from the browser's own icon cache. |
| Audio taps on other apps | Changing another app's volume | Audio is changed in memory on the output device's own thread, and is never recorded, stored or sent. macOS asks for the System audio recording permission first, and shows its purple indicator while a tap runs. |
| Microphone mute | Muting your current input device | Only the device's mute or input-volume setting changes. The app never listens to the microphone and has no microphone permission. |
| MIDI | Reading the controller you chose, and lighting its LEDs | No other MIDI device is opened. MIDI learn assignments are stored only on this Mac. |

## Undocumented macOS functions

Three functions the app needs aren't in Apple's public SDK. They're looked up at run time, and the app falls back safely if a macOS update removes them:

- `TCCAccessPreflight` and `TCCAccessRequest` (TCC framework): check and request the System audio recording permission.
- `responsibility_get_pid_responsible_for_pid`: find which app a background audio process belongs to, so a helper's sound lands on its app's channel.

## Logs

The app logs to macOS's unified log only (subsystem `org.lcxmixer.app`) and writes no log files of its own. Anything that could identify you, such as file paths with your user name, is marked private, so macOS hides it in logs you share. See [docs/SPEC.md](docs/SPEC.md#testing-logging-and-auditing) for how to read them.

## Code checks

Every push and pull request is built and tested on a GitHub macOS runner, and CodeQL scans the Swift and JavaScript code. The workflows hold no secrets and never sign or publish anything; releases are built and published by hand. The CI workflow's token is read-only. CodeQL's token can also write code-scanning alerts, which is how its results reach the Security tab. Every action is pinned to an exact commit, and Dependabot proposes updates to those pins.

The app has no third-party dependencies.
