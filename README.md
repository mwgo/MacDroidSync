# MacDroidSync

Clipboard sharing between macOS and Android over Wi-Fi, in the spirit of KDE Connect.

* **macOS → Android is live.** Every `Copy` on the Mac is pushed to the phone immediately and applied
  to the Android clipboard through a transparent window. If the phone is not around, the latest value
  waits in a queue and is delivered on the next connection.
* **Android → macOS is on demand.** The phone pushes its clipboard when you tap *Send clipboard to Mac*
  in the notification.
* **Files go both ways.** On the phone, pick *Send to Mac* in the share sheet and the file lands in the
  Mac's Downloads folder; shared plain text goes to the Mac's clipboard instead. On the Mac, use the Share
  menu, *Send to Android* in the Services menu, or *Send files to phone…* in the menu bar, and the file
  lands in the phone's Download folder. Files shared while the other device is away wait in a queue and
  are delivered on the next connection.
* **The status bar icon on Android only exists while a Mac is connected.** No connection, no icon.
* **Ping** the phone straight from the Mac menu and get the round trip time.

```
                       Bonjour _macdroidsync._tcp, TCP port 47831
   ┌──────────────────────────┐                        ┌──────────────────────────┐
   │ macOS menu bar app       │   one long lived TCP    │ Android foreground svc   │
   │ (server, advertises)     │◄──────────────────────►│ (client, reconnects)     │
   │ NSPasteboard polling     │  AES-256-GCM frames     │ transparent window       │
   │ offline queue (latest)   │  heartbeat every 15 s   │ notification actions     │
   └──────────────────────────┘                        └──────────────────────────┘
```

The wire format, the key derivation and the cross platform test vectors are documented in
[PROTOCOL.md](PROTOCOL.md).

## Requirements

| | |
|---|---|
| macOS | 14 or newer, Xcode command line tools (built and verified with Xcode 26.6 / Swift 6.3) |
| Android | 9 (API 28) or newer, built against SDK 36 |
| Build tools | Android SDK with build-tools 36, JDK 17+ (the Android Studio JBR works) |
| Network | Both devices on the same Wi-Fi network; a fixed TCP port, 47831 by default |

## Build and run

### macOS

```bash
cd macos
./build.sh
open build/MacDroidSync.app
```

`build.sh` produces `build/MacDroidSync.app` in release configuration; pass `debug` for a debug build.
Once it is open, an icon of two arrows pointing opposite ways appears in the menu bar.

To follow what it is doing, run the binary inside the bundle with logs on stdout:

```bash
MDS_VERBOSE=1 build/MacDroidSync.app/Contents/MacOS/MacDroidSync
```

The app has no Dock icon and no window, but it does carry an application icon (Finder, Login Items,
notifications): two arrows one above the other, pointing opposite ways, the same artwork as the Android
launcher icon. The clipboard it replaces described only the first thing this app ever did; everything it
carries now - the clipboard, the files, the presence - travels both ways. `Resources/AppIcon.svg` is the
source; regenerate the bundled `Resources/AppIcon.icns` after editing it with

```bash
cd macos
swift Tools/make-app-icon.swift
```

The menu bar itself stays on monochrome SF Symbols, because that icon has to change with the connection
state and follow the menu bar tint. They are the same two arrows, drawn thin while nothing is connected
and enclosed in a filled circle once it is.

The menu carries the state and the things worth doing from the menu bar; everything that is set once
lives in *Settings…* instead:

| Menu item | What it does |
|---|---|
| `Connected: <phone>` / `Listening on port 47831` | current state |
| `Ping phone` (⌘P) | rings the phone and shows the round trip time, `Ping: 23 ms`, for a few seconds |
| `Send clipboard now` (⌘S) | pushes the current clipboard even if it did not change |
| `Last sent: …` | what was last sent, received or queued |
| `Send files to phone…` (⌘O) | opens a file picker; several files at a time are fine |
| `Sending photo.jpg - 45%` | outgoing transfer, then `Sent: …` or `Queued: 3 files` |
| `Received: <file>` | the file that arrived last; selecting it reveals the file in Finder |
| `Open Downloads folder` | opens the folder incoming files are saved to |
| `Lock when the phone leaves` | the automatic locking, with the live reading `Phone: -58 dBm (near)` under it |
| `Pause auto lock for an hour` | gets the automatic locking out of the way for a while |
| `Settings…` (⌘,) | the settings window, see below |
| `About MacDroidSync` | author, licence and the version that is actually running |

#### The settings window

Two tabs, opened from `Settings…` in the menu - or with ⌘, while the menu is open, the same as the
other shortcuts there:

| Tab | What is in it |
|---|---|
| **General** | the pairing code with *Copy* and *Regenerate…*, the listening port, *Launch at login*, and where incoming files are saved |
| **Auto lock** | the *Lock when the phone leaves* switch, the three sensitivity presets with their numbers spelled out, the away threshold in dBm, the live reading next to it, and the pause |

The window and the menu show the same settings from two sides and stay in step: switching the automatic
locking off in one is visible in the other straight away. A value typed into a field takes effect on
*Return* or on the button next to it - never on the way out of the field - so closing the window
abandons a half typed port instead of applying it.

Being a menu bar app, MacDroidSync has no menu bar of its own to show. It installs one anyway, without
displaying it, because that is what dispatches ⌘C, ⌘V, ⌘A and ⌘W to the settings window - without it a
window in which you paste a pairing code would not accept a paste.

The menu bar icon reflects the connection:

| State | Icon |
|---|---|
| waiting for the phone | thin two way arrows, dimmed |
| connecting / handshake | thin two way arrows, full strength |
| connected | two way arrows in a filled circle |
| clipboard or a file moving | brief flash of the circular sync arrows |
| suspended (lid closed, or the Mac asleep) | dimmed moon |
| error (port taken, listener failed) | red warning triangle, details in the menu |

### Android

```bash
cd android
JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ./gradlew :app:assembleDebug
~/Library/Android/sdk/platform-tools/adb install -r app/build/outputs/apk/debug/app-debug.apk
```

Then open the app once and, in *Settings* in the toolbar menu:

1. Type the **pairing code** from the Mac's settings window (case and dashes do not matter).
2. Leave *Mac address* empty to find the Mac over Bonjour, or type an address if discovery is blocked
   (client isolation on the access point, a VPN, or the emulator, where the host is `10.0.2.2`).
3. Grant **notifications** and **display over other apps**.
4. Press *Save and reconnect*, go back, and turn on *Keep the clipboard in sync*.

The main screen keeps only what is used day to day: the connection state, the two switches, *Send
clipboard to the Mac*, *Lock Now* and *Disconnect*. The pairing, the address, the port and the
permissions live in *Settings*; *About* names the author and the licence.

To send a file, share it from any app (*Share* → *Send to Mac*). That works whether or not clipboard sync
is on: a shared file is an explicit request, so the app connects for it and goes back to idle afterwards.

#### Why "display over other apps" is required

Since Android 10 an app may only read or write the clipboard while it owns the focused window, and it may
only start an activity from the background if it holds this permission. MacDroidSync therefore opens
`ClipboardBridgeActivity`, a fully transparent window with no animation, does the clipboard work as soon
as it gains focus and finishes right away. Without the permission, incoming clipboard items become a
tappable notification instead of being applied automatically.

## Behaviour worth knowing

* **Suspending the sync.** Both sides send a heartbeat when idle for 15 s and drop the connection after
  30 s of silence, so walking out of Wi-Fi range suspends the sync instead of hanging it. The phone
  retries with a 1 → 2 → 5 → 10 → 30 s backoff and reconnects immediately when a network appears.
* **Closing the lid stops the sync on purpose.** When the Mac goes to sleep, or its lid is closed while it
  keeps running in a dock, MacDroidSync sends a `bye` frame, drops the session and stops advertising
  itself. The phone therefore hides its status bar icon within a second instead of waiting for the 30 s
  timeout, and the menu bar icon turns into a dimmed moon with `Suspended, the lid is closed`. Everything
  copied in the meantime is queued and delivered when the lid opens again. Sleep is detected through
  `NSWorkspace.willSleepNotification`; the lid itself through `AppleClamshellState` on `IOPMrootDomain`,
  which is polled every two seconds because there is no public notification for it.
* **Offline queue.** Only the most recent clipboard value is kept (clipboard semantics are "last one
  wins"). It is stored in `~/Library/Application Support/MacDroidSync/pending.json`, so it also survives
  restarting the Mac app, and it is cleared once the phone acknowledges it.
* **Sending files.** *Share* → *Send to Mac* copies the shared files into the app cache and hands them
  to the sync service, which streams them over the same encrypted connection in 192 KiB chunks. The Mac
  writes to `<name>.macdroidsync-part` in `~/Downloads` and only renames it to the real name once the
  SHA-256 sent with the last frame matches, so a half transferred file never shows up as finished. An
  existing name is not overwritten: `photo.jpg` becomes `photo (2).jpg`, exactly like Finder. The phone
  shows the progress in a notification and the Mac shows it in the menu; when the file lands, the Mac
  posts a notification with a *Show in Finder* action.
  The copy into the cache is not optional: the permission to read a shared `content://` URI dies with the
  screen you shared from, so the bytes have to be taken while it is still open. That same copy is the
  offline queue, capped at 512 MiB in total, and it survives the app being killed. Files are sent from the
  phone to the Mac only; the Mac never pushes files to the phone.
* **Sending files from the Mac.** Three entry points end up in the same queue: the **Share** menu (a
  share extension inside the app bundle), **Send to Android** in the Services menu, which also appears in
  the Finder context menu, and **Send files to phone…** in the menu bar. Files are streamed straight from
  disk, so nothing is copied first; the queue in
  `~/Library/Application Support/MacDroidSync/outbox.json` only remembers paths, which means a file that
  is moved or deleted before its turn is dropped from the queue and reported in the menu instead of being
  sent. Up to eight chunks are kept in flight, which keeps memory flat: sending 120 MB moves the app from
  50 to 80 MB of RSS and stays there. On the phone the file goes to the public **Download** folder through
  MediaStore, so no storage permission is involved, and MediaStore renames duplicates itself
  (`photo.jpg`, then `photo (1).jpg`). The arrival notification carries an **Open** action.
* **The Share menu needs one setup step.** An ad-hoc signed extension is registered but not necessarily
  enabled, so after the first build run `pluginkit -a macos/build/MacDroidSync.app/Contents/PlugIns/ShareExtension.appex`
  and turn MacDroidSync on under *System Settings, General, Login Items and Extensions, Sharing*. The
  Services entry needs `/System/Library/CoreServices/pbs -flush` once. Both are printed by `build.sh`.
  The extension itself does no networking: it is sandboxed, drops the shared paths into
  `~/Library/Application Support/MacDroidSync/share-requests/` and the app, which watches that folder,
  picks them up within milliseconds and starts sending. Because it is sandboxed, that path is resolved
  from the real home directory (`getpwuid`) instead of the usual `FileManager` search paths: those are
  redirected into `~/Library/Containers/…`, where the app would never find the requests.
* **Locking the Mac when you walk away.** While the clipboard sync is on, the phone broadcasts a
  Bluetooth LE beacon every 250 ms; the
  Mac measures the signal strength of each packet and locks its screen once the **average** says you have
  left. Both sides have to agree: the switch *Lock the Mac when I walk away* on the phone, which needs the
  *Nearby devices* permission and the clipboard sync switched on, and *Lock when the phone leaves* in
  the Mac's menu, which asks for Bluetooth access the first time it is turned on. The beacon rides along
  with the sync rather than running on its own, so switching the sync off - from the switch, the
  **Disconnect** button or the notification - stops the broadcast as well. The phone says so over the
  session before it goes, so the Mac disarms instead of reading the silence as a departure. The beacon needs no Wi-Fi, no pairing over Bluetooth
  and no connection of any kind - it is one 31 byte advertisement, and nothing is ever scanned or
  connected to from the phone.
  Signal strength is far too noisy to act on directly, so nothing is decided from a single reading: the
  Mac averages the last 20 seconds, starts a 20 second countdown once that average drops below -80 dBm
  (or once no packet arrives for 15 s at all), and needs -72 dBm to consider you back. In practice the
  screen locks roughly 25 to 40 seconds after you leave the room, and a hand over the phone or a body
  walking past does nothing at all. For the whole countdown a panel sits in the middle of the screen
  showing the seconds left, with a **Don't lock** button. It is a non-activating panel, so it never takes
  focus from what you are doing, and it keeps no clock of its own: the number it shows comes from the
  same state machine that decides on the lock.
  **Don't lock** does not pause the feature for a fixed stretch. It means "I am here, my phone is not":
  the Mac goes back to square one and locks nothing at all until it has seen the phone again, at which
  point the auto lock resumes as usual. For a real pause there is *Pause auto lock for an hour* in the
  menu.
  **The Mac never locks itself for a phone it has not seen.** Bluetooth off on either side, a mismatched
  pairing code, a phone that never had the switch on: all of them mean the feature simply stays idle. It
  also stays out of the way while the Mac is asleep, while the lid is closed and while the screen is
  already locked.
* **What the radio actually delivers.** Measured on this pair (Samsung SM-S931B next to a MacBook Pro,
  phone on the desk, 2.9 minutes): **0.40 readings a second**, arriving in bursts of a few packets 0.29 s
  apart separated by quiet spells - median gap 0.29 s, 90th percentile 6.3 s, **worst 7.2 s**. macOS duty
  cycles its own scan, so that pattern is the platform, not the phone; the 15 s "beacon lost" threshold is
  sized against it with roughly double the margin, and a false lock would need 35 s of total silence.
  In the same run a **stationary** phone produced readings from -51 to -91 dBm, a spread of **40 dB**,
  while the average stayed put at -63.5. That gap between one reading and the average is the whole reason
  this feature averages at all.
* **Calibrating the distance.** dBm readings differ by more than ten between radios, rooms and pockets,
  so both the menu and the *Auto lock* tab show the live average (`Phone: -63 dBm (near)`): walk to where
  you want the lock to happen and read the number. The tab is the place to do it, because the threshold
  field and the reading it is compared against sit next to each other. *Sensitivity* offers three presets
  - **Fast** (10 s window, -75 dBm, 10 s grace), **Balanced** (the default above) and **Cautious** (30 s
  window, -85 dBm, 45 s grace) - and *Away threshold* takes a single dBm value while keeping the preset's
  hysteresis.
* **Locking the Mac by hand.** **Lock Now** in the Android app, both as a button in the main window and
  as an action on the ongoing notification, locks the Mac straight away. It works whether or not the
  automatic locking is switched on and regardless of the beacon, because it is a button press rather
  than a guess about where you are; all it needs is the encrypted session, so the button is greyed out
  while no Mac is connected. **Disconnect** next to it ends the clipboard sync, and with it the beacon.
* **Turning the beacon off tells the Mac.** A beacon that just disappears is indistinguishable from a user
  walking away, so anything that stops the broadcast - the beacon switch, the sync switch, Disconnect -
  first sends a `presence` message over the encrypted session, and the Mac disarms immediately. The one
  corner: if the switch is flipped while the phone is not connected to the Mac over Wi-Fi, the Mac sees
  the beacon vanish and locks **once** before disarming for good.
* **What the beacon gives away.** The advertisement carries a 128 bit service UUID derived from the
  pairing code plus a token that only works for 30 seconds, so no other phone can arm the auto lock and a
  recorded packet cannot keep the Mac unlocked later. The UUID itself is constant, which means anyone
  scanning nearby can tell that *the same* device is present again; it is derived through a separate HKDF
  purpose, so it reveals nothing about the key that encrypts the clipboard.
* **Android strips location metadata from shared media.** When a photo or video comes from the gallery,
  Android hands out a copy with the GPS tags zeroed out unless the app holds the media location
  permission. MacDroidSync deliberately asks for no storage permission at all, so what arrives on the Mac
  is byte identical to what Android provided: the whole file, minus the geotag. Sharing the same file from
  a file manager keeps it intact.
* **No echo loops.** A value received from the peer is never sent back, and an identical value that some
  other app rewrites onto the clipboard is not forwarded twice.
* **A ping rings the phone.** `Ping phone` is a "where did I leave it": the phone plays its own ringtone
  on a loop for 20 seconds and vibrates, showing a heads-up notification with a `Silence` action. Tapping
  the notification, swiping it away, or waiting for the 20 seconds stops it. Ringing uses the ringer
  stream, so a phone set to silent only vibrates, exactly like an incoming call. The Mac still measures
  and shows the round trip time.
* **Secrets are skipped.** Copies marked `org.nspasteboard.ConcealedType`, `TransientType` or
  `AutoGeneratedType` (password managers, clipboard tools) are never sent.
* **Size limit.** Clipboard payloads above 512 KiB are skipped, and the clipboard carries text only.
  Files use the transfer path below, with a limit of 512 MiB per file.
* **The Android status bar icon.** A foreground service must always keep an ongoing notification, and
  Android raises such a notification to at least `IMPORTANCE_LOW` even when its channel asks for
  `IMPORTANCE_MIN`. The disconnected notification therefore uses a fully transparent icon
  (`drawable/ic_stat_idle`): nothing shows up in the status bar, only a silent entry at the bottom of the
  shade, and the real icon appears the moment a Mac connects.
* **Encryption.** Every frame is sealed with AES-256-GCM under a key derived from the pairing code
  (HKDF-SHA256). The server opens with a random challenge that the phone has to echo back sealed, which
  authenticates the pairing without ever putting the code on the wire. Sequence numbers are rejected when
  they do not increase, so frames cannot be replayed.
* **Where the pairing code is stored.** Login keychain on macOS, with a `0600` file next to the offline
  queue as a fallback; `EncryptedSharedPreferences` on Android.

## Tests

Crypto vectors, framing and a full server integration test:

```bash
cd macos && swift test
```

The same vectors on the JVM side:

```bash
cd android
JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ./gradlew :app:testDebugUnitTest
```

The vectors in [PROTOCOL.md](PROTOCOL.md) are asserted by both suites, which is what keeps the Swift and
Kotlin implementations byte compatible.

Debug builds also ship `DebugConfigReceiver`, which lets a script configure and drive the app without the
screen (it is guarded by `android.permission.DUMP`, held by the adb shell but not by ordinary apps, and it
does not exist in release builds):

```bash
adb shell am broadcast --include-stopped-packages \
    -n pl.wojas.macdroidsync/.DebugConfigReceiver -a pl.wojas.macdroidsync.DEBUG_CONFIG \
    --es code PMNS-M99F-8KN8-U9EN --es host 10.0.2.2 --ei port 47831 --ez enabled true --ez beacon true
adb shell am broadcast --include-stopped-packages \
    -n pl.wojas.macdroidsync/.DebugConfigReceiver -a pl.wojas.macdroidsync.DEBUG_CONFIG --es bridge read
adb shell am broadcast --include-stopped-packages \
    -n pl.wojas.macdroidsync/.DebugConfigReceiver -a pl.wojas.macdroidsync.DEBUG_CONFIG --ez lock true
adb logcat -s MacDroidSync
```

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| macOS asks about the local network, or nothing connects | macOS needs the local network permission for the app bundle; allow it, and keep using the signed bundle from `build.sh` rather than the bare binary |
| macOS pauses for a few seconds on the first pairing code read after a rebuild | An ad-hoc signature changes on every build, so the keychain re-evaluates access. Allow it once, or let it fall back to the file store |
| The phone never finds the Mac | Bonjour is blocked on many guest networks and VPNs. Type the Mac's IP address in *Mac address* |
| `Sync is on` but nothing happens after a reboot | Android does not always allow starting a foreground service from the background. Open the app once |
| Incoming clipboard arrives as a notification instead of being applied | *Display over other apps* is not granted |
| On the emulator the clipboard seems to bounce between host and guest | The emulator mirrors the guest clipboard onto the host by itself; that is an emulator feature, not this app |
| Port already in use | Another process holds 47831; change it in *Settings…*, tab *General*, and in the Android app |
| A rebuild changes nothing | `build.sh` always writes `macos/build/MacDroidSync.app`. If you moved the app to `/Applications`, copy the fresh bundle over it again: `cp -R macos/build/MacDroidSync.app /Applications/` |
| The phone shows no icon although the Mac is awake | If the Mac runs docked with the lid closed, the sync is suspended by design; the Mac menu says `Suspended, the lid is closed`. Open the lid to resume |
| macOS asks whether MacDroidSync may access the Downloads folder | Incoming files are saved there; allow it once. Denying it makes every transfer end with `Failed: …` in the menu and a refusal on the phone |
| A shared photo differs from the original by a few bytes near the end | That is Android removing the GPS metadata, see *Android strips location metadata* above. The rest of the file is identical |
| *Send to Mac* does not appear in the share sheet | Some apps only share a preview instead of the file. Try sharing from the gallery or a file manager |
| Sharing from Finder appears to do nothing | Requests are dropped in `~/Library/Application Support/MacDroidSync/share-requests/`. If they pile up there, the app is not running; if they show up under `~/Library/Containers/pl.wojas.MacDroidSync.ShareExtension/…` instead, the extension is an old build that resolved the path inside its sandbox container: rebuild and re-run `pluginkit -a` |
| MacDroidSync is missing from the Share menu | The extension has to be registered and enabled once, see *The Share menu needs one setup step*. Until then use *Send to Android* in the Services menu or *Send files to phone…* in the menu bar |
| *Send to Android* is missing from the Services menu | Run `/System/Library/CoreServices/pbs -flush` and open the app once. Services are indexed per app bundle, so a bundle that moved has to be picked up again |
| The menu says `Missing: <file>` | The file was moved or deleted while it waited in the queue. Only paths are queued, so share it again from its new location |
| A file transfer stops halfway | The Mac deletes its partial file and the phone keeps the file queued, so it is sent again from the start on the next connection. Three unanswered attempts drop it with a notification |
| The clipboard window never seems to do its job | It needs window focus. The log line `Bridge window focus: true` followed by `Bridge acting on focus` is the healthy case; `Bridge acting on timeout` means the skin denied focus and the clipboard may come back empty |

## Layout

```
macos/    Swift package: MacDroidSyncCore (protocol, crypto, server, pasteboard, file transfer both
          ways, outgoing queue) plus the menu bar app, its notifications, the Services provider
          and the Share extension bundled into Contents/PlugIns
android/  Gradle project: Kotlin foreground service, transparent clipboard window, share target,
          file outbox, MediaStore writer for incoming files, main screen plus settings and about
PROTOCOL.md  wire format, crypto, cross platform test vectors
```

## Licence

MacDroidSync is free software by **Marcin Wojas**, released under the **MIT licence**; the full text is
in [LICENSE](LICENSE). It costs nothing, carries no advertising and sends nothing anywhere except to the
Mac and the phone you paired with each other.
