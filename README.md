
<h1 align="center">LCX Mixer</h1>

<p align="center"><strong>Map everything playing to your Novation Launch Control XL (MK2).</strong></p>

<p align="center">
  <img src="docs/images/hero.png" width="880" alt="The LCX Mixer window: YouTube, Twitch, GarageBand and Spotify on channels 1–4, four free channels, and App Store in the Unassigned Audio Sources list">
</p>

LCX Mixer turns a Novation Launch Control XL mk2 into an 8-channel mixer for whatever is making sound: individual browser tabs (Spotify, YouTube, Twitch…) and native apps (games, Discord, Music…). Each new source lands on the next free fader automatically.

## Why it exists

macOS has no per-app volume mixer, and browsers play every tab through one shared audio stream. In practice that means balancing a game, a voice chat and music by hunting through tabs and in-app sliders, often mid-game.

A physical controller solves that: one fader per source, always in the same place, usable without looking or switching windows. LCX Mixer makes that work for both native apps and individual browser tabs, with no setup per session.

https://github.com/user-attachments/assets/81d2e758-2983-4775-951c-c71e33042e1c

**What you get**

- **Automatic assignment:** a new source takes the next free channel, first come, first served, and keeps it until it closes, even if you restart the app.
- **Per-tab control:** Spotify, YouTube and Twitch in the same browser each get their own fader, in Chrome, Edge, Brave, Arc, Vivaldi or Chromium.
- **Hands-free control:** volume on the faders, play/pause and mute on the buttons, all media muted on the side Mute button, and your microphone muted on Solo.
- **Mute list:** apps and websites that should always stay silent, such as chat notifications, never take a channel.
- **Other controllers:** the Launch Control XL mk2 works out of the box; any other MIDI controller can be set up by moving its faders and pressing its buttons (MIDI learn). Mackie Control surfaces such as the Behringer X-Touch are supported experimentally, with motorised faders and scribble strips.
- **Readable at any size:** four text sizes scale the mixer window, menu-bar panel, pop-up and Settings together.
- **Clear feedback:** controller LEDs, a mixer window, a menu-bar panel and a short on-screen pop-up all show the same state.
- **Light on your Mac:** with its windows closed, it uses practically no CPU, even with several sources playing. It wakes up only when something changes, and apps at full volume play completely untouched.
- **Fully local:** no account, no server, no network connections (see *Security*).

The full product specification, including assignment rules, LED colours and edge cases, is in [docs/SPEC.md](docs/SPEC.md).

## Requirements

- macOS 14.2 or later (Apple silicon)
- Novation Launch Control XL **mk2** (the app switches it to Factory Template 1 automatically), any other MIDI controller through MIDI learn, or a Mackie Control surface (experimental)
- Google Chrome or another Chromium browser (Edge, Brave, Arc, Vivaldi, Chromium), for per-tab control
- Xcode (free from the App Store), to build

## Build and install

1. Clone or download this repository.
2. Double-click **Build LCX Mixer.command**, or run `./scripts/build.sh`.
   The script builds the app, signs it, installs it to Applications and launches it.
   If you have an "Apple Development" certificate (Xcode → Settings → Accounts → Manage Certificates), the app keeps its audio permission between rebuilds.
3. On first launch, a welcome window walks through the three setup steps: the audio permission, the browser extension and the controller. macOS asks for **System audio recording**, which is needed to control the volume of native apps. About LCX Mixer, in the menu-bar panel, shows the steps again.

To run the tests, double-click **Test LCX Mixer.command** or run `./scripts/test.sh`. The extension's tests need [Node.js](https://nodejs.org); without it they're skipped locally and still run in CI on every push. How the code is laid out, how to read the logs and how to measure performance: [docs/SPEC.md](docs/SPEC.md#testing-logging-and-auditing).

## Browser extension

The app keeps an up-to-date copy of the extension at:

```
~/Library/Application Support/LCXMixer/ChromeExtension
```

In each browser you use, open its extensions page (`chrome://extensions`, `edge://extensions`, `brave://extensions`…), turn on **Developer mode**, choose **Load unpacked** and select that folder. Load it from that folder rather than from this repository: that copy updates itself whenever the app is rebuilt. Settings → Browsers shows which browsers are connected.

## Controls

| Control | Action |
| --- | --- |
| Fader | Volume. If the fader is below the current level it takes over immediately; if it's above, move it down to take over. |
| Top button row | Play / pause (browser tabs). Double-press on a Twitch channel jumps to live. Hold for 3 seconds to reload the tab. |
| Bottom button row | Mute. Hold for 1 second to unassign the channel. |
| Side **Mute** button | Mute / unmute all media playback: what you hear |
| Side **Solo** button | Mute / unmute your microphone: what others hear from you |
| Bottom knob row | Playback speed: centre = 1×, left end 0.5×, right end 2× (LED green when faster, red when slower) |
| Middle knob row | Seek shuttle: turn right to skip forward, left to skip back; the further you turn, the bigger the jumps (5 / 15 / 30 s). Centre stops. |

**Mute and Solo** are deliberately split: Mute silences everything playing on your Mac, Solo silences your current microphone for every app at once (Discord, Zoom, OBS…). Both light up while on.

**LED colours:** green = playing, amber = paused, dim green = a native app (no play/pause), red = muted, off = empty channel.

**Another MIDI controller?** In Settings → Controller, choose **Any MIDI controller (MIDI learn)** and your device. Then click **Learn** next to each function (a channel's volume, play/pause or mute, Mute all media, Microphone mute) and move the fader or press the button you want for it. A control does one thing at a time: learning it for a new function takes it off the old one.

**Mackie Control (experimental):** choose **Mackie Control** in Settings → Controller and put the surface in Mackie Control (MCU) mode. Faders set volume, and motorised ones move to each channel's level; **Select** plays and pauses, **Mute** mutes (hold to unassign), **F1** mutes all media and **F2** the microphone. The scribble strips show each channel's name and volume. It's written from the protocol and not yet tested on hardware: reports are welcome.

## On screen

The **mixer window** (shown at the top) opens whenever you start the app yourself; at login, the app starts quietly in the menu bar. It lays the 8 channels out in the same order as the controller's columns. Sources that are playing without a channel wait in the **Unassigned** tab below, where you can assign them or drag them onto a channel; the **Muted** tab beside it shows what your mute list is silencing.

The **menu-bar panel** shows the same channels as compact rows, one click away:

<img src="docs/images/menu-bar-panel.png" width="402" alt="The menu-bar panel listing the same four channels as rows, with status dots, volume percentages, and an Assign button for App Store">

**Text size** (Settings → General, or ⌘− / ⌘+ / ⌘0 in the mixer window and Settings) scales everything together; the mixer window resizes to fit, and Settings, which you can resize yourself, never gets smaller than its content needs.

Touching any control shows a short **pop-up** on the screen where that source is playing, so you can mix without opening anything:

<img src="docs/images/pop-up.png" width="462" alt="The on-screen pop-up: Spotify – Bleed It Out • Linkin Park, on channel 4">

## Security

LCX Mixer has **no network attack surface**: there is no server or web app, and nothing listens on the network.

- Browsers talk to the app only through their native messaging, which they allow only for this extension's ID.
- The app and its browser bridge connect through a local socket that only your user account can access. Each side checks that the other runs under your account and carries the app's own code signature.
- Site icons come from the browser's local icon cache. The app makes no network requests.
- Logs stay in macOS's own log on your Mac, with anything that could identify you hidden.
- The only permission requested is System audio recording. No microphone access: muting the microphone only switches the input device's mute (or input volume) setting, and the app never listens to it.
- **About the purple dot:** while a native app's volume is below 100% or it's muted, macOS shows a purple dot in the menu bar, its standard sign that an app is capturing system audio. That's LCX Mixer taking over the app's sound to set its volume. The dot also shows while the mixer window or the menu-bar panel is open, because LCX Mixer then listens to playing native apps at 100% to draw their level meters; their sound itself stays untouched. With the windows closed and every app at 100%, the dot goes away. Click the dot or open Control Center to see the app's name. An orange dot would mean a microphone is in use, which LCX Mixer never does.

Found a security problem? Please report it privately, as described in [SECURITY.md](SECURITY.md), which also lists everything the app exposes and how it's protected.

## Known limitations

- **Changing a native app's volume** from 100% (or back to it) can sound slightly rough for a split second, as the app's sound crossfades over to LCX Mixer (or back). It happens only at that moment, not while you adjust the volume.
- **Browser tab meters** show activity, not real levels: drops land on the bar below the channel's volume and ripple outward. macOS can't separate the sound of individual tabs, so the tab meter is deliberately unlike a real one.
- **Twitch live streams:** "pause" silences the tab and keeps the stream live. A background tab can't reliably resume a paused live stream.
- **Spotify** applies its own loudness curve to its volume slider, so the bottom half of the fader is gentler than on other sources.
- **Microphone mute:** some audio interfaces, such as the Focusrite Scarlett range, don't let apps mute their inputs. The pop-up says so when you press Solo.
- **Side button lights** (Mute, Solo) on the Launch Control XL mk2 are yellow only.
- **Mackie Control** support is experimental: it follows the protocol but hasn't been tested on a real surface yet. V-Pots and the master fader aren't used.
- **MIDI learn** covers volume, play/pause, mute, Mute all media and Microphone mute. It has no light feedback, since every controller lights its buttons differently, and the speed and seek knobs are only on the Launch Control XL.
- To check the audio permission and to identify which app a background audio process belongs to, the app uses three undocumented macOS functions (listed in [SECURITY.md](SECURITY.md)). Future macOS versions could change them.

## How it was made

LCX Mixer was designed and specified by @Blazenkoo (on Github.com) and built with Claude (Anthropic), from an approved specification through hardware testing on a real controller.

## License

MIT, see [LICENSE](LICENSE).
