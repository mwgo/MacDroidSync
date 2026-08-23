# MacDroidSync wire protocol v1

A single long lived TCP connection carries clipboard updates in both directions.
The macOS app is the **server** (it listens and advertises itself over Bonjour), the
Android app is the **client** (it discovers, connects and reconnects).

* Default port: **47831** (configurable on both sides, must match)
* Bonjour service type: `_macdroidsync._tcp`, TXT record: `v=1`, `name=<mac device name>`
* Byte order: big endian everywhere
* Text encoding: UTF-8

## 1. Framing

```
+--------+--------+--------+--------+--------+---------------------------+
| length (4 bytes, big endian)      |  kind  |  body (length - 1 bytes)  |
+--------+--------+--------+--------+--------+---------------------------+
```

`length` counts the kind byte plus the body. Frames larger than 4 MiB are rejected
and the connection is closed.

| kind | meaning |
|------|---------|
| `0x01` | plaintext JSON body (**only** valid for the server `challenge` frame) |
| `0x02` | sealed body: `nonce (12) || ciphertext || GCM tag (16)` |

## 2. Cryptography

```
key   = HKDF-SHA256(ikm  = normalized pairing code,
                    salt = "MacDroidSync/v1",
                    info = "clipboard-channel",
                    L    = 32)
nonce = 4 random bytes chosen per connection || 8 byte big endian frame counter
body  = nonce || AES-256-GCM(key, nonce, plaintext) || tag
```

* The pairing code is normalized before key derivation: uppercased, every character
  that is not a letter or a digit removed. `abcd-efgh` and `ABCDEFGH` are the same code.
* Each side keeps its own random nonce prefix and its own counter starting at 1, so a
  nonce is never reused under the same key.
* No associated data is used.
* A frame that fails to decrypt means the pairing codes differ: close the connection.

## 3. Messages

The plaintext of every sealed frame is a JSON object. Absent fields are omitted.

| field | type | notes |
|-------|------|-------|
| `v` | int | protocol version, currently `1` |
| `seq` | int | per direction counter starting at 1, strictly increasing |
| `type` | string | see below |
| `ts` | int | sender clock, milliseconds since the Unix epoch |
| `text` | string | clipboard payload (`clipboard`) |
| `device` | string | human readable device name |
| `deviceId` | string | stable random id of the device |
| `challenge` | string | base64 of the 32 challenge bytes |
| `token` | int | correlates `ping` with `pong`, always fits in a signed 64 bit integer |
| `reason` | string | free form detail for `bye` and for a refused file |
| `fileId` | string | id of one file transfer, shared by its four messages |
| `name` | string | file name chosen by the sender (**untrusted**) |
| `size` | int | file size in bytes, announced in `file-offer` |
| `mime` | string | MIME type, informational |
| `sha256` | string | lowercase hex SHA-256 of the whole file, sent in `file-end` |
| `data` | string | base64 of one `file-chunk` payload |
| `ok` | bool | verdict in `file-ack` |
| `path` | string | where the receiver saved the file (`file-ack` with `ok`) |
| `beacon` | bool | whether the phone broadcasts its presence beacon (`hello`, `presence`) |

Message types: `challenge`, `hello`, `hello-ack`, `clipboard`, `clipboard-ack`,
`request-clipboard`, `ping`, `pong`, `heartbeat`, `bye`, `file-offer`, `file-chunk`,
`file-end`, `file-ack`, `presence`, `lock`.

A receiver drops any message whose `seq` is not greater than the highest `seq` seen on
that connection (replay and reordering protection).

## 4. Session flow

```
client                                        server (macOS)
  |                                              |
  |<---- 0x01 {"type":"challenge","challenge"} ---|   32 random bytes, base64
  |                                              |
  |----- 0x02 {"type":"hello","challenge",...} ->|   proves knowledge of the key
  |<---- 0x02 {"type":"hello-ack",...} ----------|   connection is now authenticated
  |                                              |
  |<---- 0x02 {"type":"clipboard","text"} -------|   every macOS copy, plus the
  |----- 0x02 {"type":"clipboard-ack"} --------->|   queued item after a reconnect
  |                                              |
  |----- 0x02 {"type":"clipboard","text"} ------>|   Android notification action
  |                                              |
  |<---- 0x02 {"type":"ping","token"} -----------|   "Ping phone" menu command
  |----- 0x02 {"type":"pong","token"} ---------->|   server measures the round trip
  |                                              |
  |<---> 0x02 {"type":"heartbeat"} <------------>|   every 15 s while idle
```

* The `hello` must echo the `challenge` verbatim, otherwise the server closes the
  connection. Successful decryption is the actual proof of pairing.
* Nothing but `challenge` may be sent in plaintext; a plaintext frame received at any
  other point is a protocol violation.
* **Liveness**: each side sends a `heartbeat` when it has been idle for 15 s and drops
  the connection when no frame arrives for 30 s. This is what suspends the sync when
  the devices move apart.
* **Offline queue**: while disconnected, macOS keeps only the most recent clipboard
  text (last one wins) and sends it right after `hello-ack`.
* **Echo suppression**: a clipboard value received from the peer is never sent back.
  Both sides remember the SHA-256 of the last applied text.
* Clipboard payloads above 512 KiB are skipped instead of being transferred.

## 5. File transfer

Files travel over the same session and go **both ways**. The sender streams,
the receiver writes: macOS saves into `~/Downloads`, Android into the public
`Download` folder (through MediaStore, so no storage permission is involved).

```
sender                                         receiver
  |-- file-offer {fileId,name,size,mime} ------>|  a refusal is an immediate file-ack
  |-- file-chunk {fileId,data} x N ------------>|  appended to a partial file
  |-- file-end   {fileId,sha256} -------------->|  checksum, then published atomically
  |<-- file-ack  {fileId,ok,path|reason} -------|
```

* One transfer at a time **per direction**, so a file can go each way at once; a
  new `file-offer` supersedes an unfinished one in that direction.
* Chunk payload: **192 KiB** of raw bytes, which stays well below the frame limit
  once base64 adds a third.
* Maximum file size: **512 MiB**. A larger `file-offer` is refused before any
  byte is transferred.
* Nothing incomplete is ever published. macOS writes to
  `<name>.macdroidsync-part` next to the destination and renames it (same volume,
  so the rename is atomic); Android inserts a MediaStore item with `IS_PENDING`
  and only clears that flag at the end. Either way the file is only published
  once `sha256` matches and the byte count equals the announced `size`; anything
  else removes it and answers `file-ack { ok: false, reason }`.
* The name is chosen by the sender and therefore untrusted: the receiver strips
  directories, `..`, control characters and excessive length, then avoids
  collisions (`photo.jpg` becomes `photo (2).jpg` on macOS, `photo (1).jpg` on
  Android, which MediaStore handles itself).
* The sender may keep a few chunks in flight (macOS uses eight) instead of
  waiting for each one to reach the network; the connection preserves order, so
  `file-end` simply queues behind the last chunk.
* `file-ack { ok: false }` at any point ends the transfer: the sender stops
  sending the remaining chunks.
* A connection that drops mid transfer deletes the partial file on the receiver.
  The sender keeps the file queued and sends it again from the beginning: Android
  keeps a copy in its cache, macOS keeps the path in `outbox.json`.
* A sender that gets no `file-ack` within 60 s of `file-end` gives up on that
  attempt and retries later.

## 6. Cross platform test vectors

Both the Swift and the Kotlin test suite assert these values, which keeps the two
implementations byte compatible.

```
pairing code        ABCD-EFGH-JKLM-NPQR
normalized          ABCDEFGHJKLMNPQR
key (hex)           8fbe4a33389056e7d5beebae8fa395bbb3f550ba601a2fa58742825b6729349e
nonce (hex)         0a0b0c0d0000000000000001
plaintext           {"seq":1,"ts":1700000000000,"type":"ping","v":1}
ciphertext (hex)    53ee74cf645d5e54bcd32aa4545e08dd3481b931abaaf9610008bdd6e02f3ac8
                    13e9ab23b25e59c926edff17cc448bc0
tag (hex)           2664ab0c4cacf5f707397bd2ac6c1e3c
complete frame      0000004d02
(hex, 81 bytes)     0a0b0c0d0000000000000001
                    53ee74cf645d5e54bcd32aa4545e08dd3481b931abaaf9610008bdd6e02f3ac8
                    13e9ab23b25e59c926edff17cc448bc0
                    2664ab0c4cacf5f707397bd2ac6c1e3c
```

The file checksum has its own vector, which pins down the hex format as well:

```
file content        MacDroidSync file transfer v1     (29 bytes, UTF-8, no newline)
sha256 (hex)        4f3a7edaac1dc9e52ee41243f6f5d0dec1229bea078dde437c84054b019901c3
```

The presence beacon of section 7 is derived from the same pairing code:

```
service uuid (hex)  993bbecdd85ea9a50f0f705378a22fac
service uuid        993BBECD-D85E-A9A5-0F0F-705378A22FAC
slot                56666666          (unix second 1700000000 divided by 30)
flags               0x01              (auto lock allowed)
payload (hex)       01ae64c93d94      ([flags][5 byte HMAC])
payload, slot - 1   01a9b137d4a0      still accepted
payload, slot + 1   019354cefcd3      still accepted
```

## 7. Presence beacon

Independent of the TCP session, the phone broadcasts a Bluetooth LE advertisement
that lets macOS measure **how far away it is** and lock the screen once the user
has walked off with it. Nothing is ever scanned or connected to from the phone,
and no payload beyond the token below is broadcast.

```
        phone (advertiser)                       Mac (scanner)
  |-- ADV_NONCONN_IND every 250 ms -------------->|  RSSI measured per packet
  |   service UUID + [flags][HMAC of the slot]    |  mean over a time window
  |                                               |  mean too low or nothing
  |                                               |  for a while -> lock
```

### Identity

```
serviceUuid = HKDF-SHA256(ikm  = normalized pairing code,
                          salt = "MacDroidSync/v1",
                          info = "presence-beacon", L = 16)
beaconKey   = HKDF-SHA256(same ikm and salt, info = "presence-token", L = 32)
slot        = floor(unix seconds / 30)
token       = HMAC-SHA256(beaconKey, "MDS1" || BE64(slot) || flags)[0..4]
payload     = flags || token                                   (6 bytes)
```

* The 16 derived bytes are used **verbatim** as the 128 bit service UUID; they are
  not shaped into an RFC 4122 version, because both sides only ever compare them.
* Android rotates its advertising address, so the address is never an identifier.
  The service UUID is what tells the Mac this is its phone, and the token is what
  stops a recorded packet from working forever.
* `flags` bit 0 means "the phone agrees to the Mac locking itself". The flags are
  covered by the HMAC, so they cannot be flipped in flight. Other bits are
  reserved and must be zero.
* The Mac accepts `slot - 1`, `slot` and `slot + 1`, which tolerates a minute of
  clock skew. Everything else is ignored and logged as a bad token, which is the
  signal that the two devices disagree about either the pairing code or the time.
* Forty bits of HMAC are enough here: a forgery achieves nothing but a Mac that
  fails to lock, and there is no feedback channel to guess against.

### Packet layout

Everything travels in the **primary advertisement**; nothing is put in a scan
response, because macOS merges one into `advertisementData` only when it happens
to have it, and a token that is missing from part of the callbacks would starve
the average.

```
flags element                        3 bytes
complete 128 bit service UUID       18 bytes
manufacturer data 0xFFFF + payload   4 + 6 bytes
-----------------------------------------------
                                    31 bytes, the legacy advertising limit
```

Company id `0xFFFF` is the value reserved for testing, so no Bluetooth SIG
assignment is involved. The advertisement is non-connectable: it is a beacon, and
nothing may open a GATT connection to it. It is rebuilt at every slot boundary,
which is what publishes the next token.

### Deciding that the user left

The Mac never acts on a single reading. A hand over the phone, a passing body or
a closed door costs 10 to 15 dB instantly, so every verdict comes from the
**mean RSSI over a time window**:

* the mean needs at least three samples in the window before it means anything;
* the phone counts as leaving once the mean falls below the away threshold, or
  once no packet has arrived for `lostAfter` seconds - walking out of range
  rarely looks like a slope, the packets simply stop;
* coming back needs a **higher** mean than leaving did (8 dB of hysteresis by
  default), so the state cannot flap at the edge of the range;
* the leaving condition has to hold for the whole grace period; a warning is
  raised a few seconds before the end, and the user can stop the lock there;
* after a lock the Mac disarms itself and will not lock again until it has seen
  the phone anew.

Defaults, all configurable on the Mac: 20 s window, away below -80 dBm, back at
-72 dBm, 15 s without a packet counts as lost, 20 s of grace.

**Nothing is ever locked before the phone has been recognised at least once.**
That single rule is what makes every failure safe: Bluetooth off on either side,
a mismatched pairing code, a phone that never had the feature on - all of them
end in a Mac that simply never locks itself.

### Turning it off

The switch lives on the phone, and flipping it off stops the advertising. So does
switching off the clipboard sync: the beacon rides along with the session rather
than running on its own. Either way, to the Mac the silence looks exactly like the
user walking away, so the phone says so explicitly over the encrypted session
before it stops:

```
phone                                          Mac
  |-- hello    { ..., beacon: false } --------->|  known from the handshake on
  |-- presence { beacon: false } -------------->|  the switch was just flipped
```

The Mac disarms while `beacon` is false and arms again when it turns true. If the
switch is flipped while the phone is not connected to the Mac, the Mac sees the
beacon disappear and locks **once**; after that it is disarmed, because the phone
is never seen again.

A user who calls off a countdown puts the Mac back into the unarmed state rather
than pausing it: nothing is locked until the phone has been seen again, and from
that sighting on the auto lock behaves exactly as it did before.

### Locking on demand

```
phone                                          Mac
  |-- lock ----------------------------------->|  locks immediately
```

`lock` carries nothing but its type. It is **not** gated on the auto lock being
switched on, on the beacon, or on any measurement: the user pressed a button,
which is a clearer signal than any distance estimate, and locking is the safe
direction. The Mac ignores it only when the screen is already locked.
