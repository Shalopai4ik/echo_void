# Ship audio drop-in directory

`ShipAudio` (`scripts/ship/ship_audio.gd`) resolves every sound by **file name** from
this folder. It tries `.ogg`, then `.wav`, then `.mp3`, and caches the answer for the
lifetime of the component. Dropping a correctly named file in here is the whole of
"installing" a sound; no script, scene or resource needs to change.

A name with no file is not an error. The layer stays silent, one-shot intents are still
counted and rate-limited, and the debug panel reports the inventory as
`audio ON 0/19 streams`. The project ships with no audio files yet.

Continuous layers are set to loop automatically (`AudioStreamWAV` gets a forward loop
over its whole length; OGG and MP3 get their `loop` flag). One-shots are played raw.

## Continuous layers → bus `ShipEngines`

| file base name   | driven by                                   |
|------------------|---------------------------------------------|
| `engine_main`    | `EngineController.main_power` (0..1.5)      |
| `engine_retro`   | `brake_power + astern_power` (emergency +3 dB) |
| `engine_strafe`  | `abs(strafe_power)`                          |
| `engine_rotation`| `abs(rotation_power)`                        |
| `boost_layer`    | the boost authority factor above 1.0         |
| `stabilizer_bed` | `stabilization.authority` (optional, quiet)  |

## One-shot events

Collisions → bus `ShipImpacts`:

| `impact_light` | `impact_medium` | `impact_heavy` |
|---|---|---|

System signals → bus `ShipSystems`:

| `stabilizer_on` | `stabilizer_off` |
|---|---|
| `boost_on` | `boost_low` | `boost_empty` | `boost_ready` |
| `control_on` | `control_off` | `emergency_on` | `power_on` |

## Mixing

`default_bus_layout.tres` carries `Master → Ambience / Ship / UI`, with
`ShipEngines`, `ShipSystems` and `ShipImpacts` under `Ship`. Per-layer levels and fade
times live in `assets/ship/audio_parameters.tres` (class `ShipAudioParameters`), so the
ship can be re-voiced from the inspector. A future settings menu should change bus
levels through `AudioMixer` (`scripts/audio/audio_mixer.gd`) rather than touching the
players.