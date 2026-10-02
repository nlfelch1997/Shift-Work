# Audio credits

Every file in `res://audio/` is listed here with where it came from and its
license. Rebuild them all with `tools/build_audio.py` (it documents every
trim, mix and synth step).

**Only one file needs an attribution credit: the selling-phase music.**
Everything else is CC0 (public domain): crediting is not required, but
Kenney is credited below as a courtesy.

## Required attribution (put this on the Credits screen / Steam page)

> "Monkeys Spinning Monkeys" Kevin MacLeod (incompetech.com)
> Licensed under Creative Commons: By Attribution 3.0 License
> http://creativecommons.org/licenses/by/3.0/

- File: `music/selling_loop.ogg` (unmodified)
- Track: search "Monkeys Spinning Monkeys" at https://incompetech.com/music/royalty-free/music.html
- Obtained from: the Godot demo projects, which ship this exact file under
  the CC-BY 3.0 line above —
  https://github.com/godotengine/godot-demo-projects/blob/3e08537616661a5883831628decab4c526260289/audio/audio_effects/sfx/music_monkeys_spinning_monkeys.ogg
  (incompetech.com itself was not reachable from the build environment; if
  you re-download it from incompetech today it is offered under CC-BY 4.0,
  whose credit line is the same with "4.0" / `.../by/4.0/`).

## CC0 sources

| File(s) | Source | Author | License |
|---|---|---|---|
| `sfx/pickup` (pluck_002), `sfx/drop` (drop_002), `sfx/broom_sweep_1/2` (scratch_001/002), `sfx/clean_chime` (confirmation_003), `sfx/all_clean` (confirmation_004 + glass_003), `sfx/order_filled` (confirmation_002), `sfx/ui_buy` (confirmation_001), part of `sfx/clock_out` (bong_001) | [Kenney — Interface Sounds](https://kenney.nl/assets/interface-sounds), via Calinou's verbatim Godot packaging https://github.com/Calinou/kenney-interface-sounds (commit `4596a49`) | Kenney | CC0 |
| `sfx/ui_click` (click1), part of `sfx/clock_out` (switch2), part of `sfx/paycheck_chaching` (switch7) | [Kenney — UI Audio](https://kenney.nl/assets/ui-audio), via https://github.com/Calinou/kenney-ui-audio (commit `8c3d81b`) | Kenney | CC0 |
| `sfx/footstep_1`–`6` (sliced from walking.ogg) | Kenney's official [Starter Kit FPS](https://github.com/KenneyNL/Starter-Kit-FPS) (commit `185fd23`) | Kenney | CC0 |
| `sfx/box_thud` (land.ogg), parts of `sfx/stack_collapse` (land, break), part of `sfx/paycheck_chaching` (coin) | Kenney's official [Starter Kit 3D Platformer](https://github.com/KenneyNL/Starter-Kit-3D-Platformer) (commit `3fa8a04`) | Kenney | CC0 |
| `sfx/forklift_engine_loop` (engine.ogg), part of `sfx/forklift_ram` (impact.ogg) | Kenney's official [Starter Kit Racing](https://github.com/KenneyNL/Starter-Kit-Racing) (commit `2f2e5f2`) | Kenney | CC0 |
| `sfx/place_shelf` (placement-a.ogg), `sfx/pan_dump` (removal-a.ogg) | Kenney's official [Starter Kit City Builder](https://github.com/KenneyNL/Starter-Kit-City-Builder) (commit `4535092`) | Kenney | CC0 |
| `sfx/impact_heavy`, parts of `sfx/stack_collapse` / `sfx/forklift_ram` | [Freesound #532873](https://freesound.org/people/FFeller/sounds/532873/), via godot-demo-projects `3d/ragdoll_physics/sounds/impact_big.wav` | FFeller | CC0 |
| `sfx/impact_light`, part of `sfx/stack_collapse` | [Freesound #381626](https://freesound.org/people/dorian.mastin/sounds/381626/), via godot-demo-projects `3d/ragdoll_physics/sounds/impact_small.wav` | dorian.mastin | CC0 |
| `sfx/register_ding`, `sfx/store_open_bell`, part of `sfx/paycheck_chaching` | [Freesound #361564 "Ding"](https://freesound.org/people/MatthewWong/sounds/361564/), via godot-demo-projects `audio/audio_effects/sfx/Ding.wav` | MatthewWong | CC0 |
| `sfx/glass_break` | [Freesound #244238 "Glass Breaking"](https://freesound.org/people/chewiesmissus/sounds/244238/), via godot-demo-projects | chewiesmissus | CC0 |
| `sfx/manager_whistle`, `sfx/manager_tweet` | [Freesound #320150 "Whistle"](https://freesound.org/people/OwlStorm/sounds/320150/), via godot-demo-projects | OwlStorm | CC0 |
| `sfx/writeup_trombone` | [Freesound #175409 "Sad Trombone"](https://freesound.org/people/kirbydx/sounds/175409/), via godot-demo-projects | kirbydx | CC0 |
| `sfx/order_missed` | [Freesound #253886 "Negative Beeps"](https://freesound.org/people/themusicalnomad/sounds/253886/), via godot-demo-projects | themusicalnomad | CC0 |

Each Kenney starter kit's README states: "Assets included in this package (2D
sprites, 3D models and sound effects) are CC0 licensed" (the kits' code is
MIT; none of their code is used here).

The Freesound files were taken from
https://github.com/godotengine/godot-demo-projects (commit `3e08537`), whose
READMEs / per-file LICENSE notes give the Freesound links, authors and CC0
license quoted above.

## Made for this project (CC0)

Synthesized from scratch in `tools/build_audio.py` (oscillators and filtered
noise, no samples) for effects no free pack matched well:

- `sfx/forklift_beep`, `sfx/forklift_alert` — backup beeper and the ram "!!" chirp
- `sfx/forklift_bonk` — cartoon bonk + spring boing (a forklift bump is slapstick)
- `sfx/throw_whoosh`, `sfx/mop_swish_1/2`, `sfx/spill_splat`
- `sfx/order_chime` — three-tone "attention shoppers" PA chime
- `sfx/flicker_sting` — fluorescent hum cutting out + a goofy "boo-WOMP"
- `final_shift.ogg` — "ta-ta-ta TAAA!" major-key fanfare
- `music/prep_loop.ogg` — 40 s lazy supermarket muzak loop (prep, cleanup, menus, report)
