# AGENTS.md — operator notes for second-movement (Sensor Watch firmware)

Repo-specific operational knowledge that is NOT obvious from the code or
upstream docs. Read this before building, editing faces, or touching the build
system. Aimed at any agent (pi or otherwise) landing cold.

## TL;DR — the only commands you need

```sh
# Emulator (WASM, runs in browser):
emmake make BOARD=sensorwatch_pro DISPLAY=custom
python3 -m http.server -d build-sim 8000
#   -> http://localhost:8000/firmware.html   (hard-reload / disable cache to see changes)

# Hardware (drag-drop flash):
make BOARD=sensorwatch_pro DISPLAY=custom
#   -> drag build/firmware.uf2 onto the mounted WATCHBOOT drive

# Keep your fork's firmware branch synced with upstream:
./sync.sh
```

## Two builds, two toolchains, two output dirs

| Build        | Toolchain              | Dir        | Artifact            | Purpose        |
|--------------|------------------------|------------|---------------------|----------------|
| `emmake make`| emscripten (WASM)      | `build-sim`| `firmware.{html,js,wasm}` | Emulator only |
| `make`       | arm-none-eabi-gcc      | `build`    | `firmware.uf2`      | Hardware flash |

- `BOARD` and `DISPLAY` are **required** for every build. Valid: `BOARD=sensorwatch_{red,blue,pro}`, `DISPLAY={classic,custom,autodetect}`.
- The emulator build (`build-sim`) **cannot** be flashed to hardware. The hardware build (`build`) is not loadable in the browser. They share the same sources/config; do not cross them.
- `sensorwatch_pro` is `CHIP=saml22` (not samd51). UF2 conversion uses `-co` (no boot offset); output reports `start address: 0x2000`.
- Toolchains: `brew install emscripten` (emulator); `arm-none-eabi-gcc` for hardware (already on this machine at `/opt/homebrew/bin`).

## CRITICAL: build system always cleans (do not "fix" dep tracking)

`make` (default goal `rebuild`) runs `clean` then a recursive `make all`. This is
intentional. **Do not remove it.**

Reason: gossamer's per-object dependency tracking is **broken**. The compile
rules are generated via `$(eval)` as *explicit* rules (`gossamer/rules.mk:81`),
so GNU make's stem `$*` is empty in `CFLAGS` (`gossamer/make.mk:66`
`-MD -MP -MT $(BUILD)/$(*F).o -MF $(BUILD)/$(@F).d`). Result: every `-MD` writes to
`build/.d` (overwritten each compile) and `-include $(wildcard $(DEPFILES))`
matches nothing. Editing any header (e.g. `movement_config.h`) silently leaves
stale `.o`s linked in. We hit this twice.

- Default `make`/`emmake make` → always clean + full rebuild (~30–60s). Safe.
- Escape hatch (skip clean when you know nothing changed): `make all ...`
- If you add a new dependency-tracking "fix", test it: `touch movement_config.h`
  then a bare `make` must recompile `movement.o`. The current `rebuild` target
  guarantees correctness regardless.

## Face configuration

Face order and membership live in **`movement_config.h`**, array `watch_faces[]`.
Face *declarations* (headers) are pulled in by `movement_faces.h` (add new face
headers above the `// New includes go above this line.` marker).

- **`MOVEMENT_SECONDARY_FACE_INDEX = MOVEMENT_NUM_FACES - 5`** (movement_config.h:56).
  Faces from that index to the end are a **hidden secondary group**: excluded
  from normal Mode rotation, reachable only by long-Mode-press from face 0, then
  Mode cycles within the group. `settings`, `set_time`, `voltage` conventionally
  live here. If you append a face, it lands in the secondary group — that is why
  `activity_logging`/`temperature_logging` are not in the normal cycle.
  Adjust the formula or position faces before the boundary to change this.
- Adding/removing/reordering faces = edit `watch_faces[]` only. The build
  always-cleans, so a stale `movement.o` cannot silently hide the change.
- Individual face code: `watch-faces/<category>/<name>_face.{c,h}`.

## timer_face value packing (gotcha that nearly shipped a bug)

`timer_face.c` stores presets as `uint32_t` written via `.value` and read via
`.unit` (struct `{hours, minutes, seconds, repeat}`). Target is **little-endian**
(Cortex-M0+ and WASM both LE), so:

```
value = (repeat<<24) | (seconds<<16) | (minutes<<8) | hours
        hours = low byte, minutes = byte 1, seconds = byte 2, repeat = byte 3
```

Proof: original `0x002D02` is commented "2 h 45 min" → only decodes correctly with
hours=`0x02` (low byte), minutes=`0x2D` (byte 1). A big-endian reading would give
45 min 2 s, contradicting the comment. So **1 hour = `0x000001`, not `0x010000`**.
Minute-only presets look identical under either endianness (minutes is always byte
1) — that masked the 1h mistake. Always derive from the comment+struct, not from
"HHMMSS" intuition.

## Emulator caveats (read before trusting what you see)

- **Browser cache is aggressive.** After rebuilding, the old `firmware.wasm`/`.js`
  persist. Hard-reload (Cmd+Shift+R) often isn't enough; open DevTools → Network →
  check "Disable cache" → reload. Verify freshness: `shasum -a 256 build-sim/firmware.wasm`
  vs `curl -s http://localhost:8000/firmware.wasm | shasum -a 256` — they must match.
- **Simulated sensors.** Temperature comes from the `temp-c` input field in the
  HTML; accelerometer input is limited. Faces using real sensor data show static/
  canned values in the emulator. Verify sensor faces on hardware.
- **Filesystem is RAM-only** (`watch-library/simulator/watch/watch_storage.c`,
  static `uint8_t storage[]`, no disk backing). `totp_lfs` secrets, activity/temp
  logs, etc. **reset on every reload**. On real hardware they persist in flash.
- **In-emulator shell:** the input box under the display ("Filesystem command")
  feeds the shell (`ls`, `cat <PATH>`, `echo TEXT {>,>>} FILE`, `rm`, `format YES`,
  `df`, `b64encode`). Useful for seeding `totp_uris.txt` to test `totp_lfs` — but
  re-enter each session (ephemeral).
- `totp_face` (non-LFS) compiles secrets into firmware via
  `watch-faces/complication/totp_face.secrets.h` (`#if __has_include`). No runtime
  file. Better for emulator testing; reflash to change keys on hardware.

## Hardware flash

1. Plug in watch, **double-tap Reset** to enter UF2 bootloader → drive mounts
   (e.g. `WATCHBOOT`).
2. Drag `build/firmware.uf2` onto it. Watch reboots into the new firmware.
3. No flashing tool/DFU needed. (A `make install` target exists using dfu-util,
   but drag-drop is the normal path.)

## Git layout (this checkout)

- `origin` = `joeycastillo/second-movement` — **upstream truth**. Fetch latest here.
- `fork`   = `h6y3/second-movement` — your GitHub fork; push here.
- Firmware work lives on branch **`custom-firmware-pro-custom`** = upstream
  `main` + a surgical 3-file firmware patch (`Makefile`, `movement_config.h`,
  `watch-faces/complication/timer_face.c`) kept linear via rebase, plus two
  workflow files (`sync.sh`, `AGENTS.md`). Build from it.
- `./sync.sh` = fetch `origin` → rebase `custom-firmware-pro-custom` onto
  `origin/main` → `push fork --force-with-lease`. Run it to absorb upstream work.
  On conflict it stops with hints (patch touches 3 small spots; resolve →
  `git rebase --continue`).
- **gossamer submodule has a pre-existing local modification**
  (`gossamer/chips/saml22/linker/saml22n18.ld`) that is NOT ours. Do not commit
  the gossamer submodule pointer. Stage only your real files.

## Don'ts

- Don't commit `build/`, `build-sim/`, or the gossamer submodule's dirty
  `saml22n18.ld`.
- Don't add a "smart" incremental dependency fix without testing it against the
  broken `eval`-rule mechanism above — the always-clean default exists precisely
  because the dep system is unreliable.
- Don't trust a single `make` without confirming it recompiled `movement.o` after
  any config-header edit (the always-clean default makes this moot, but if
  someone uses `make all` to skip clean, stale artifacts can return).
- Don't flash `build-sim/*` to hardware or open `build/firmware.uf2` in a browser.

## Reference

- Upstream emulator docs: https://www.sensorwatch.net/docs/movement/emulator/
- Movement faces reference: https://www.sensorwatch.net/docs/faces/