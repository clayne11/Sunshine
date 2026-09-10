# Remote microphone on macOS

This optional feature receives the encrypted microphone extension implemented by
VoidLink and renders mono 48 kHz audio to a selected Core Audio output device.
A virtual audio device exposes that audio as a microphone input to Mac apps.
The receiver uses public Core Audio APIs; it has no Loopback SDK, bundled
driver, or BlackHole-specific API dependency.

## Routing

1. Install a virtual audio device. For Loopback, create a two-channel device
   named `iPad Microphone` containing only the enabled Pass-Thru source. For
   BlackHole, a dedicated two-channel device can serve the same purpose.
2. Set Sunshine's `microphone_sink` to that device's exact Core Audio UID.
   A display name is not a UID. Leave the setting empty to disable reception.
   To list device names, UIDs, and channel counts without changing audio state,
   run `swift scripts/macos-audio/list-devices.swift` from the Sunshine
   checkout and copy the `uid` of the intended virtual device.
3. Enable microphone forwarding in a compatible VoidLink client and grant
   the client microphone permission. Reconnect after changing the host setting.
4. Select the virtual device as the input in the receiving Mac app. To use it
   in apps that follow the system input, select it in macOS Sound settings.
   Apps with their own input selection may need a separate change.

Keep the Mac's normal playback output selected. Do not use the same virtual
device for both streamed host audio and the remote microphone, and do not add
a speaker monitor to the microphone device. Loopback's
[Pass-Thru documentation](https://rogueamoeba.com/support/manuals/loopback/?page=passthru)
describes how an output becomes an input available to other apps.

Only one session can own the microphone receiver. An unavailable UID does not
redirect received voice to the speakers, and failure to initialize the receiver
does not stop video or host audio. Disconnecting releases the receiver and its
device. Sunshine does not change the system input or output defaults.

Core Audio sink initialization and disposal run in one isolated worker so a
stalled audio driver cannot block RTSP, video, or session teardown. If that
worker remains stuck inside the driver, microphone forwarding stays unavailable
for later sessions until Sunshine restarts; streaming and reconnects remain
available. A reconnect waits at most 500 ms for normal sink disposal before it
continues without microphone forwarding. The worker retains no session key, UDP
socket, or decoder after the streaming session ends, and canceled sessions
cannot publish delayed audio.

## Protocol and limitations

The implementation follows the microphone wire format in
[VoidLink's common client library](https://github.com/TrueZhuangJia/voidlink-c)
at commit `5ec6288caacf07f679123fbd4b2f8ea46ba6724a`: UDP on the server base port
plus 12 (48001 with the default base), 20 ms mono Opus frames, and the negotiated
microphone encryption feature bit. The receiver requires a paired launch,
negotiated encryption, and packets from the streaming client's IP address.
It bounds packet reordering, concealment, and the device queue. The microphone
jitter queue keeps at most four 20 ms packets. When a burst exceeds that limit,
it drops the oldest queued audio and advances playout to the retained window,
rather than preserving old gaps while repeatedly discarding fresh speech.
Skipping audio resets decoder concealment state; it does not expand the queue
or play a catch-up burst into the audio device.

This extension uses AES-CBC without an authentication tag. Its encryption must
not be described as authenticated encryption. Ordinary Moonlight clients do not
gain microphone support by changing the host setting alone. Client releases
may differ from the public source and require interoperability testing.

Host-side buffering does not provide acoustic echo cancellation. With the
client's speakers playing, test conversational audio for echo as well as delay;
the client and receiving app's audio processing affect the result.

Sunshine logs aggregate receiver diagnostics every 10 seconds for the first
minute, every 30 seconds afterward, and once at teardown. These counters report
packet channel mode, real/PLC/synthetic frames, queue and scheduling gaps, and
real decoded PCM peak and RMS in signed 16-bit sample units plus zero and clipped
fractions. Client timestamps are wrapping monotonic milliseconds rather than
audio sample timestamps. The logs never include packet payloads, PCM samples,
session keys, or client addresses.

## Validation before release

Unit tests cover malformed and encrypted packets, ordering, replay rejection,
and the bounded audio queue. They do not establish live compatibility with a
particular client, driver, or Mac app. Check all of the following on the target
setup before calling microphone forwarding ready:

- Speak from the iPad and observe the virtual input and receiving app meters.
- Play host audio simultaneously and check that it does not enter the virtual
  microphone through digital routing.
- Pause and resume microphone forwarding, then disconnect and reconnect several
  times without restarting Sunshine.
- Remove or disable the virtual device and verify video continues without
  microphone audio being sent to another output.
- Check voice latency and echo while using the intended speakers or headphones.
