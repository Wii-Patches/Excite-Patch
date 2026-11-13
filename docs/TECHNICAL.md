# Technical notes

How the three patches work, where they hook, and how one set of data becomes a
patched `main.dol`, a Gecko code list and a Riivolution patch. For installing
and playing, see the [README](../README.md).

Addresses below are the **USA** `main.dol` (`REXE01`) unless noted; the table at
the end lists the other releases.

## One data set, three outputs

Every patch is a list of operations on one release's `main.dol`:

| Operation | Static (`main.dol`) | Gecko | Riivolution |
| --- | --- | --- | --- |
| **Patch** — overwrite bytes in place | write them | `04` / `06` code | `<memory>` |
| **Hook** — replace one instruction with a branch to a routine that runs the displaced instruction and branches back | branch + trampoline in the injected section | `C2` code | `<memory>` (branch + trampoline) |

`tools/prebuilt/<feature>_<disc id>.json` holds those operations, including the
retail bytes expected at every site. `tools/ops.py` turns them into each format,
`tools/patcher.py` applies them (and refuses a `main.dol` whose sites do not
match, so already-modified or foreign dumps are never touched), and
`tools/build.py` writes `codes/` and `riivolution/`. `tools/check.py` fails if
the committed files drift from the data; `tools/verify.py` checks the data
against real retail DOLs for every combination of patches.

**Hooks are self-contained.** A routine carries everything it needs and calls
game code through absolute addresses, so a Gecko code handler can put it anywhere.
There are no shared helper routines and no variables of its own in low memory.
The static build parks the trampolines in one new text section at `0x80001820`
(the Wii's boot-time scratch area, which this game never touches: every
`0x8000xxxx` access in the retail DOLs is at `0x80003000` or above).

The Gecko form deliberately avoids that area: Dolphin's and the loaders' code
handler live there. Writing the cave from a Gecko code (a `06` code) therefore
silently never worked — the handler's own code was sitting on top of it — which
is why nothing in the Gecko output uses `06` for new code.

## Classic Controller

Vague Rant's hack (`src/cc/<disc id>.txt`, unchanged): it patches the KPAD
library so a Classic Controller looks like the tilting Wii Remote. The game reads
steering and in-air angle from the remote's accelerometer fields, so the left
stick is written there (`clamp_stick` / `read_kpad_stick`, with the axes swapped,
inverted, and the second axis stored eight bytes after the first), the buttons
are rewritten into Wii Remote bits in `read_kpad_button`, and the right-hand part
of `read_kpad_stick` turns a stick into a pointer for the HOME Menu. The European
and Japanese releases also reject unknown extensions; one extra word patches that.

## GameCube controller

The game links the SDK's `PAD` library and calls `PADInit` at boot (it prints
`RVL_SDK - PAD`), which probes the controller ports and, for a pad that is
plugged in, enables the SI hardware's auto-polling. The game never calls
`PADRead`, so the pad's state just sits in the SI result registers,
`SIC0INBUFH` at `0xCD006404` (+12 per port): bit 31 error, bit 23 always set in a
real pad's answer, bits 29-16 the PAD button word, then the two stick bytes.

Dolphin refreshes those registers whether or not the port is polled, so reading
them there proves nothing about a console. On a real Wii the first build saw no
buttons while still replacing the remote's tilt with a fixed stick value: the
registers most likely held an answer that was no longer being refreshed (not yet
confirmed on a console). So the button hook,
which runs once per channel per frame, now keeps the poll alive the way the SDK's
`SIEnablePolling` sets it up, for every port that `si`'s type cache marks as a
standard pad: the poll command (`0x00400300`) into `SICnOUTBUF`, `SISR` with WR
(bit 31) plus that port's error nibble, the port's enable bit in `SIPOLL` and in
`si`'s shadow of it (`Si.poll`, which the VI retrace writes back to `SIPOLL`).
The `si` state block (`Si` at `0x80311630` USA: `+4` the SIPOLL shadow, `+0x18`
the four cached types) is read out of `SIEnablePolling` per release.

A pad answer is used only if the port's cached type is a standard pad, bit 31 is
clear, bit 23 is set and the stick bytes are not zero.

Two hooks use that:

- **`read_kpad_button` merge point (`0x80045AF8`)** — every extension type
  reaches `lwz r0,0(r3)` (r3 = the channel's KPAD struct, base `0x8037C808`, stride
  `0x400`). After the polling upkeep, the hook maps the pad's buttons onto the Wii
  Remote bits the game expects with the remote held sideways (the same mapping the
  Classic Controller patch uses) and ORs them in before the edge detection runs.
- **The KPAD sample loop's `bl 0x80047284`** (three call sites, one per extension
  type; it runs after the accelerometer filter for every sample) — runs the
  original call, then, if a pad answers *and its stick is outside the dead zone*,
  writes the stick into the accelerometer fields the same way the Classic
  Controller patch does (`acc.x ← −stickY`, `acc.z ← −stickX`, normalised to ±1).
  With the stick at rest the remote's own tilt is left alone, so a remote and a
  pad can share a player. While the HOME Menu is open the stick also moves the
  pointer.

Port N feeds KPAD channel N (SI result registers are 12 bytes apart, KPAD structs
`0x400`). The game polls all four channels every frame but is a two-player game
(`Pause:MISSING_CTRL_0/1` are the only controller-missing screens); in Dolphin, pad 1
and pad 2 drove channels 0 and 1 independently, and channels 2-3 stayed idle.

Nothing is stored anywhere: the pad is judged from `si`'s type cache and its own
result word every time.

## SDHC

The game's custom soundtrack reads MP3s through Nintendo's `PFD` SD driver, the
same library as *Animal Crossing: City Folk* and *My Pokémon Ranch*, here an
older build of it. It assumes a standard-capacity card: byte addresses in the
read/write commands, a CSD v1 capacity, and a check that the card is "initialized".
SDHC differs in all three, so (Bero's fix):

| Address | Hook | What it does |
| --- | --- | --- |
| `0x800BAE58` | `ISD_GetDeviceStatus`, `stw r3,0(r28)` | latch the SDHC bit (`0x00100000`) of the IOS status word into `FLAG` |
| `0x800BA34C` | `pfd_sddrv_get_disk_info`, `rlwinm. r0,r3,0,15,15` | also accept an SDHC card IOS has not marked initialized (Dolphin never does) |
| `0x800BA8DC` | `pfd_sddrv_get_total_sectors`, `lwz r5,0xc(r1)` | CSD v2: sectors = (`C_SIZE` + 1) × 1024, then rejoin the v1 code just after its own maths |
| `0x800BB568`, `0x800BB8A4` | `ISD_{Read,Write}MultiBlockAsync`, `cmplw r4,r0` | block numbers are never 512-byte aligned: always pass the alignment check |
| `0x800BA504`, `0x800BA6F0` | `physical_{read,write}`, `mullw r25,r5,r6` | keep the sector index as the address instead of multiplying by 512 |
| `0x800BA658`, `0x800BA844` | the per-sector loops, `add r25,r25,r23` | advance one block instead of 512 bytes |

`FLAG` is the last word (`+0x3C`) of the SD handle struct (`0x80407320`, 0x40
bytes), which nothing in the driver touches. That puts it at `0x8040735C` (USA),
and it is written on every `ISD_GetDeviceStatus`, so it follows card changes.

IOS matters on a real console. The game's TMD asks for IOS 9, which predates SDHC
support; the driver has a message for an IOS refusing an SDHC card at reset
("SDHC card inserted; format not supported"). An IOS that supports SDHC (58, or a
cIOS built on one) is needed — the patcher can rewrite the disc's IOS slot for
you. This part is reasoning from the driver and from the same fix in other games;
it has not been seen on a console.

## Other releases

The SD driver is byte-identical in all three releases apart from addresses: the
site map above shifts by a constant (Europe `+0x510`, Japan `+0x5BC`). The KPAD
library moved by a different amount, so those sites were carried over by
masked-signature search (`tools/sig.py`, which ignores branch targets and
address-sized immediates and demands exactly one match):

| | USA | Europe | Japan |
| --- | --- | --- | --- |
| `read_kpad_button` merge | `0x80045AF8` | `0x80045FEC` | `0x80046098` |
| `bl` to the IR routine (×3) | `0x80047D94` `0x80047E38` `0x80047EE8` | `0x8004822C` `0x800482D0` `0x80048380` | `0x800482D8` `0x8004837C` `0x8004842C` |
| KPAD channel 0 struct | `0x8037C808` | `0x80396048` | `0x803A2608` |
| SD `FLAG` | `0x8040735C` | `0x80420B9C` | `0x8042D15C` |

## How it was tested

Dolphin, with its GDB stub reading the KPAD struct while a pipe-input device
presses buttons and moves the sticks: GameCube and Classic Controller inputs land
in the buttons and accelerometer fields on all three releases, and the SD driver's
reads on a 3 GB card image arrive as block addresses (`0x0, 0x1, 0x3008, …`) where
the stock game gives up with "SD card type is not memory". `tools/verify.py`
re-checks every site against retail DOLs. Nothing here has been run on a console.
