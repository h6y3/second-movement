# AGENTS.md — operator notes for second-movement (Sensor Watch firmware)

Repo-specific operational knowledge that is NOT obvious from the code or
upstream docs. Read this before building, editing faces, or touching the build
system. Aimed at any agent (pi or otherwise) landing cold.

## TL;DR — the workflow

```sh
# 1) Edit faces/config locally (movement_config.h, watch-faces/...).
# 2) Emulator check (optional, works locally on macOS — WASM, not the LCD path):
emmake make BOARD=sensorwatch_pro DISPLAY=custom
python3 -m http.server -d build-sim 8000   # -> http://localhost:8000/firmware.html

# 3) HARDWARE firmware: DO NOT build locally on macOS. Build via CI (Linux):
./build-via-ci.sh            # commits/pushes, watches CI, downloads the .uf2
#    -> firmware-prebuilt/ci/firmware.uf2

# 4) Flash: double-tap reset to mount WATCHBOOT, drag the .uf2 onto it.

# 5) Keep the fork's firmware branch synced with upstream:
./sync.sh
```

## ⚠️ CRITICAL — do NOT build hardware firmware locally on macOS

This was a multi-hour saga. **Building the hardware firmware (`make BOARD=…
DISPLAY=…`) on macOS produces a binary that boots but does NOT drive the LCD** —
the watch looks completely dead (blank screen, no segments) even though the
chip runs (the bootloader mounts fine, and a boot-LED diagnostic lights up).
Confirmed across two independent local toolchains:

| Local toolchain (macOS)          | Boots? | LCD?  |
|----------------------------------|--------|-------|
| Arm GNU Toolchain 15.2 (Mac)     | yes    | **blank** |
| xPack gcc-arm-none-eabi 10.3.1 (Mac, arm64) | yes | **blank** |
| **Official prebuilt (Arm 10.3, Linux)** | yes | ✅ works |
| **GitHub Actions CI (Linux container)** | yes | ✅ works |

The failure is host-environment-dependent, not GCC-version-dependent (two
different compilers failed identically on Mac; the same 10.3 the project pins
works on Linux). A cross-compiler's output *should* be host-independent, but
something in this project's macOS build path breaks the SLCD driver codegen.
Root cause not fully isolated, but **the fix is deterministic: build on
Linux/CI.** Don't waste time chasing local macOS toolchain versions — use CI.

- The **emulator build** (`emmake make`) works fine locally on macOS (it targets
  WASM, a different path that doesn't touch the SLCD driver).
- The **hardware build** (`make`) must run on Linux — either GitHub Actions CI
  (this repo has a `build.yml` workflow) or a Linux machine/Docker.

## Build via CI (the supported hardware build path)

The repo ships `.github/workflows/build.yml`, which builds the firmware in the
official Linux environment (Ubuntu + Arm toolchain container) for all
board×display combinations and uploads each `.uf2` as an artifact. Your custom
config lives in `movement_config.h` on branch `custom-firmware-pro-custom`; CI
builds whatever `movement_config.h` is on the pushed branch.

### One-time: enable Actions on the fork
Forks ship with workflows disabled. Visit
https://github.com/h6y3/second-movement/actions and click
**"I understand my workflows, go ahead and enable them."** (Once.)

### Per-build
```sh
./build-via-ci.sh
# - commits any uncommitted config changes on custom-firmware-pro-custom
# - pushes to the fork (triggers the Build workflow on push)
# - waits for the run to finish
# - downloads the sensorwatch_pro + custom artifact
# - leaves the flashable file at firmware-prebuilt/ci/firmware.uf2
```
Then drag `firmware-prebuilt/ci/firmware.uf2` onto the mounted `WATCHBOOT` drive.

Manual equivalent: push to `fork custom-firmware-pro-custom`, watch the run with
`gh run watch <id> --repo h6y3/second-movement`, download with
`gh run download <id> --repo h6y3/second-movement --name sensorwatch_pro-display-custom-movement.uf2 --dir firmware-prebuilt/ci`.

### Official prebuilt (zero-build control / fallback)
If you just need a known-good Pro+custom firmware (stock face set), download the
project's official artifact (built on Linux):
```sh
curl -L -o firmware-prebuilt/standard_pro_custom.uf2 \
  https://www.sensorwatch.net/docs/firmware/download/standard_pro_custom.uf2
```
Keep downloaded/prebuilt UF2s **outside `build/`** (e.g. `firmware-prebuilt/`) —
the always-clean `make` wipes `build/` and will delete anything you stash there.

## The build system always cleans (do not "fix" dep tracking)

`make` (default goal `rebuild`) runs `clean` then a recursive `make all`. This is
intentional and **must stay**. Reason: gossamer's per-object dependency tracking
is **broken**. The compile rules are generated via `$(eval)` as *explicit* rules
(`gossamer/rules.mk:81`), so GNU make's stem `$*` is empty in `CFLAGS`
(`gossamer/make.mk:66` `-MD -MP -MT $(BUILD)/$(*F).o -MF $(BUILD)/$(@F).d`).
Result: every `-MD` writes to `build/.d` (overwritten each compile) and
`-include $(wildcard $(DEPFILES))` matches nothing. Editing any header (e.g.
`movement_config.h`) silently leaves stale `.o`s linked in. We hit this twice.

- Default `make`/`emmake make` → always clean + full rebuild. Safe.
- Escape hatch (skip clean when you know nothing changed): `make all …`
- CI runs `make` (the `rebuild` default) — fine.

## Face configuration

Face order and membership live in **`movement_config.h`**, array `watch_faces[]`.
Face *declarations* (headers) are pulled in by `movement_faces.h` (add new face
headers above the `// New includes go above this line.` marker).

- **`MOVEMENT_SECONDARY_FACE_INDEX = MOVEMENT_NUM_FACES - 7`** in our branch
  (upstream default is `- 5`). Faces from that index to the end are a **hidden
  secondary group**: excluded from normal Mode rotation, reachable only by
  long-Mode-press from face 0, then Mode cycles within the group. We keep
  `voltage, settings, set_time, finetune, nanosec, activity_logging,
  temperature_logging` in the secondary group (7 faces), so the normal rotation
  is `clock … temperature_display` (10 faces). If you add/remove faces, recompute
  the offset so the boundary stays at the first utility face.
- Adding/removing/reordering faces = edit `watch_faces[]` only.
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
Minute-only presets look identical under either endianness (minutes is always
byte 1) — that masked the 1h mistake. Always derive from the comment+struct, not
from "HHMMSS" intuition.

## Emulator caveats (read before trusting what you see)

- **Browser cache is aggressive.** After rebuilding, the old `firmware.wasm`/`.js`
  persist. Hard-reload (Cmd+Shift+R) often isn't enough; open DevTools → Network →
  check "Disable cache" → reload. Verify freshness: `shasum -a 256 build-sim/firmware.wasm`
  vs `curl -s http://localhost:8000/firmware.wasm | shasum -a 256` — must match.
- **The emulator does NOT exercise the LCD-driver codegen bug.** A firmware that
  runs in the emulator may still be blank on hardware if built on macOS. The
  emulator is a logic/UX check only; hardware behavior is proven by a Linux/CI
  build flashed to the watch.
- **Simulated sensors.** Temperature comes from the `temp-c` input field;
  accelerometer input is limited. Verify sensor faces on hardware.
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

1. Plug in watch, **double-tap Reset** (two quick presses ~half-second apart) to
   enter the UF2 bootloader → a drive mounts (e.g. `WATCHBOOT`).
2. Drag the `.uf2` onto it. Watch reboots into the new firmware.
3. No flashing tool/DFU needed. (A `make install` target exists using dfu-util,
   but drag-drop is the normal path.)
4. The bootloader runs on USB power and **bypasses the battery** — a working
   bootloader does NOT prove the battery path is good (see debugging below).

## Hardware debugging playbook (lessons from a long saga)

If the watch shows "no sign of life" after flashing, isolate systematically. The
bootloader mounting proves the chip + USB power are good; the question is whether
the **app boots** and whether **battery power** reaches the board.

1. **Is it the build?** The #1 cause on macOS: a locally-built firmware that boots
   but doesn't drive the LCD. Test by flashing the **official prebuilt**
   (`firmware-prebuilt/standard_pro_custom.uf2`). If the official shows the clock
   and your build doesn't → it's the macOS build (use CI). This single test saved
   the whole investigation.
2. **Does the app boot at all?** Temporarily add to `app_init()` (in `movement.c`),
   right after `_watch_init();`:
   ```c
   watch_enable_leds(); watch_set_led_red();
   ```
   Build via **CI** (so the LCD bug isn't confounding), flash, and observe the
   bare board on USB: red LED on = app boots. (The LED is independent of the LCD.)
   Revert this before committing.
3. **Battery power vs USB.** The bootloader/app run on USB even if the battery
   clip is broken. To test battery specifically: flash a boot-LED diagnostic (as
   above), **unplug USB**, and hold the battery firmly into the holder.
   - Red LED lights → battery power works when pressed → the case/clip isn't
     pressing the cell firmly enough (reform the clip).
   - No LED → battery not delivering (dead cell, broken clip, cracked solder
     joint, or wrong polarity).
4. **Is the LCD seated?** The Sensor Watch LCD uses a zebra/elastomer connector
   that only contacts under case-clamp pressure. A flaky seat can give
   intermittent blank screens. Reassemble carefully; if results are inconsistent
   across reassemblies, suspect seating.
5. **Audible boot test (no LCD needed).** For an in-case test where the LED isn't
   visible, add to `app_init()`:
   ```c
   watch_enable_buzzer(); watch_buzzer_play_note(BUZZER_NOTE_C7, 400);
   ```
   Reassemble on battery; a beep = app boots in the case (power good) → any blank
   LCD is then the LCD/zebra, not power.

## Git layout (this checkout)

- `origin` = `joeycastillo/second-movement` — **upstream truth**. Fetch latest here.
- `fork`   = `h6y3/second-movement` — your GitHub fork; push here. Actions enabled.
- Firmware work lives on branch **`custom-firmware-pro-custom`** = upstream
  `main` + a surgical firmware patch (`Makefile`, `movement_config.h`,
  `watch-faces/complication/timer_face.c`) kept linear via rebase, plus workflow
  files (`sync.sh`, `build-via-ci.sh`, `AGENTS.md`). Build from it.
- `./sync.sh` = fetch `origin` → rebase `custom-firmware-pro-custom` onto
  `origin/main` → `push fork --force-with-lease`. Run it to absorb upstream work.
  On conflict it stops with hints (resolve → `git rebase --continue`).
- `./build-via-ci.sh` = commit+push → watch CI run → download the pro/custom `.uf2`
  to `firmware-prebuilt/ci/firmware.uf2`.
- **gossamer submodule** is pinned at `03aedcb`; keep its working tree clean. An
  earlier local mod added an `.ARM.exidx` section to `saml22n18.ld` to work around
  a link error under some Mac toolchains — do not re-add it; build via CI instead,
  which links cleanly. Stage only your real files; never commit the submodule
  pointer unless you intentionally bump gossamer.

## Don'ts

- **Don't build hardware firmware locally on macOS** — it produces a
  blank-LCD binary. Use CI (`./build-via-ci.sh`) or a Linux machine.
- Don't stash UF2s in `build/` — the always-clean `make` wipes it. Use
  `firmware-prebuilt/`.
- Don't add a "smart" incremental dependency fix without testing against the
  broken `eval`-rule mechanism — the always-clean default exists because the dep
  system is unreliable.
- Don't trust a single `make` without confirming it recompiled `movement.o`
  after any config-header edit (the always-clean default makes this moot).
- Don't flash `build-sim/*` to hardware or open `build/firmware.uf2` in a browser.
- Don't re-add the gossamer linker-script `.ARM.exidx` hack — build via CI.

## Reference

- Upstream emulator docs: https://www.sensorwatch.net/docs/movement/emulator/
- Movement faces reference: https://www.sensorwatch.net/docs/faces/
- Official prebuilt firmware: https://www.sensorwatch.net/docs/firmware/prebuilt/
- Build workflow: `.github/workflows/build.yml`