# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

QRious is a set of Lua scripts for OpenTX / EdgeTX RC radios that encode the model's GPS telemetry position as a QR code on the radio screen, so a lost aircraft can be found by scanning the QR with a phone. There is no build step, package manager, linter, or test framework. The entire project is three Lua files under `src/`, which mirror the SD-card layout of the radio (`SCRIPTS/TELEMETRY`, `SCRIPTS/TOOLS`, `WIDGETS/qrPos`).

## Commands

The QR engine runs on a desktop Lua interpreter, and this is the only automated way to exercise it. It needs a Lua 5.3+ interpreter (the script polyfills `bit32` using 5.3 bitwise-operator syntax when it detects it is not on a radio; `apt install lua5.4` works).

```bash
# Generate a QR from a string; prints per-stage progress, then the QR as ASCII
lua src/SCRIPTS/TELEMETRY/qrPos.lua "geo:37.87133,-122.31750"

# Multiple arguments generate multiple QRs in sequence
lua src/SCRIPTS/TELEMETRY/qrPos.lua "geo:1,2" "comgooglemaps://?q=1,2"
```

The CLI run also writes `qr_temp.bmp` into the current working directory (it exercises the BMP writer). It is gitignored.

### Tests

`test/qrtest.py` is the end-to-end check for the encoder. It runs the script on many inputs, decodes the printed ASCII frame and the written BMP with an independent QR reader (zbar), and requires the decoded text to equal the input. Run it after any change to `Qr` or the lookup tables; a QR that merely looks plausible is not proof, since ECC bugs produce clean-looking codes that decode to wrong coordinates.

```bash
apt install lua5.4 zbar-tools && pip install pillow   # one-time setup
python3 test/qrtest.py                 # fixed suite (~150 cases), non-zero exit on failure
python3 test/qrtest.py --random 200    # plus random coordinates, deterministic seed
python3 test/qrtest.py "geo:1,2"       # just these strings
```

The suite includes a "yields at every check" mode that rewrites the CLI `getUsage()` stub to always report overload, which proves every stage makes progress per call. Keep that guarantee when adding loops (see the invariants below).

Radio-side rendering (`lcd.*`, `Bitmap.*`) can only be verified on a radio or in the EdgeTX/OpenTX Companion simulator.

## Architecture

### One engine, three entry points

`src/SCRIPTS/TELEMETRY/qrPos.lua` is the whole project: the QR encoder (`Qr` prototype), the telemetry-page UI, and the desktop CLI harness. The other two files are thin wrappers around it:

- `src/SCRIPTS/TOOLS/qrPos.lua` is a system-tools menu entry. Its `run()` just `chdir`s and returns the telemetry script path, which makes OpenTX chain-load it.
- `src/WIDGETS/qrPos/main.lua` is the color-screen widget. In `create()` it `loadfile`s the telemetry script and uses the module table it returns: `qr` (the `Qr` prototype), `getGps`, `linkLabels`, `linkPrefixes`. The widget never calls the telemetry script's `init()`.

So the return table at the bottom of the telemetry script is a public API consumed by the widget. Changing its shape, or the `Qr` method signatures (`start`, `isRunning`, `genframe`, `toBMP`, `reset`), requires updating the widget.

### Environment detection

The telemetry script decides where it is running by probing globals, not by configuration:

- `getUsage == nil` means "not on a radio": it installs the `bit32` polyfill.
- `lcd == nil` means "desktop CLI": the bottom of the file defines a fake `getUsage()` from `os.clock()`, calls `init()`, and drives `run()` in a loop for each command-line argument. `run()` itself also has a `lcd == nil` branch that starts generation from `arg[1]`, prints the ASCII frame, and returns 1 when done.
- On a radio, `lcd` and `getUsage` exist and `init`/`run`/`background` are called by the firmware.

Keep new radio API calls (`lcd.*`, `Bitmap.*`, `getFieldInfo`, `getTime`) guarded so the CLI path still runs.

### The reentrant QR state machine

The engine is built to never block the radio's ~20 Hz loop. `Qr:genframe()` is a state machine over `self.progress` (0 through 11) with `self.resume` holding continuation state for the stage in flight. Every stage, and every inner loop that can be long, checks `getUsage() > MAX_LOAD` (40%) and returns early; the caller simply calls `genframe()` again next tick until it returns `true`. `Qr:draw()` and `Qr:toBMP()` follow the same pattern, returning a resume index instead of `nil` when they yield.

When editing a stage, preserve these invariants:

- A stage must make at least some progress before yielding (the `vsn > self.resume` / `id > tmp.id_start` style guards), or it can spin forever under load.
- `self.resume` is set to `nil` when a stage completes and the next stage initializes its own resume state from `nil`.
- Buffers are freed as soon as they are dead (`genpoly` after stage 7, `eccbuf` after stage 9, `framask` after stage 10) followed by `collectgarbage()`. This is deliberate; radios have very little RAM.

Stage 11 is output: if `self.bmpPath` is set it streams a 32-bit BGRA BMP (with `fgColor`/`bgColor`/`bgTransp` set on the instance by the widget); on the CLI `bmpPath` defaults to `qr_temp.bmp`.

### Memory tricks

- The frame and the "immutable cell" mask (`framask`) are bit-packed into 32-bit words via `setFrame`/`getFrame`/`setmask`/`ismasked`, not stored as Lua arrays of booleans.
- Galois-field and ECC lookup tables (`GLOG_LOOKUP`, `GEXP_LOOKUP`, `ECCBLOCKS_LOOKUP`, `ADELTA_LOOKUP`, `FMTWORD_LOOKUP`) are byte strings indexed with `string.byte`, not tables. They are trimmed to QR versions 1 through 4 (`MAX_QR_VERSION = 4`, up to 33x33) at ECC level L. Supporting larger payloads means regenerating those strings, not just raising the constant.
- `Qr` is a global prototype on purpose. The telemetry page's `init()` instantiates it and then sets `Qr = nil` to release the prototype; the widget keeps its own single instance instead.

### Widget specifics

- All widget instances share one `Qr` instance and one BMP file. `qrMutex` records which instance's `vars` currently owns generation; `getMyQr(vars)` returns `nil` for the others so only one instance generates at a time.
- Widget options are declared in `myoptions`. The link-type `CHOICE` option's label list is filled in at `create()` time from the engine's `linkLabels`. `CHOICE` and more than five options need EdgeTX 2.11+; older firmware shows a plain switch and truncates the option list, which is why option order matters (transparency is deliberately sixth).
- Link types are defined once, in the telemetry script's parallel `linkLabels` / `linkPrefixes` arrays. Add new map-app URL schemes there. The `prefixes` table in the widget is unused legacy and is not the source of truth.
- Telemetry page controls: ENTER generates, long-ENTER / MENU toggles auto mode (regenerates every `AUTO_MODE_INTERVAL` seconds when the position changes), +/- cycles link type. `background()` keeps polling GPS while the page is not shown so the last good fix survives a crash that kills the telemetry link.
