# Zoom Red Light

A tiny native macOS menu-bar app. Its dot is:

- **red** when Zoom's microphone is unmuted;
- **gray** when Zoom is muted, closed, or its state cannot be read.

It has no third-party dependencies and does not record or inspect audio. It reads
the label of Zoom's Mute/Unmute control through macOS Accessibility.

For immediate local updates, it also follows Zoom's configured **Mute/unmute my
audio** keyboard shortcut (including globally enabled shortcuts) and detects
clicks on Zoom's audio button. While Zoom is focused, it also follows temporary
press-and-hold Space unmuting on both key-down and key-up. Zoom shortcut changes
are picked up automatically.

The **Icon Style** menu offers five persistent choices: Solid Circle,
Outlined Circle, Rounded Square, Microphone, and LIVE Badge. Each style is red
while the microphone is live and gray when it is muted or unavailable.

The **Icon Size** menu provides Standard and Large choices. The separate
**Banner** menu can show or hide a top-center status banner spanning one-third
of the screen during an active Zoom meeting. The banner is hidden when Zoom is
closed or no meeting is active. It stays above the menu bar, follows display
changes, and ignores pointer input so controls underneath remain clickable. All
choices persist across launches.

Use **Advanced → Custom Banner Text…** to replace the default **MIC MUTED** and
**MIC HOT** labels. Custom text persists across launches and can be restored to
the defaults from the same editor.

## Build and run

macOS 13 or later and the Xcode Command Line Tools are required.

```sh
./scripts/build-app.sh
open ".build/Zoom Red Light.app"
```

On first launch, allow **Zoom Red Light** in **System Settings → Privacy &
Security → Accessibility**. If it is not listed yet, quit and reopen the app,
then use its **Open Accessibility Settings…** menu item. During a meeting, the
icon checks Zoom's current mute control about ten times per second.

To keep it running after login, open **System Settings → General → Login Items**
and add `.build/Zoom Red Light.app`. You can also move the app to `/Applications`
before adding it.

## Package for distribution

Create a compressed drag-to-Applications disk image with:

```sh
./scripts/package-dmg.sh
```

The resulting `.dmg` is written to `.build`. The app is ad-hoc signed rather
than Apple-notarized, so another Mac may initially block it. After copying the
app to Applications, the recipient can attempt to open it and then allow it
from **System Settings → Privacy & Security**. The app separately needs
Accessibility permission to read Zoom's mute state and detect its shortcut.

## Privacy

The app only searches the accessible labels exposed by the running Zoom app. It
does not connect to the network, use the microphone, or store meeting data.
