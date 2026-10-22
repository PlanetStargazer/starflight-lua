# Starflight 1 for LÖVE

A source port of the *Starflight* (1986/87) runtime to Lua, for [LÖVE](https://love2d.org) 11.x.
It does not contain any game data: it reads the files of your own copy of the game.

## What this is

Starflight is written in Forth.  `STARFLT.COM` is a Forth kernel, and all the game
logic, the user interface and the overlays in `STARA.COM` / `STARB.COM` are
*threaded code*: lists of 16-bit pointers to words.  Only about 225 words in the
kernel, 35 in the overlays and a graphics driver are real machine code.

The [starflight-reverse](https://github.com/s-macke/starflight-reverse) project
disassembled all of this.  This port is built on that work:

* `src/vm.lua`, `src/prims.lua`, `src/hw.lua`, `src/dos.lua` – the Forth virtual
  machine (inner interpreter and the kernel's primitive words), the DOS file
  interface the game uses (FCB random reads/writes of STARA/STARB), keyboard,
  text screen, ports and sound.
* `src/gfx.lua`, `src/ega.lua`, `src/video.lua` – the game's graphics machine
  code (clipper, polygon scan converter, bitmap blitter, line, fill, ellipse...)
  and a model of the EGA adapter (planar memory, write modes, latches) it draws
  through.
* `src/ovcode.lua` – machine-code words that live inside overlays (planet terrain
  generator, orbit view maths, run-length bitmaps, save/restore jumps ...).
* `src/music.lua` – the timer-interrupt song sequencer from the MUSIC overlay.

Every ported routine was written from the disassembly of the original, and was
checked against the original machine code by running both side by side (see
`tools/`).

## Running

```
love starflight-lua                       # finds games/sf1, ../starflight.zip or the LÖVE save folder
love starflight-lua /path/to/folder       # a folder with STARFLT.COM, STARA.COM, STARB.COM
love starflight-lua /path/to/starflight.zip
```

* The first screen's display-mode question is answered for you: only **EGA** is ported
  (choosing 1-4 at that menu is treated as 5).
* Arrow keys, Return, Space and Esc work as in the DOS game.  Alt+Enter toggles full screen, Ctrl+Q returns to the
  slot menu, Ctrl+L opens the quest log.  No F-key is bound unless debug mode is on (see Settings).
* At start the game shows its own slot menu (drawn with the game's fonts): 1-9 plays a slot (a new game plays the intro, a saved one skips it), **D. Delete a save** removes one after a confirmation.  A slot only ever holds a state saved with the game's own Save Game
  (Esc, then 1), exactly what the original can resume; leaving without saving asks for confirmation.
* The slot menu also has **S. SETTINGS**, **D. DELETE A SAVE** and **0. QUIT** (or Q); Up/Down + Return/Space choose an entry.
* **Settings** switch every enhancement off (they are kept in `settings.txt` in the save folder): enhanced sound,
  UI sounds, short waits (the game's 5-second pauses, e.g. the hull integrity check when you
  disembark, are cut to 0.3 s), the speed cap in orbit and landing, the quest log, the gamepad, the mouse, the key-repeat cap,
  skipping the intro of saved games, the CRT shader, CRT glitches, and **debug mode**.  Debug mode enables the F-keys:
  F3 CRT glitches, F4 CRT shader, F5 quest log, F6 UI sounds, F7 short waits, F8 enhanced sound, F9 cheat, F10 slot menu, F11 full screen.
  (Ctrl+G also toggles CRT glitches at any time).
* **Mouse**: left click presses a button (menus, the Esc save/options menu, the button bar at the bottom of starport and vehicle screens, the
  ship's command list; a click anywhere else is Space), right click is Esc (or Resume in the save menu), the wheel is Up/Down.  In the starport rotunda a click
  walks the astronaut there, and a click on a door mat (or the launch pad) also opens that facility. Mouse coordinates are automatically corrected for CRT barrel curvature when the CRT shader is enabled.
* **Gamepad**: d-pad or left stick = arrow keys, A = Return, B = Space, Start = Esc, Back = slot menu, Y = quest log.
  In the slot menu use d-pad up/down, A to choose and B to leave Settings.
* **Sound** (`src/synth.lua`): the music is played as an FM lead with an octave-down bass, a detuned pad and a
  reverb; the game's beeps and effects get the same instrument plus noise for sweeps and a rumble for low tones.
  UI sounds are interface blips and a quiet ambience per screen; with enhanced sound off you get the raw PC speaker.
  The intro song stops when the intro ends.
* **Quest log** (Ctrl+L, or Y on the gamepad): a per-slot record (`slotN_LOG.txt` in the save folder) of what the game tells
  you: starport notices, everything said in the communications screens, and ship messages that mention coordinates
  or subjects such as wormholes and alien activity.  The log is drawn with the game's own fonts (read from the game's memory). Coordinates and subjects are highlighted.  The game pauses while it is open.
* **The F9 cheat** (debug mode only) creates six Human crew members (skills and vitality 99), assigns them to
  all posts, and sets the ship's parts to class 5 with full points.  Use it in the Starport, then
  Save Game as usual if you want to keep it.
* Saved games go to the LÖVE save directory (`~/.local/share/love/starflight-lua/` on
  Linux); the original files are never modified.  Delete `save_STARA.COM` / `save_STARB.COM`
  there to start over.  The game also writes to those files while running, as the DOS game did.
* Speed: unlimited, except the rotating planet and landing sequence, which are capped at 240000 Forth words/s (Ctrl+Left/Right set a global cap, Ctrl+Down removes it).
* Not done: Starflight 2, CGA/Tandy/Hercules display modes.

## Verification

All of `tools/` runs the *original* machine code in a small 8086 interpreter next to the
Lua VM and compares them: Forth word trace, stack, memory, EGA planes, text screen and
speaker state.  `tools/regress.sh` runs forced tests of every graphics, overlay and arithmetic
primitive plus random-play fuzz runs (millions of Forth steps each).  Everything matches except
two known cases: `VMOVE-` (broken in the original, never called) and the stack-garbage copied
by `PRMSAV`.

## Development tools (`tools/`)

* `x86.lua`, `oracle.lua` – a small 8086 interpreter that runs the *original* machine
  code.  It is a test oracle only; the game itself does not use it.
* `vmlog.lua`, `cmplog.py`, `cmp.sh`, `dm.sh` – run the oracle and the Lua VM on the same
  key script and report the first Forth word where stack, memory or EGA planes differ.
* `shot.lua`, `shot2.sh` – headless screenshots.
* `fuzz.py` – random key scripts for the comparison.
