# XM6-Connect protocol reference

This document describes the part of Sony's headphone control protocol that XM6-Connect uses to
control a Sony WH-1000XM6 from macOS over Bluetooth Classic RFCOMM. It covers the transport, the
frame format, sequence numbers and acknowledgements, the opening handshake, and the messages for
every setting XM6-Connect reads or writes: noise cancelling and ambient sound, battery, equalizer,
speak-to-chat, listening mode, automatic power off, pause when taken off, and the multipoint device
list with its playback-source switch. It is meant for developers who want to understand
XM6-Connect's traffic or reimplement the same subset elsewhere.

Sony does not publish this protocol. This document describes only behaviour observed on one
headset model and firmware, and behaviour that XM6-Connect implements. It is not an official
specification, and it may be wrong or incomplete for other models, other firmware versions, or
situations XM6-Connect has not met.

The Gadgetbridge project's open-source work on Sony headphones (https://gadgetbridge.org) informed
this project.

## Status labels

Behavioural facts carry one of three labels. When a whole table or list shares a status, it is
stated once for that block.

| Label | Meaning |
|---|---|
| **Observed** | Seen on a WH-1000XM6 running firmware 3.1.5. |
| **Implemented** | What XM6-Connect sends or accepts. Not independently confirmed on the device. |
| **Unknown** | Not determined. |

## Conventions

- Bytes are hexadecimal, lowercase, separated by spaces: `3e 0c 00`. A decimal value, where
  useful, follows in parentheses: level `14` (20).
- *Host* means the Mac running XM6-Connect. *Headset* means the WH-1000XM6.
- A *payload* is a message body, starting with its opcode. A *frame* is a payload wrapped for the
  wire as described in section 2.
- Example frames use sequence bit `00` unless stated otherwise. With bit `01`, the sequence byte is
  `01` and the checksum is one higher (escaped if that makes it `3c`, `3d` or `3e`).
- Headset payloads marked *(illustrative)* are built from the documented layout and are not
  claimed to be captures. Unmarked headset payloads were observed. Full frames around observed
  payloads are built with the rules in section 2, except where a frame is said to be captured.

---

## 1. Transport

| Item | Value | Status |
|---|---|---|
| Link | Bluetooth Classic, RFCOMM. The headset must already be paired with the Mac. | Implemented |
| Service discovery | SDP lookup of a vendor service UUID on the paired headset. | Implemented |
| Service UUID, protocol v2 | `956c7b26-d49a-4ba8-b03f-b17d393cb6e2` (tried first) | Implemented |
| Service UUID, protocol v1 | `96cc203e-5068-46ad-b32d-e316f5e069ba` (tried second) | Implemented |
| RFCOMM channel | Read from the SDP record on every connection. XM6-Connect does not assume a fixed channel number. | Implemented |
| Largest single write | 65535 bytes | Implemented |

Connection steps (Implemented):

1. If macOS has no Bluetooth link to the headset, open one.
2. Look for a cached SDP record for the v2 UUID, then the v1 UUID. If neither is cached, run a full
   SDP query and look again.
3. Read the RFCOMM channel ID from the record and open that channel.
4. If the request to open the channel fails immediately, try once more after 1.5 s. Just after a
   reconnect, the previous control channel can still be closing.
5. Report the channel as open after a settle delay of 0.15 s when step 1 created the link, or
   0 s when the link already existed (see section 5.3).

On macOS, IOBluetooth delivers RFCOMM data callbacks through the main run loop. A process that
does not run the main run loop receives no inbound data.

---

## 2. Framing

### 2.1 Frame layout

A frame is a start byte, an escaped body, and an end byte.

| Role | Byte |
|---|---|
| Start | `3e` |
| End | `3c` |
| Escape introducer | `3d` |

The body, before escaping:

| Offset | Size | Field | Notes |
|---|---|---|---|
| 0 | 1 | Message type | Section 3 |
| 1 | 1 | Sequence number | `00` or `01`, section 4 |
| 2 | 4 | Payload length | Unsigned, big-endian, counts payload bytes only |
| 6 | N | Payload | N = payload length |
| 6 + N | 1 | Checksum | Section 2.2 |

The smallest frame has an empty payload and is 9 bytes long with its delimiters. An ACK is an
example.

Observed: frames from the headset follow this layout. The frame
`3e 0c 00 00 00 00 03 e7 04 00 fa 3c` was captured from the headset:

| Bytes | Field |
|---|---|
| `3e` | Start |
| `0c` | Type: main table |
| `00` | Sequence number |
| `00 00 00 03` | Payload length: 3 |
| `e7 04 00` | Payload |
| `fa` | Checksum |
| `3c` | End |

### 2.2 Checksum

The checksum is the sum of every unescaped body byte from the message type through the last
payload byte, modulo 256. It excludes the delimiters. It is computed before escaping and is then
escaped like any other body byte.

For the captured frame above: `0c + 00 + 00 + 00 + 00 + 03 + e7 + 04 + 00 = fa`.

### 2.3 Escaping

Every body byte equal to one of the three special bytes is replaced by `3d` followed by that byte
minus `10` (16):

| Body byte | On the wire |
|---|---|
| `3c` | `3d 2c` |
| `3d` | `3d 2d` |
| `3e` | `3d 2e` |
| any other | unchanged |

Escaping covers the type, sequence, length, payload and checksum bytes. The delimiters are never
escaped. A conforming frame therefore never contains a bare `3c` or `3e` between its delimiters.
Unescaping reverses the table: `3d 2c` → `3c`, `3d 2d` → `3d`, `3d 2e` → `3e`.

Implemented: a frame containing `3d` followed by any byte other than `2c`, `2d` or `2e`, or a
`3d` directly before the end byte, is rejected.

### 2.4 Worked examples

Encoding the payload `23 00 3d 00` (a battery reply, section 7.2) as type `0c`, sequence `00`:

| Step | Bytes |
|---|---|
| Body without checksum | `0c 00 00 00 00 04 23 00 3d 00` |
| Checksum: `0c + 04 + 23 + 3d` | `70` |
| Body with checksum | `0c 00 00 00 00 04 23 00 3d 00 70` |
| Escape `3d` | `0c 00 00 00 00 04 23 00 3d 2d 00 70` |
| Add delimiters | `3e 0c 00 00 00 00 04 23 00 3d 2d 00 70 3c` |

A payload made of special bytes, `3e 3c 3d 00`, sent as type `0c` with sequence `01`:

```
3e 0c 01 00 00 00 04 3d 2e 3d 2c 3d 2d 00 c8 3c
```

The checksum is `0c + 01 + 04 + 3e + 3c + 3d = c8`.

### 2.5 Decoding a frame

Implemented: a candidate frame, from its start byte through its end byte, is accepted only if all
of these hold. Otherwise it is dropped.

1. It is at least 9 bytes long, starts with `3e` and ends with `3c`.
2. The bytes between the delimiters unescape cleanly (section 2.3).
3. The unescaped body is at least 7 bytes long.
4. The type byte is `01`, `0c` or `0e`.
5. The length field equals the number of payload bytes actually present.
6. The checksum matches.

### 2.6 Reassembling the byte stream

RFCOMM reads arrive in arbitrary pieces. One read can hold several frames or part of a frame, and
a frame can be split anywhere, including inside an escape pair. XM6-Connect buffers reads and
extracts frames as follows (Implemented):

1. Discard every byte before the first `3e`, including a stray `3d`. Escape processing applies only
   inside a frame.
2. The first `3c` after that `3e` ends the candidate frame.
3. If no `3c` has arrived yet, keep the buffer for the next read. If it grows beyond 8192 bytes
   without an end byte, discard it. The largest frame XM6-Connect receives, the multipoint device
   list, is well under 1 KB (Observed).
4. If the candidate decodes, deliver it and continue after its end byte.
5. If it does not decode and contains another `3e` after its first byte, resume from that inner
   `3e`. A truncated frame followed by a complete one therefore loses only the truncated frame.
6. Otherwise drop the candidate through its end byte and continue.

Example: one read containing `3e 0c 00 00 00` followed by `3e 0c 01 00 00 00 03 57 04 20 8b 3c`
yields exactly one message, the second frame.

---

## 3. Message types

| Type byte | Name used here | Carries |
|---|---|---|
| `01` | ACK | Acknowledgement. The payload is always empty. |
| `0c` | Main table | The handshake and every feature except multipoint. |
| `0e` | Second table | In XM6-Connect, only the multipoint device list and the playback-source switch. |

Implemented: opcodes are interpreted per table. The same opcode byte means different things in
`0c` and `0e` frames, so a decoder routes on the pair (type, opcode). Frames of any other type are
rejected.

---

## 4. Sequence numbers and acknowledgements

### 4.1 Stop-and-wait

Implemented:

- Every `0c` and `0e` frame carries a sequence bit, `00` or `01`. The host starts every session
  (every channel open) at `00`. The first frame of a session is INIT, sent with `00`.
- The host keeps at most one unacknowledged data frame outstanding. It sends the next one only
  after the matching ACK arrives. Queries and writes in both tables share this single sequence.
- A frame with bit *s* is acknowledged by an ACK whose bit is the complement of *s*. When the host
  accepts that ACK, it adopts the ACK's bit as its current bit and uses it for its next data frame.
  The host's bits therefore run `00`, `01`, `00`, `01` as frames are acknowledged.
- The host accepts an ACK only while a frame is outstanding and only if the ACK's bit is the
  complement of that frame's bit. Stale ACKs, duplicate ACKs and ACKs that arrive while nothing is
  outstanding are ignored.
- The host waits only for the ACK, never for a reply, before sending its next frame. Replies and
  events are matched by opcode and subtype, never by sequence number.

### 4.2 Acknowledging the headset

- The host acknowledges every inbound `0c` or `0e` frame that has a non-empty payload, whether or
  not it can decode or uses the payload. The ACK's bit is the complement of the received frame's
  bit (the received byte XOR `01`), not the host's own current bit. (Implemented)
- Observed: acknowledging with the wrong bit makes the headset treat its messages as
  unacknowledged, and it stops answering.
- ACK frames are never acknowledged. Data frames with an empty payload are neither acknowledged
  nor decoded. (Implemented)
- ACKs are not data frames. The host sends them even while its own frame is outstanding, and they
  do not change the host's current bit. (Implemented)
- XM6-Connect does not track the headset's sequence bits and does not drop repeated inbound
  frames. A repeated report applies the same value again. It accepts any value in the sequence
  byte of an inbound frame. (Implemented)
- How the headset chooses its own sequence bits: Unknown.

The two ACK frames:

| ACK bit | Frame |
|---|---|
| `00` | `3e 01 00 00 00 00 00 01 3c` |
| `01` | `3e 01 01 00 00 00 00 02 3c` |

### 4.3 Retransmission

Implemented:

- If no ACK arrives within 3 s, the host resends the identical frame, with the same sequence bit,
  byte for byte. It resends at most twice.
- After the third timeout, the host treats the session as failed and writes nothing more on it.
- The INIT frame is exempt from this timeout while the handshake is in progress (section 5.3).
- Once the channel has closed or failed, nothing is retransmitted.

### 4.4 Example exchange

A clean session start. Headset sequence bits are illustrative.

| # | Direction | Frame | Meaning |
|---|---|---|---|
| 1 | host → headset | `3e 0c 00 00 00 00 02 00 00 0e 3c` | INIT, bit `00` |
| 2 | headset → host | `3e 01 01 00 00 00 00 02 3c` | ACK of 1. The host's bit becomes `01`. |
| 3 | headset → host | `3e 0c 00 00 00 00 08 01 00 00 00 00 00 00 00 15 3c` | INIT reply *(illustrative bytes after `01`)* |
| 4 | host → headset | `3e 01 01 00 00 00 00 02 3c` | ACK of 3 |
| 5 | host → headset | `3e 0c 01 00 00 00 02 66 19 8e 3c` | Ambient query, bit `01` |
| 6 | headset → host | `3e 01 00 00 00 00 00 01 3c` | ACK of 5. The host's bit becomes `00`. |
| 7 | headset → host | `3e 0c 00 00 00 00 09 67 19 01 01 01 00 08 00 00 a0 3c` | Ambient reply |
| 8 | host → headset | `3e 01 01 00 00 00 00 02 3c` | ACK of 7 |
| 9 | host → headset | `3e 0c 00 00 00 00 02 22 00 30 3c` | Battery query, bit `00` |

XM6-Connect accepts frames 2 and 3 in either order, and a reply such as frame 7 before or after
its ACK (Implemented).

---

## 5. Handshake

### 5.1 Messages

| Direction | Type | Payload | Status |
|---|---|---|---|
| host → headset, INIT | `0c` | `00 00` | Implemented. It is the first frame of every session. |
| headset → host, ACK of INIT | `01` | empty, bit = complement of the INIT's bit | Observed |
| headset → host, INIT reply | `0c` | `01`, then version-dependent bytes. 8 bytes in total on the XM6. | Observed |

On a fresh session the INIT frame is `3e 0c 00 00 00 00 02 00 00 0e 3c`.

Observed: the ACK and the INIT reply are separate frames. The reply has arrived up to about
0.81 s after the ACK.

### 5.2 Protocol version

The version is inferred from the INIT reply's payload length, opcode included:

| Payload length | Version | Status |
|---|---|---|
| 4 | v1 | Implemented |
| 8 | v2 | Observed: the XM6 sends an 8-byte reply. |
| other | unknown. The handshake still completes. | Implemented |

XM6-Connect does not interpret the bytes after `01`. Whether they carry reliable version
information: Unknown. Only a `0c` frame carries the INIT reply. Opcode `01` in a `0e` frame is not
treated as one.

### 5.3 Timing rules

1. **Settle delay.** Observed: a freshly established Bluetooth link (just connected or just woken)
   can drop the first write. Implemented: the transport therefore waits 0.15 s after the channel
   opens before reporting it open on a new link, and 0 s on a link that already existed.
2. **INIT first.** Implemented: when the channel is reported open, the host sends INIT at once,
   with bit `00`. It sends no other data frame until the INIT reply has arrived. Commands issued
   meanwhile wait in a queue of up to 64 entries; beyond that, the oldest is dropped.
3. **INIT resend.** Implemented: while no INIT reply has arrived, the host resends INIT every 1 s,
   but only within 5 s of the first INIT. INIT therefore goes out at most five times, for example
   at 0, 1, 2, 3 and 4 s.
   - If the earlier INIT has not been acknowledged, the resend is the identical frame with the same
     bit.
   - If it was acknowledged but no reply followed, the resend is a new INIT carrying the adopted
     bit, sent 1 s after that ACK. The 1 s grace covers the ACK-to-reply gap in 5.1.
4. **Reply latency.** Observed: the 99th-percentile INIT reply latency is about 0.98 s. On a
   freshly established link the headset has stayed silent for up to about 1.7 s.
5. **No ACK-timeout failure for INIT.** Implemented: while the handshake is in progress, the
   3 s ACK timeout of section 4.3 does not apply to INIT. The handshake verdict belongs to the
   XM6-Connect agent: if no reply arrives within 5 s of the handshake starting, the agent ends the
   attempt (section 9). If the reply arrives while the INIT itself is still unacknowledged, the
   ordinary ACK timeout then applies to the INIT.
6. **One reply counts.** Implemented: the first INIT reply completes the handshake. A second reply,
   for example to a resent INIT, has no effect. A reply that arrives after the channel has closed or
   failed has no effect either.
7. **Queued commands.** Implemented: after the reply arrives and the INIT has been acknowledged,
   queued commands go out in order under the rules of section 4.
8. **No automatic sweep.** Implemented: completing the handshake does not by itself send any query.
   The XM6-Connect agent requests the state sweep (section 8).

---

## 6. Payload conventions

- Byte 0 of every payload is the **opcode**. For every feature here, byte 1 is a **subtype** that
  selects one parameter within the opcode family.
- Most features use a family of four consecutive opcodes: query (base), reply (base + 1), write
  (base + 2) and event (base + 3). The headset sends events unprompted. Replies and events share
  one layout.
- One family can carry unrelated parameters told apart by subtype. For example, `f6`–`f9` carry
  speak-to-chat on subtype `0c` and pause when taken off on subtype `01`. Each (type, opcode,
  subtype) combination XM6-Connect uses maps to one feature.
- Per-feature decoders do not check byte 0. The dispatcher (section 7.9) has already chosen the
  decoder by opcode. (Implemented)

| Feature | Type | Query | Reply | Write | Event | Subtype |
|---|---|---|---|---|---|---|
| Noise cancelling and ambient sound | `0c` | `66` | `67` | `68` | `69` | `19` read, `17` write |
| Battery | `0c` | `22` | `23` | — | `25` | `00` |
| Equalizer | `0c` | `56` | `57` | `58` | `59` | `04` (and `00` read) |
| Speak-to-chat on/off | `0c` | `f6` | `f7` | `f8` | `f9` | `0c` |
| Speak-to-chat settings | `0c` | `fa` | `fb` | — (not used) | `fd` | `0c` |
| Background music and room size | `0c` | `e6` | `e7` | `e8` | `e9` | `09` |
| Cinema | `0c` | `e6` | `e7` | `e8` | `e9` | `04` |
| Automatic power off | `0c` | `26` | `27` | — (not used; `28` observed, section 7.6) | `29` | `05` |
| Pause when taken off | `0c` | `f6` | `f7` | — (not used) | `f9` | `01` |
| Multipoint device list | `0e` | `36` | `37` | — | `39` | `02` |
| Playback-source switch | `0e` | — | — | `3c` | — | `01` |

---

## 7. Features

### 7.1 Noise cancelling and ambient sound

Opcodes `66` query, `67` reply, `68` write, `69` event. The subtype selects a layout, called a
dialect here.

| Subtype | How XM6-Connect uses it | Status |
|---|---|---|
| `19` | The only ambient query sent (`66 19`). `67 19` replies and `69 19` events carry the state. | Observed |
| `17` | Every ambient write uses `68 17`. `67 17` replies are ignored. `69 17` events are decoded. | Observed: `66 17` is always answered with the constant `67 17 00 00 00 00 00`, including while the headset is in noise cancelling or ambient mode. It carries no state. |
| `15` | Not queried. `67 15` and `69 15` are decoded if they arrive. | Observed: `66 15` is acknowledged but never answered. |
| `22` | Decoded if it arrives. It has never been seen from the XM6. | Implemented. Its purpose: Unknown. |

Each of these held for every query in XM6-Connect's protocol logs, which contain more than 140
queries of each of `66 15` and `66 17`.

#### Queries

Observed:

- `66 19` is answered with a 9-byte `67 19` in the event layout below, 17–37 ms after the query.
- Every `67` reply in the logs followed a `66` query with the same subtype in the same session. No
  unsolicited `67` reply has been seen.
- A `69 19` event can arrive between a query and its reply.
- When `66 17` and `66 19` were asked in that order, the `67 17` reply arrived 18–38 ms before the
  `67 19` reply, in a separate read.

XM6-Connect therefore asks only `66 19`.

#### Reply and event layout, subtype 19

| Offset | Field | Values |
|---|---|---|
| 0 | Opcode | `67` reply, `69` event |
| 1 | Subtype | `19` |
| 2 | Unknown | Observed: `01` in every reply and in every event that followed a host write, `00` in unprompted events. Meaning: Unknown. A decoder must accept both. |
| 3 | On/off | `00` off. Implemented: any non-zero value means on. |
| 4 | Ambient flag | `01` ambient, any other value noise cancelling |
| 5 | Focus on voice | `00` off, `01` on. Anything else is rejected. |
| 6 | Level | `00`–`14` (0–20). Anything else is rejected. |
| 7 | Unknown | Observed: always `00`. Not read. |
| 8 and later | Unknown | Observed: `00` at offset 8. Not read. |

Observed: every `19` frame seen was 9 bytes long. Implemented: any length of 7 bytes or more is
accepted.

The mode is off when the on/off byte is `00`. Otherwise the ambient flag decides between ambient
and noise cancelling.

Observed facts about the reported state:

- **Level outside ambient mode.** In noise cancelling and off reports, the level byte is the
  retained ambient level, not the level of the last write. Noise cancelling writes at levels 8, 1
  and 0 and off writes at level 1 were all followed by reports of level 20, the retained level.
  An off write at level 13 made right after ambient level 13 reported 13.
- **Reply equals event.** In every logged pair of a write followed by a `66 19` query, the `67 19`
  reply equalled the preceding `69 19` event byte for byte. That includes a case where the written
  level (8) differed from the reported one (20), so the reply reports headset state rather than
  echoing the write.
- Unknown: whether the `67 19` reply tracks changes made with the headset's own controls or in the
  phone app. Every state change observed so far was made by a host write.

#### Other dialects

Implemented. Only the constant `67 17` reply has been observed from the XM6.

| Offset | `15`, `22`, or `17` at 7 bytes | `17` at 8 bytes |
|---|---|---|
| 0 | Opcode | Opcode |
| 1 | Subtype | Subtype |
| 2 | Not read | Not read |
| 3 | On/off: `00` off, `01` on, anything else rejected | Same |
| 4 | Ambient flag: `01` ambient | Same |
| 5 | Focus on voice | Mode byte: `03` or `05` means noise cancelling (see below). Meaning of its values: Unknown. |
| 6 | Level | Focus on voice |
| 7 | — | Level |

- Subtypes `15` and `22` must be exactly 7 bytes long, and subtype `17` must be 7 or 8 bytes long.
  Other lengths are rejected.
- Mode when on: subtype `22` always means ambient. Subtype `17` at 8 bytes with mode byte `03`
  or `05` means noise cancelling. Otherwise the ambient flag decides.
- Focus and level use the same rules as subtype `19`.
- A `67 17` reply is dropped before decoding, because the XM6 always sends it as a constant. A
  `69 17` event is decoded.

#### Write

The write is always the same 7-byte shape:

| Offset | Value |
|---|---|
| 0 | `68` |
| 1 | `17`, always, whatever dialect the headset reported |
| 2 | `01`, always. Meaning: Unknown. |
| 3 | `00` for off, `01` for noise cancelling or ambient |
| 4 | `01` for ambient, otherwise `00` |
| 5 | Focus on voice: `00` or `01` |
| 6 | Level, `00`–`14` (0–20). XM6-Connect clamps it to that range. |

- Observed: every ambient write in XM6-Connect's protocol logs used this form. Each was
  acknowledged and followed by exactly one `69 19` event. Across 23 logged writes the event came a
  median of about 73 ms after the write (90th percentile about 235 ms, longest about 806 ms).
- Unknown: whether the headset accepts `68 19`, `68 15` or 8-byte writes. XM6-Connect never sends
  them.
- Implemented: a write always carries a level and a focus value, even for noise cancelling or off.
  When a user changes only part of the setting (the mode, the focus, or the ambient level, from the
  widget, the menu-bar app, the command line, or the cycle action), the agent fills in the rest from
  the latest ambient report received in the current session. Changing the ambient level also
  selects ambient mode; focus comes from the session's report. If no report has arrived yet in this
  session, the write waits for one. Changes made before a write is sent are combined into one
  write. For 1 s after its own write the agent uses that write, not the last report, as the basis
  for the next one, because the headset's event can arrive after the next change. The cycle action
  goes from noise cancelling to ambient to off, then back to noise cancelling.

#### Examples

| Message | Payload | Frame |
|---|---|---|
| Query (first sweep query, bit `01`) | `66 19` | `3e 0c 01 00 00 00 02 66 19 8e 3c` |
| Reply: ambient, focus off, level 8 | `67 19 01 01 01 00 08 00 00` | `3e 0c 00 00 00 00 09 67 19 01 01 01 00 08 00 00 a0 3c` |
| Reply: off, retained level 13 | `67 19 01 00 00 00 0d 00 00` | `3e 0c 00 00 00 00 09 67 19 01 00 00 00 0d 00 00 a3 3c` |
| Event after a write: noise cancelling, level 20 | `69 19 01 01 00 00 14 00 00` | `3e 0c 00 00 00 00 09 69 19 01 01 00 00 14 00 00 ad 3c` |
| Unprompted event: noise cancelling, level 20 | `69 19 00 01 00 00 14 00 00` | `3e 0c 00 00 00 00 09 69 19 00 01 00 00 14 00 00 ac 3c` |
| Constant reply to `66 17` (ignored) | `67 17 00 00 00 00 00` | `3e 0c 00 00 00 00 07 67 17 00 00 00 00 00 91 3c` |
| Write: noise cancelling, level 20 | `68 17 01 01 00 00 14` | `3e 0c 00 00 00 00 07 68 17 01 01 00 00 14 a8 3c` |
| Write: ambient, focus on, level 8 (bit `01`) | `68 17 01 01 01 01 08` | `3e 0c 01 00 00 00 07 68 17 01 01 01 01 08 9f 3c` |
| Write: off, level 20 | `68 17 01 00 00 00 14` | `3e 0c 00 00 00 00 07 68 17 01 00 00 00 14 a7 3c` |

The write built from the event `69 19 01 01 00 00 14 00 00` is `68 17 01 01 00 00 14`.

### 7.2 Battery

Opcodes `22` query, `23` reply, `25` event. There is no write. Implemented throughout.

Query: `22 00`. Kind `00` selects the single battery of an over-ear headset.

| Offset | Field | Rule |
|---|---|---|
| 0 | Opcode | `23` or `25` |
| 1 | Battery kind | Must be `00`, otherwise rejected |
| 2 | Level, percent | `00`–`64` (0–100), otherwise rejected |
| 3 | Charging | `01` charging. Any other value means not charging. |
| 4 and later | — | Ignored |

Payloads shorter than 4 bytes are rejected.

| Message | Payload | Frame |
|---|---|---|
| Query | `22 00` | `3e 0c 00 00 00 00 02 22 00 30 3c` |
| Reply: 61 %, not charging *(illustrative)* | `23 00 3d 00` | `3e 0c 00 00 00 00 04 23 00 3d 2d 00 70 3c` |
| Event: 80 %, charging *(illustrative)* | `25 00 50 01` | `3e 0c 00 00 00 00 04 25 00 50 01 86 3c` |

The reply frame shows escaping: the level byte `3d` goes on the wire as `3d 2d`. A level of 101
(`23 00 65 00`) is rejected.

### 7.3 Equalizer

Opcodes `56` query, `57` reply, `58` write, `59` event.

| Subtype | Use | Status |
|---|---|---|
| `04` | Read and write | Observed: the XM6's own events use `04`, and it is the only subtype on which the headset accepts writes. Writes on `00` are silently ignored. |
| `00` | Read only. Queried as a fallback. | Unknown: whether the XM6 answers `56 00`. |
| `02` | Accepted in replies and events, never written | Implemented |

Queries: `56 04`, then `56 00`.

#### Reply and event layout

| Offset | Field | Rule |
|---|---|---|
| 0 | Opcode | `57` or `59` |
| 1 | Subtype | `00`, `02` or `04`, otherwise rejected |
| 2 | Preset code | Kept as reported. It may be a code outside the table below. |
| 3 | Band count | `00`, `06` or `0a`, otherwise rejected |
| 4 … 3 + count | Band values, lowest frequency first | Gain = byte − bias. The bias is 6 for 10 bands (Observed) and 10 for 6 bands (Implemented; not seen from the XM6). Every gain must lie in −6…+6, otherwise the payload is rejected. |
| later | — | Ignored |

Payloads shorter than 4 bytes, or shorter than 4 + band count, are rejected. A band count of 0 gives
an empty band list. Band centre frequencies: Unknown.

#### Presets

| Preset | Code | Status |
|---|---|---|
| Off | `00` | Implemented |
| Game | `20` | Observed: the headset reports `20` after "Game" is chosen in Sony's app. |
| Heavy | `30` | Implemented |
| Clear | `31` | Implemented |
| Hard | `32` | Implemented |
| Soft | `33` | Implemented |
| Custom | `a0` | Implemented |

#### Writes

- Preset: `58 04 <preset> 00`.
- Band curve: `58 04 a0 <count> <gain + 6> …`, one byte per band. XM6-Connect always sends 10 bands
  and clamps each gain to −6…+6 before adding the bias. Writing a curve selects the custom preset
  `a0`.
- Observed: the curve write `58 04 a0 0a 09 08 07 06 05 04 03 06 06 06` (gains +3 +2 +1 0 −1 −2 −3
  0 0 0) was reported back by the headset byte for byte, and a later read returned the same curve.

| Message | Payload | Frame |
|---|---|---|
| Query | `56 04` | `3e 0c 00 00 00 00 02 56 04 68 3c` |
| Reply: Game preset | `57 04 20 0a 00 04 08 09 07 05 07 09 06 04` | `3e 0c 00 00 00 00 0e 57 04 20 0a 00 04 08 09 07 05 07 09 06 04 da 3c` |
| Write: Heavy preset | `58 04 30 00` | `3e 0c 00 00 00 00 04 58 04 30 00 9c 3c` |
| Write: custom curve | `58 04 a0 0a 09 08 07 06 05 04 03 06 06 06` | `3e 0c 00 00 00 00 0e 58 04 a0 0a 09 08 07 06 05 04 03 06 06 06 5c 3c` |

The Game reply decodes to gains −6 −2 +2 +3 +1 −1 +1 +3 0 −2. A reply with band count `07`, or with a
band byte of `0d` (gain +7), is rejected.

### 7.4 Speak-to-chat

#### On/off

Opcodes `f6` query, `f7` reply, `f8` write, `f9` event, subtype `0c`. Query: `f6 0c`.

The reply or event payload must be exactly 4 bytes (Implemented):

| Offset | Field | Rule |
|---|---|---|
| 0 | Opcode | `f7` or `f9` |
| 1 | Subtype | Must be `0c` |
| 2 | Enabled, inverted | `00` on, `01` off, anything else rejected. Observed: the inversion. |
| 3 | Unknown | Not read |

Write: `f8 0c <00 for on, 01 for off> 01` (Implemented). XM6-Connect always sends the trailing byte
as `01`. Its meaning: Unknown.

| Message | Payload | Frame |
|---|---|---|
| Query | `f6 0c` | `3e 0c 00 00 00 00 02 f6 0c 10 3c` |
| Reply: on *(illustrative)* | `f7 0c 00 01` | `3e 0c 00 00 00 00 04 f7 0c 00 01 14 3c` |
| Write: on | `f8 0c 00 01` | `3e 0c 00 00 00 00 04 f8 0c 00 01 15 3c` |
| Write: off | `f8 0c 01 01` | `3e 0c 00 00 00 00 04 f8 0c 01 01 16 3c` |

#### Settings

Opcodes `fa` query, `fb` reply, `fd` event, subtype `0c`. Query: `fa 0c`.
Implemented throughout.

The reply or event payload must be exactly 4 bytes. Values outside these lists are rejected:

| Offset | Field | Values |
|---|---|---|
| 0 | Opcode | `fb` or `fd` |
| 1 | Subtype | `0c` |
| 2 | Sensitivity | `00` auto, `01` high, `02` low |
| 3 | Timeout | `00` short, `01` standard, `02` long, `03` off |

XM6-Connect reads these settings and never writes them. The write form is not documented here.

| Message | Payload | Frame |
|---|---|---|
| Query | `fa 0c` | `3e 0c 00 00 00 00 02 fa 0c 14 3c` |
| Reply: auto, standard *(illustrative)* | `fb 0c 00 01` | `3e 0c 00 00 00 00 04 fb 0c 00 01 18 3c` |

### 7.5 Listening mode: background music, room size and cinema

Opcodes `e6` query, `e7` reply, `e8` write, `e9` event. This family carries two independent on/off
parameters. Both are inverted on the wire: `00` means enabled (Observed).

#### Background music, subtype 09

| Offset | Field | Rule |
|---|---|---|
| 0 | Opcode | `e7` or `e9` |
| 1 | Subtype | Must be `09` |
| 2 | Enabled, inverted | `00` on. Any other value means off. |
| 3 | Room size | `00` small ("My Room"), `01` middle ("Living Room"), `02` large ("Cafe"). Anything else is rejected. |

Payloads shorter than 4 bytes are rejected. Observed: `e7 09 01 01` reports background music off
with room size `01`.

Observed: the XM6 acknowledges the query `e6 03` but never answers it. XM6-Connect queries
background music on subtype `09` only.

#### Cinema, subtype 04

| Offset | Field | Rule |
|---|---|---|
| 0 | Opcode | `e7` or `e9` |
| 1 | Subtype | Must be `04` |
| 2 | Enabled, inverted | `00` on. Any other value means off. |

Payloads shorter than 3 bytes are rejected. Observed: the captured frame
`3e 0c 00 00 00 00 03 e7 04 00 fa 3c` reports cinema on.

#### Queries and writes

- Queries: `e6 09`, `e6 04`.
- Background music write: `e8 09 <00 for on, 01 for off> <room size>`.
- Cinema write: `e8 04 <00 for on, 01 for off>`.

Implemented: XM6-Connect presents one listening mode derived from the two flags. Background music
on gives Background Music. Otherwise, cinema on gives Cinema. Otherwise the mode is Standard. A
mode change is two writes, background music first and cinema second:

| Mode | First write | Second write |
|---|---|---|
| Standard | `e8 09 01 <room>` | `e8 04 01` |
| Background Music | `e8 09 00 <room>` | `e8 04 01` |
| Cinema | `e8 09 01 <room>` | `e8 04 00` |

Implemented:

- `<room>` is the room size from the current session's background-music report.
- A room-size change is a single `e8 09` write that keeps the background-music flag as last
  reported.
- Both kinds of change wait until the session's first background-music report has arrived.
- Unknown: how the headset behaves when both flags are on.

| Message | Payload | Frame |
|---|---|---|
| Query: background music | `e6 09` | `3e 0c 00 00 00 00 02 e6 09 fd 3c` |
| Reply: off, room size `01` | `e7 09 01 01` | `3e 0c 00 00 00 00 04 e7 09 01 01 02 3c` |
| Reply: cinema on (captured) | `e7 04 00` | `3e 0c 00 00 00 00 03 e7 04 00 fa 3c` |
| Write: background music on, small room | `e8 09 00 00` | `3e 0c 00 00 00 00 04 e8 09 00 00 01 3c` |
| Write: background music off, large room | `e8 09 01 02` | `3e 0c 00 00 00 00 04 e8 09 01 02 04 3c` |
| Write: cinema on | `e8 04 00` | `3e 0c 00 00 00 00 03 e8 04 00 fb 3c` |
| Write: cinema off (bit `01`) | `e8 04 01` | `3e 0c 01 00 00 00 03 e8 04 01 fd 3c` |

### 7.6 Automatic power off

Opcodes `26` query, `27` reply, `29` event, subtype `05`. Query: `26 05`.

The reply or event payload must be exactly 4 bytes (Implemented):

| Offset | Field | Rule |
|---|---|---|
| 0 | Opcode | `27` or `29` |
| 1 | Subtype | Must be `05` |
| 2 | Mode | `10` power off when taken off, `11` never. Anything else is rejected. |
| 3 | — | Ignored |

Observed:

- In an earlier test the headset accepted the write `28 05 <mode> 00`, confirmed it with a `29`
  event, and the next read showed the new value.
- The timed values `00`–`03` that older models used are refused. The headset answers them with an
  event that repeats the old value.
- On the XM6, subtype `05` in the `f6`–`f9` family is a different parameter, the voice-assistant
  wake word. Automatic power off must not be written as `f8 05 …`.

XM6-Connect reads this setting and does not write it.

| Message | Payload | Frame |
|---|---|---|
| Query | `26 05` | `3e 0c 00 00 00 00 02 26 05 39 3c` |
| Reply: off when taken off *(illustrative)* | `27 05 10 00` | `3e 0c 00 00 00 00 04 27 05 10 00 4c 3c` |
| Write: never (observed form; not sent by XM6-Connect) | `28 05 11 00` | `3e 0c 00 00 00 00 04 28 05 11 00 4e 3c` |

### 7.7 Pause when taken off

Subtype `01`, queried through the `f6`–`f9` family.

- Query: `f6 01`.
- Observed: `26 01` is acknowledged but never answered by the XM6. The setting comes back as
  `f7 01 <value>`.
- Implemented: replies and events are accepted with opcode `27`, `29`, `f7` or `f9` and subtype
  `01`.

The payload must be exactly 3 bytes (Implemented):

| Offset | Field | Rule |
|---|---|---|
| 0 | Opcode | `27`, `29`, `f7` or `f9` |
| 1 | Subtype | Must be `01` |
| 2 | Enabled, inverted | `00` on, `01` off, anything else rejected |

XM6-Connect reads this setting and does not write it.

| Message | Payload | Frame |
|---|---|---|
| Query | `f6 01` | `3e 0c 00 00 00 00 02 f6 01 05 3c` |
| Reply: on *(illustrative)* | `f7 01 00` | `3e 0c 00 00 00 00 03 f7 01 00 07 3c` |

### 7.8 Multipoint device list and playback source

Message type `0e`. Opcodes `36` query, `37` reply, `39` event, `3c` extended write.
XM6-Connect does not use `38` or `3d`.

#### Device list

Query: `36 02`, sent in a `0e` frame. Subtype `02` asks for entries that include a class-of-device
field.

Observed: this layout matches a list captured from the XM6.

| Part | Size | Field |
|---|---|---|
| Byte 0 | 1 | Opcode, `37` or `39` |
| Byte 1 | 1 | Subtype: `02` entries carry a class-of-device field; `00` they do not (Implemented). Anything else is rejected. |
| Byte 2 | 1 | Entry count *n* |
| Entries | variable | *n* entries, laid out as below |
| Last byte | 1 | Playback status |

Each entry:

| Field | Size | Meaning |
|---|---|---|
| Bluetooth address | 17 | Text, `XX:XX:XX:XX:XX:XX` |
| Connected status | 1 | `00` not connected, non-zero connected |
| Class of device | 3 | Present only with subtype `02`. Ignored. |
| Name length *L* | 1 | — |
| Name | *L* | UTF-8 |

Rules (Implemented):

- A device is the playback source when its connected status is non-zero and equals the trailing
  playback-status byte. The meaning of individual non-zero status values: Unknown.
- With *n* = 0, the payload must be exactly 4 bytes, and the result is an empty list.
- *n* of 16 or more is rejected.
- The entries plus the trailing byte must account for every byte exactly. A short payload or
  leftover bytes are rejected.
- An address that is not valid text is rejected. A name that is not valid UTF-8 is shown as
  "Unknown device".
- Payloads shorter than 4 bytes are rejected.

Example *(illustrative)*: two devices, "Phone" at `00:11:22:33:44:55` with status `01` and "Laptop"
at `66:77:88:99:AA:BB` with status `02`. The playback status is `02`, so Laptop is the playback
source.

```
37 02 02                                              opcode, subtype, count 2
30 30 3a 31 31 3a 32 32 3a 33 33 3a 34 34 3a 35 35    "00:11:22:33:44:55"
01                                                    connected status
00 00 00                                              class of device
05 50 68 6f 6e 65                                     name length 5, "Phone"
36 36 3a 37 37 3a 38 38 3a 39 39 3a 41 41 3a 42 42    "66:77:88:99:AA:BB"
02                                                    connected status
00 00 00                                              class of device
06 4c 61 70 74 6f 70                                  name length 6, "Laptop"
02                                                    playback status
```

As a frame (59-byte payload, length `3b`):

```
3e 0e 00 00 00 00 3b 37 02 02 30 30 3a 31 31 3a 32 32 3a 33 33 3a 34 34 3a 35 35 01 00 00 00
05 50 68 6f 6e 65 36 36 3a 37 37 3a 38 38 3a 39 39 3a 41 41 3a 42 42 02 00 00 00 06 4c 61 70
74 6f 70 02 62 3c
```

| Message | Payload | Frame |
|---|---|---|
| Query | `36 02` | `3e 0e 00 00 00 00 02 36 02 48 3c` |
| Reply: empty list | `37 02 00 00` | `3e 0e 00 00 00 00 04 37 02 00 00 4b 3c` |

#### Playback-source switch

Write: `3c 01 <17 address bytes>`, sent in a `0e` frame. Subtype `01` selects source-switch
control. The address is the 17-byte text form, exactly as the device list reported it.

The opcode `3c` equals the frame end byte, so it is always escaped as `3d 2c` on the wire. Switching
to `00:11:22:33:44:55`:

```
payload: 3c 01 30 30 3a 31 31 3a 32 32 3a 33 33 3a 34 34 3a 35 35
frame:   3e 0e 00 00 00 00 13 3d 2c 01 30 30 3a 31 31 3a 32 32 3a 33 33 3a 34 34 3a 35 35 de 3c
```

Implemented:

- XM6-Connect switches only to a device that appears in the most recent device list the agent
  holds and is marked connected there. That list can come from an earlier session. The agent
  accepts only canonical uppercase addresses (`XX:XX:XX:XX:XX:XX`, hex digits `0`–`9`, `A`–`F`).
- Right after the switch it sends `36 02` again to read the updated list.
- Unknown: whether the headset also pushes an updated list on its own.

### 7.9 Inbound dispatch

How XM6-Connect routes an inbound, non-empty payload (Implemented):

| Type | Opcode | Subtype | Result |
|---|---|---|---|
| `0c` | `01` | any | Handshake reply (section 5) |
| `0c` | `67` | `15`, `19`, `22` | Ambient sound state |
| `0c` | `67` | `17` | Ignored: the XM6's constant reply carries no state |
| `0c` | `69` | `15`, `17`, `19`, `22` | Ambient sound state |
| `0c` | `23`, `25` | `00` | Battery |
| `0c` | `27`, `29` | `05` | Automatic power off |
| `0c` | `27`, `29`, `f7`, `f9` | `01` | Pause when taken off |
| `0c` | `f7`, `f9` | `0c` | Speak-to-chat on/off |
| `0c` | `fb`, `fd` | `0c` | Speak-to-chat settings |
| `0c` | `57`, `59` | `00`, `02`, `04` | Equalizer |
| `0c` | `e7`, `e9` | `09` | Background music and room size |
| `0c` | `e7`, `e9` | `04` | Cinema |
| `0e` | `37`, `39` | `02`, `00` | Multipoint device list |

- Every other combination is acknowledged (section 4.2) and otherwise ignored.
- A payload that matches a row but fails that feature's checks is ignored.
- ACK frames never reach the dispatcher.

---

## 8. State sweep

After the handshake completes, the XM6-Connect agent asks for the complete state. The same sweep
runs whenever the agent refreshes. The host sends these 11 queries in this order (Implemented):

| # | Feature | Type | Payload | Frame in a clean session |
|---|---|---|---|---|
| 1 | Ambient sound | `0c` | `66 19` | `3e 0c 01 00 00 00 02 66 19 8e 3c` |
| 2 | Battery | `0c` | `22 00` | `3e 0c 00 00 00 00 02 22 00 30 3c` |
| 3 | Speak-to-chat on/off | `0c` | `f6 0c` | `3e 0c 01 00 00 00 02 f6 0c 11 3c` |
| 4 | Speak-to-chat settings | `0c` | `fa 0c` | `3e 0c 00 00 00 00 02 fa 0c 14 3c` |
| 5 | Automatic power off | `0c` | `26 05` | `3e 0c 01 00 00 00 02 26 05 3a 3c` |
| 6 | Pause when taken off | `0c` | `f6 01` | `3e 0c 00 00 00 00 02 f6 01 05 3c` |
| 7 | Background music | `0c` | `e6 09` | `3e 0c 01 00 00 00 02 e6 09 fe 3c` |
| 8 | Cinema | `0c` | `e6 04` | `3e 0c 00 00 00 00 02 e6 04 f8 3c` |
| 9 | Equalizer | `0c` | `56 04` | `3e 0c 01 00 00 00 02 56 04 69 3c` |
| 10 | Equalizer, fallback | `0c` | `56 00` | `3e 0c 00 00 00 00 02 56 00 64 3c` |
| 11 | Multipoint device list | `0e` | `36 02` | `3e 0e 01 00 00 00 02 36 02 49 3c` |

The frame column assumes that the sweep starts right after the INIT's ACK, which left the host on
bit `01`, and that nothing else was sent in between. Each query goes out only after the previous
one is acknowledged (section 4.1). Replies are handled whenever they arrive.

Notes (Implemented):

- `66 15`, `66 17` and `e6 03` are never sent, for the reasons in sections 7.1 and 7.5.
- Ambient sound comes first because partial ambient changes (mode, focus or ambient level alone)
  and the cycle action wait for the session's first ambient report (section 7.1).
- When the session opens, writes that were waiting for it are released just before the sweep is
  queued. The first one normally goes out ahead of the sweep. Further waiting writes follow at the
  200 ms spacing described in section 9, so they normally queue behind the sweep.
- The agent treats the first report of any field as the end of a pending refresh.

---

## 9. Session behaviour

Observed: the headset grants one control session at a time. While another client, such as Sony's
phone app, holds the session, a second client's RFCOMM channel open never completes and reports no
error. The handshake is never reached.

XM6-Connect is built around that limit. A background agent owns the Bluetooth session for the
app, the widget and the command-line tool, and treats the Mac as a guest (Implemented):

- **Released by default.** The agent opens a session only when there is something to do: a user
  command, a refresh, a brief prewarm when a user interface surface is about to be used, or a state
  check every 5 minutes. A state check releases the session as soon as the first report arrives.
- **Idle release.** The agent releases the session 20 s after the last activity, 8 s after a
  prewarm session opens, and immediately when the Mac sleeps or the screen locks. Once it has released the
  session, the phone app can connect. An optional "hold" setting keeps the session open instead.
- **Reopen gap.** An ordinary request opens a new session only once at least 2 s have passed since
  the agent last closed its own session.
- **Open deadline: 6 s.** Suppose the channel has not opened within 6 s while macOS has a Bluetooth
  link to the headset. The agent then assumes another client holds the session, closes its own
  attempt, and stands down. It stands down for 60 s, then 180 s, then 600 s, each varied by ±20 %,
  and makes one attempt after each period. A direct user command ends a stand-down. If macOS had no
  link to the headset when the attempt began, the agent reports the headset as not connected and
  tries again after 60 s.
- **Handshake deadline: 5 s.** Suppose the channel opened but the INIT reply has not arrived within
  5 s. The agent then closes its own Bluetooth link once, at most once per 60 s, and tries again
  after 3 s. If that is not possible or does not help, it reports the failure and tries again after
  60 s.
- **Refused open.** Suppose a channel open is refused outright while macOS has a link to the
  headset, within 30 s of the agent releasing its own session. The agent then assumes its previous
  session is still closing, closes its own link once under the same 60 s limit, and retries.
  Otherwise it stands down as above.
- **Other transport failures.** Any other failure of an attempt is retried after 0.5 s, then 1 s,
  then 2 s. If those retries fail too, the agent stands down as above.
- **No link reset against another client.** The agent never closes the Bluetooth link because an
  open stalled: a stalled open may mean another client holds the session.
- **Write spacing.** User actions reach the headset at least 200 ms apart. One action can be more
  than one frame: a listening-mode change sends `e8 09` then `e8 04`, and a playback switch sends
  `3c 01 …` then `36 02`, each pair back to back. For each setting only one pending write is kept:
  a newer one replaces it, except that partial ambient changes are merged into it.
- **Fresh state per session.** Each session starts at sequence bit `00`, and its state is read
  again with the sweep. Partial ambient changes, listening-mode changes and room-size changes are
  built only from reports received in the current session (or the agent's own write in the last
  second), never from values remembered from an earlier one.
