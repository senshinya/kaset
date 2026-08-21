# ADR-0034: Pause Playback When the Audio Output Device Disappears

## Status

Accepted

## Context

Playback runs inside a WebView (ADR-0001), which renders to whatever the system
has selected as its default audio output. When that device changes mid-playback
— headphones unplugged, AirPods connected, output switched in Control Center —
WebKit follows the new device and keeps playing. Nothing in the app noticed.

The failure is the unplug case: pulling headphones moves audio to the built-in
speakers and the track keeps going, out loud, in whatever room the user is in.

Only that case. Switching output deliberately — picking another device in
Control Center, or connecting headphones — is not a reason to stop the music,
which is why iOS singles out `oldDeviceUnavailable` among its route-change
reasons. macOS publishes no such reason code, so "the device went away" has to
be *inferred*: when the route changes, ask whether the route playback was using
is still attached.

Four facts shaped the design:

1. **The default output device is not the output route.** Built-in audio on
   some Macs, and many USB interfaces, model the headphone jack and the
   speakers/line-out as two *data sources* of a single device. Unplugging
   headphones there changes `kAudioDevicePropertyDataSource` while
   `kAudioHardwarePropertyDefaultOutputDevice` never moves, so a device-ID
   comparison would miss the headline case on exactly the hardware that has a
   jack. Verified against real hardware: the built-in speaker device on an
   Apple Silicon Mac reports a data source (`ispk`), while an external USB
   interface and a display report none. The property is array-valued
   ("currently selected data sources" in `AudioHardware.h`), so the route
   carries the whole selection rather than a single ID.
2. **Core Audio's notifications are noisy.** The listeners fire in bursts while
   a device settles, and fire for notifications that name the route the app is
   already on. Pausing on every notification would pause playback for events
   that changed nothing.
3. **Attachment has to be watched too.** Whether a route change was a
   disconnect or a choice is answered by the device list
   (`kAudioHardwarePropertyDevices`) and, for a jack modelled as a data
   source, by the device's available sources
   (`kAudioDevicePropertyDataSources`) — not by the change notification
   itself, which looks identical either way.
4. **In-app AirPlay does not go through these properties.** Picking an AirPlay
   target inside the playback WebView (ADR-0010) routes that media element
   without changing the system default output device, so the picker cannot trip
   this feature — which is the behaviour we want.

## Decision

Detect the change in a dedicated monitor, and act on it in the existing
one-audio-source arbiter.

**`AudioOutputDeviceMonitor`** (`Services/Audio/`) owns the Core Audio
listeners. The unit it tracks is an `AudioOutputRoute` — the default device
(matched by UID, since Core Audio recycles numeric device IDs) plus that
device's selected output data sources. Three subscriptions feed it: the default
output device and the device list on the system object, and the selected data
source on whichever device is currently default, re-pointed every time the
default changes.

The monitor debounces notifications (50 ms) so a disconnect's burst is judged
once, on settled state. When the settled route differs from the baseline, it
asks the watcher whether the *previous* route is still attached — before
adopting the new one, since adopting it would lose the question. Still
attached means the user switched, and nothing is reported; gone means a
disconnect, and playback is paused.

Route reads, attachment checks, and subscription sit behind
`DefaultOutputRouteWatching` so tests drive plug and unplug without real
hardware. The production watcher is deliberately not `@MainActor`: a listener
block formed in a MainActor context inherits that isolation and trips Swift 6's
runtime isolation check the first time Core Audio fires it off-main — the same
trap `EqualizerService` documents.

**`PlaybackArbiter.outputRouteDidDisappear()`** applies the policy. The arbiter
already knows both playback services and already owns "one audio source at a
time", so the cross-source rule belongs there rather than in either player.
Pausing does not change `activeSource`: a disconnect is not a source switch,
and media keys must keep pointing where they pointed.

The behaviour is a preference (`settings.pauseOnOutputDeviceDisconnect`, default on)
under General → Behavior, injected into the arbiter as a closure rather than
read from `SettingsManager.shared`, because suites that run in parallel race on
that singleton.

## Consequences

- Unplugging headphones pauses playback instead of broadcasting it, whether the
  jack is its own device or a data source of the built-in one. Connecting a
  device, or switching output deliberately, keeps playing.
- Only actually-playing sources are touched. A disconnect while music is still
  loading is ignored, and in particular does not begin a music playback intent
  — beginning one supersedes the in-flight request the user just started
  (ADR-0027).
- Losing every output device counts as a disconnect and pauses. The device that
  eventually appears afterwards is a fresh baseline, not a second loss.
- The inference reads live state, so it assumes Core Audio has retired the
  device by the time the settled notification is judged — which is the order
  the HAL produces, since the removal is what moves the default. If a removal
  ever landed late, the result is a missed pause, never a spurious one.
- The monitor is app-lifetime and never unsubscribes; it is created and started
  once in `KasetApp.init()`.
- Playback does not resume when the device comes back. Restoring on return
  would need per-device state and would surprise users whose track was paused
  for an unrelated reason in between.
