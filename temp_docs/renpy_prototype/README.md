# BL VN Demo — Scene 1 Prototype

Bilingual (English / Simplified Chinese) Ren'Py prototype for Scene 1 of a PG18 BL visual novel demo. This build validates the production pipeline — language toggle, CJK rendering, scene routing, BG/CG placeholders — **before** committing the full 13-scene script to Ren'Py.

## What this is

- **Scene 1 only.** Ends at "I do not know yet that 西康路 is not only a street." / "我还不知道西康路不只是一条路。" followed by an "End of Prototype" card.
- **Bilingual.** Main menu picks English or 简体中文. Each language plays its own parallel script (not a translation — both are authored per W4).
- **Placeholder art.** Solid-color backgrounds with text labels. Five BGs plus one optional CG placeholder plus a splash and end card.
- **No audio.** SFX markers preserved as comments in the script files for later audio passes.
- **Transitions.** `fade` and `dissolve` only. No custom transitions.

## Prerequisites

1. **Ren'Py 8.x SDK** — latest stable. Not yet installed on this machine as of prototype handoff.
2. **Noto Sans SC font** — required for CJK rendering. See `game/fonts/` for drop instructions.

## Install Ren'Py on macOS

**Option A — Homebrew (easiest):**
```bash
brew install --cask renpy
```
Then launch the Ren'Py Launcher from Applications.

**Option B — Official SDK download:**
1. Go to https://www.renpy.org/latest.html
2. Download the macOS SDK DMG (e.g. `renpy-8.3.7-sdk.dmg`)
3. Mount the DMG and copy the folder to your home or Applications
4. Run `/path/to/renpy-8.3.7-sdk/renpy.sh` from Terminal, or double-click the Ren'Py Launcher app inside

**Option C — Tarball:**
1. Download `renpy-8.3.7-sdk.tar.bz2` from https://www.renpy.org/dl/8.3.7/
2. Extract to `~/renpy-sdk/`
3. Launch with `~/renpy-sdk/renpy.sh`

## Install the CJK font (critical — SC won't render without it)

1. Download Noto Sans SC Regular from one of:
   - https://fonts.google.com/noto/specimen/Noto+Sans+SC
   - https://github.com/notofonts/noto-cjk/tree/main/Sans/OTF/SimplifiedChinese
2. Place the file at: `game/fonts/NotoSansSC-Regular.ttf`
3. Delete the `PLACE_NotoSansSC-Regular.ttf.here` marker file once the real TTF is in place.

If the filename differs (e.g. `NotoSansSC-Regular.otf`), either rename it or update all three `define gui.*_font` lines in `game/options.rpy` to match.

## Launch the prototype

**Via Ren'Py Launcher GUI:**
1. Open Ren'Py Launcher
2. Click "Preferences" → "Projects Directory" and set it to `/Users/reginalim/projects/rho/temp_docs/` (one level above `renpy_prototype/`). Click "Return".
3. The sidebar now shows `renpy_prototype`. Click it.
4. Click "Launch Project".

**Via CLI:**
```bash
# Homebrew cask install path (may vary):
/Applications/Ren'Py\ Launcher.app/Contents/MacOS/renpy.sh /Users/reginalim/projects/rho/temp_docs/renpy_prototype/

# Or SDK tarball install:
~/renpy-sdk/renpy.sh /Users/reginalim/projects/rho/temp_docs/renpy_prototype/
```

## Lint check

Before shipping changes, lint the project:
```bash
/path/to/renpy.sh /Users/reginalim/projects/rho/temp_docs/renpy_prototype/ lint
```
Zero errors expected. Warnings about missing images are expected until real art arrives — the `bg_xxx` images are all defined at the top of `game/script.rpy` as `Composite` placeholders so lint should not flag them.

## File map

```
renpy_prototype/
├── README.md                           this file
├── .gitignore
└── game/
    ├── script.rpy                      entry + main menu + language toggle
    │                                   + placeholder image definitions
    ├── options.rpy                     project config (name, fonts, window)
    ├── scenes/
    │   ├── scene1_en.rpy               Scene 1, English build
    │   └── scene1_cn.rpy               第一场, 简体中文 build
    ├── images/                         (empty — placeholders live inline
    │                                    in script.rpy; drop real PNGs
    │                                    here later, see below)
    ├── fonts/
    │   └── NotoSansSC-Regular.ttf      (YOU MUST PROVIDE THIS)
    └── audio/                          (empty — SFX markers are comments
                                         in scene files; drop OGG files
                                         here when audio pass begins)
```

## Replacing placeholder art

When real BGs arrive, drop them at `game/images/bg_xxx.png` using the existing names:

- `bg_longning_apartment.png` — MC's apartment, warm/cool interior, 22:00
- `bg_kitchen_counter.png` — kitchen counter, night, overhead spill
- `bg_apartment_doorway.png` — apartment doorway interior
- `bg_changning_street.png` — 长宁路 street corner, 22:37, 20°C
- `bg_subway_walk.png` — walk toward subway Line 2
- `cg_mc_counter_placeholder.png` — optional CG of MC at counter

Then **delete the matching `image bg_xxx = Composite(...)` block in `game/script.rpy`** — Ren'Py auto-detects files in `game/images/` and will use the PNG. If you leave the Composite definition in place it will win over the PNG.

## Adding audio

SFX markers are preserved as comments in each scene file, e.g.:
```
# sfx: microwave running, then ding
```

When the audio pass begins:
1. Drop OGG files in `game/audio/` (e.g. `sfx_microwave_ding.ogg`)
2. Replace the `# sfx:` comment with `play sound "sfx_microwave_ding.ogg"` in the scene file

## Known limitations (prototype scope)

- No music. No ambient bed. Silent throughout.
- Placeholder solid-color BGs only. Real CGs, real BGs, and real sprites are post-prototype.
- `fade` and `dissolve` are the only transitions. No custom transforms.
- Main-menu language toggle only — no mid-game language switcher in the Preferences screen. Restart and re-pick from main menu to change languages.
- Choices from the W3 outline (Choice 1 in Scene 4, etc.) are not implemented — Scene 1 has no player choices.
- Scene 2–13 not built. End card routes to main menu on "continue".

## What's next

1. **Regina plays through both builds end-to-end on local machine.** Confirms CJK rendering, scene pacing, transitions, and the overall feel.
2. **Signal fixes.** If any line pacing is off, edit `scene1_en.rpy` or `scene1_cn.rpy`.
3. **Scene 2 port.** Same pattern — one `scene2_en.rpy` + one `scene2_cn.rpy` file, adds BG `bg_xikang_lane` and CG `cg_threshold_crossing` (Priority CG #1 per W3 §8). Adds `label scene2_en_start` / `label scene2_cn_start` and re-routes from Scene 1's `jump end_of_demo_card` to the new scenes.
4. **Choice system.** Per W3 §3, first choice lands in Scene 4. Will use Ren'Py `menu:` blocks with a small `default anchor = 100` persistent integer tracking the anchor mechanic.
5. **Real art and audio.** Post-prototype, once the pipeline is signed off.

## File-by-file responsibilities

| File | Owns |
|---|---|
| `game/options.rpy` | Window size, project name, font paths, save dir, build classification |
| `game/script.rpy` | Entry label, main menu with language toggle, shared characters, placeholder image definitions, end-of-prototype card |
| `game/scenes/scene1_en.rpy` | `label scene1_en_start` — full Scene 1 in English, routes to `end_of_demo_card` |
| `game/scenes/scene1_cn.rpy` | `label scene1_cn_start` — 第一场全文 (简体中文), routes to `end_of_demo_card` |
| `game/fonts/NotoSansSC-Regular.ttf` | CJK rendering — user-provided |
