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

Message types: `challenge`, `hello`, `hello-ack`, `clipboard`, `clipboard-ack`,
`request-clipboard`, `ping`, `pong`, `heartbeat`, `bye`, `file-offer`, `file-chunk`,
`file-end`, `file-ack`.

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
