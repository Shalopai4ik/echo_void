# Audio: what exists, what is missing

The audio subsystem is written and wired. The sound files are not.

## What is in place

| Piece | File | State |
| --- | --- | --- |
| Event surface | `scripts/ship/ship_audio.gd` | complete, 18 named streams, 8 one-shot voices |
| Mixer | `scripts/audio/audio_mixer.gd` | complete |
| Bus layout | `default_bus_layout.tres` | 7 buses |
| Parameters | `scripts/ship/ship_audio_parameters.gd` (+ `assets/ship/audio_parameters.tres`) | complete |
| Tests | `tests/stage1_5_audio_test.gd` | 105 asserts, all passing |

The seven buses: `Master`, `Ambience`, `Ship`, `ShipEngines` and `ShipSystems`
and `ShipImpacts` (both children of `Ship`), `UI` (child of `Master`).

## What is missing

`assets/audio/ship/` contains **no sound files**. Every stream is silent in a
running build.

Deliberate decision: **no placeholder audio was generated.** A file invented to
make a test green would make the silence harder to see, not easier. Instead the
gap is reported by `tools/validation/asset_check.py` as a warning, and this
document is the list to fill.

`ship_audio.gd` is explicit that this is a normal state: `missing_streams()` and
`report()` exist to name what is absent, and `total_streams()` returning zero is
a valid answer today.

## Naming and format requirements

The lookup rule in `ship_audio.gd` is the whole contract: the base name is the
constant below, the directory is `res://assets/audio/ship/`, and the extension is
the first of `.ogg`, `.wav`, `.mp3` that resolves.

* So `engine_main.ogg` or `engine_main.wav` - not `EngineMain.wav`.
* Mono for anything positional, stereo for ambience beds.
* Peak normalised to -1 dBFS, so `ShipAudioParameters`' decibel levels are the
  only gain stage.
* Missing audio is a normal state: the code resolves a stream to null, counts the
  intent anyway, and never raises an error.

## The 18 streams

Five **continuous layers**, each with its own `AudioStreamPlayer` created once in
`_ready()` and ramped with `move_toward`, so they crossfade instead of stacking:

| Constant | Key | Driven by |
| --- | --- | --- |
| `LAYER_MAIN` | `engine_main` | main engine authority, plus boost |
| `LAYER_RETRO` | `engine_retro` | retro plant, ordinary brake and astern |
| `LAYER_STRAFE` | `engine_strafe` | strafe pair authority |
| `LAYER_ROTATION` | `engine_rotation` | yaw verniers |
| `LAYER_STABILIZER` | `stabilizer_bed` | stabilizer residual; mixed *under* the thrusters |

Thirteen **one-shot events**, played through a fixed pool of eight voices
(`VOICE_COUNT := 8`). Creating a player per event is forbidden by the design, so
do not ask for more voices without changing that:

| Constant | Key | Fires when |
| --- | --- | --- |
| `EVENT_IMPACT_LIGHT` | `impact_light` | a light collision |
| `EVENT_IMPACT_MEDIUM` | `impact_medium` | a medium collision |
| `EVENT_IMPACT_HEAVY` | `impact_heavy` | a heavy collision |
| `EVENT_STAB_ON` | `stabilizer_on` | the stabilizer takes a borrowed lever |
| `EVENT_STAB_OFF` | `stabilizer_off` | it hands it back |
| `EVENT_BOOST_ON` | `boost_on` | boost engages |
| `EVENT_BOOST_LOW` | `boost_low` | the tank drops below its low threshold |
| `EVENT_BOOST_EMPTY` | `boost_empty` | the tank runs dry |
| `EVENT_BOOST_READY` | `boost_ready` | the tank refills enough to burn again |
| `EVENT_CONTROL_ON` | `control_on` | controls are re-enabled |
| `EVENT_CONTROL_OFF` | `control_off` | controls are cut |
| `EVENT_EMERGENCY` | `emergency_on` | the emergency brake bites |
| `EVENT_POWER_ON` | `power_on` | the reactor restarts after a wreck |

There is also a global impact limiter keyed `@impact` (`_IMPACT_GATE`) that gates
all three impacts together; it is not a stream and needs no file.

## Bus assignment

`ship_audio.gd` does not set the bus per stream - `ShipAudioParameters` carries
the level per category in dB relative to its bus, and the bus is chosen where the
player is created. The intended routing, and the one to verify after the files
land:

* engine layers and stabilizer bed -> `ShipEngines`
* impacts, emergency and the boost-empty warning -> `ShipImpacts`
* control on/off and power on -> `ShipSystems`
* anything UI-ish -> `UI`

## Verify after adding sounds

* no `ERROR` at load and no `Failed to load` in the log;
* `loaded_streams()` equals `total_streams()` and `missing_streams()` is empty;
* `AudioMixer`'s volume control moves it and nothing else;
* a released `W` does not click the hum off, and boost does not snap in - the
  response time in `ShipAudioParameters` is what makes that true;
* pressing boost leaves `engine_main` ramping, not `engine_retro` playing
  underneath - the layers must crossfade, never stack;
* `tests/stage1_5_audio_test.gd` still reports `ALL PASS`.

