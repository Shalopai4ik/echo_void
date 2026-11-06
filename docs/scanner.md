# The survey scanner

One device that answers one question: **what is out there, and how much of it can
this hull actually tell?** It is the first mechanic built on the ship's internal
systems (power, condition, equipment), and it deliberately stops at the answer - no
panel, no markers, no experience, no research tree.

## Where it lives

| file | what it is |
| --- | --- |
| `scripts/ship/systems/scanner_system.gd` | `ShipScanner`, a `ShipComponent`. The sweep, its timing, its energy, its refusals |
| `scripts/scan/scanner_profile.gd` | `ScannerProfile`: the sweep's numbers and its whole vocabulary |
| `scripts/scan/scan_signature.gd` | `ScanSignature`: one kind of return, its thresholds and what it reveals |
| `assets/ship/scanner_profile.tres` | the shipping profile: nine signatures, two of them phantom |
| `scripts/world/world_field.gd` → `objects_near()` | the one world question a sweep asks |
| `scenes/world/SpaceMap.tscn` | the device, mounted under `Ship/Systems` |
| `tests/scanner_test.gd` | 105 asserts over thirteen phases |

Nothing else was edited to add it: no hub, no energy system, no health system, no
HUD, no flight model. The scanner is a device, and devices are nodes under
`Ship/Systems`.

It is mounted by `SpaceMap.tscn`, not by `Ship.tscn`, and that is deliberate: the
hull scene is the regression fixture several suites count devices on, and the
scanner's own suite loads the map to prove the shipping wiring. The map adds the
node to an editable instance of the hull, so the device is a real `ShipComponent`
under `Ship/Systems` at run time and the hull scene stays exactly as it was. Moving
it into `Ship.tscn` later is a one-line scene change and three count assertions - not
a code change.

Energy: the profile's `sweep_energy_cost` (12 units) is paid per pulse through
`ShipSystems.spend_energy()`; the device's `nominal_power_draw` (6 units) is what it
costs to keep the sensor lit afterwards. It ships cold (`starts_enabled = false`) and
the first order lights it, so a hull that never surveys pays nothing for the dish.

## The sweep

`start_scan()` is the whole command. It returns a bool and refuses in four named
ways:

| refusal | when |
| --- | --- |
| `busy` | a sweep is already running |
| `offline` | the sensor could not be switched on (wreck, or the switch was left off with `auto_start` disabled) |
| `unpowered` | the sensor is on the bus but the allocation granted it nothing - a brownout |
| `energy` | the reserve could not pay the pulse |

A refusal spends nothing and emits `scan_refused(reason)`. An order for a cold
sensor lights it first (`auto_start`), so one key is one action for the pilot: `R`,
the same key the radar dish already answers.

Then, once per order:

1. **One area query.** `world.objects_near(center, radius, limit)` walks the chunk
   grid, not the object list: it looks up the chunk keys that cover the disc and
   measures only their children. It builds nothing, unloads nothing and remembers
   nothing, and it costs a few dictionary probes in an empty region however large
   the world is. Measured in `scanner_test`: about 120 microseconds over a loaded
   window with 160 live objects.
2. **Classification, in arithmetic.** For each candidate the profile answers with a
   signature or does not. The measured return is
   `strength * (1 - d / range) ^ 0.85 * sensitivity * condition`, and the signature's
   two thresholds decide whether the contact is reported and whether it is named.
3. **Delivery across the sweep.** Contacts are spaced by index across
   `sweep_seconds`, so a sweep is something the pilot waits on and the per-frame cost
   of a scan is arithmetic over a list, not a query. `contact_found` fires per
   contact; `scan_completed` carries the whole list.

Nothing runs per frame while no sweep is in flight: the device disables its own
`_physics_process` when the sweep ends.

## The contact

Every listener gets the same dictionary. It is a *value*, not a node: an object can
be recycled the moment a chunk unloads, so a contact carries an identity that
survives that.

| key | meaning |
| --- | --- |
| `id` | `chunk:item` for a world object (the same key `ChunkStateStore` uses), `sig:x,y` for a signal, `obj:<instance>` for something the field did not place |
| `source` | `object` or `signal` |
| `kind` | the signature's kind once named, otherwise `unknown_signal` or `anomaly` |
| `signature` | which profile entry answered |
| `identified` | is this thing named |
| `title` | the name, or `""` - an unidentified contact has no name at all |
| `position`, `bearing`, `distance` | where it was, as the hull saw it |
| `strength` | the measured return, 0..1 |
| `population` | the world population it came from, `""` for a signal |
| `info` | the object's own numbers, filtered by the signature's `reveal_keys` |
| `at` | physics time of the sweep |

`title` and `info` are the two fields that carry knowledge, and both are empty until
the return is strong enough to name the thing. A derelict at the far edge of the
disc is an `anomaly` with no name and no numbers; the same derelict at 300 px is a
`derelict`. Nothing about its interior is ever revealed by a range finder - that is
the research stage's business.

## Two doors out

Both carry the same dictionaries, and a listener needs only one of them:

* **Godot signals** on the device: `scan_started`, `contact_found`,
  `scan_completed`, `scan_cancelled`, `scan_refused`. A panel, a research stage or a
  test holds the device and connects.
* **The ship's bus**: `publish("scan_started" | "scan_completed" | "scan_cancelled")`
  becomes a `ShipSystemEvent` of kind `EQUIPMENT` with `data.topic`, delivered to
  every mounted device and to every listener of `ShipSystems.system_event`. That is
  how a system that has never heard of the scanner reacts to a sweep.

No `Node` reference travels in a contact, on purpose: a signal handler that kept one
would point at a recycled body.

## Adding a kind of thing to find

A new signature in `assets/ship/scanner_profile.tres` and nothing else:

```gdscript
[sub_resource type="Resource" id="Resource_ice"]
script = ExtResource("2_signature")
id = "ice_body"
kind = "ice"
title = "ice body"
uncertain_kind = "unknown_signal"
populations = PackedStringArray("ice")
strength = 0.8
detect_at = 0.04
identify_at = 0.25
reveal_keys = PackedStringArray("px_scale")
```

A signature matches by world population (`SpaceObjectKind.label`), by node group, or
by `WorldObjects.kind_of()` - whichever the object actually answers, which is the
project's existing rule for "what is this thing". The first signature that matches
answers for an object, so a named population goes above a general group. The scanner
has no list of kinds in it and does not need one.

Two knobs decide the whole feel of a signature: `detect_at` (below it, nothing is
reported) and `identify_at` (at or above it, the contact is named). Because the
return falls off with distance, they are also two ranges: a thing can be findable
and still a mystery until the hull gets closer. That is where "not everything is
found on the first sweep" comes from.

## Unknown signals and anomalies

A signature may have `phantom = true`: no object, no population, just a lattice of
world cells and the world's own hash. A cell whose hash is below `phantom_chance`
raises a contact at its centre, with `id = "sig:x,y"`.

Three properties make that worth the code:

* **deterministic** - the same cell raises the same signal on every sweep and every
  visit, from the field's own `get_seed()`; nothing is stored;
* **honest** - a phantom is never named (the shipping entries sit above 1.0 on
  `identify_at`), carries no `info`, and reads as an `anomaly` or an `unknown_signal`;
* **addressable** - its id is its cell, which is exactly what a later research stage
  needs in order to attach content to it.

The walk is bounded: a cell never falls below a sixteenth of the range, so one sweep
hashes at most about a thousand cells whatever the profile says.

## Upgrade seams

The device exposes two multipliers and a profile swap, so a later upgrade system does
not need a new device type:

* `set_range_multiplier(x)` - a better dish is a bigger disc;
* `set_sensitivity(x)` - a better receiver names weaker returns;
* `set_profile(p)` - a better sensor with a vocabulary this one does not have.

Condition multiplies in from `integrity`: a damaged dish sweeps a smaller disc and
takes longer over it (`range_now()`, `sweep_seconds_now()`), and a wrecked one
refuses the order at the same door every other device does. `integrity` and not
`efficiency()` is read on purpose - a sensor that is merely switched off is not a
damaged sensor, and a panel has to be able to show its range before the pilot commits
a pulse to it.

## What it deliberately does not do

* no scanner interface and no hotkey beyond the shared `R`: a panel is its own
  sub-stage. `ScannerProfile.icon` is where that panel will look for its art;
* no research, no experience, no discovery log: the contact list is returned and
  forgotten. Persistence will key on `contact.id`;
* no HUD marker: the radar dish (`scripts/hud.gd`) still draws its own picture from
  the field's bodies on `R`, and was not touched;
* no ship-side objects: the field streams what world generation put there. A scanner
  cannot invent an asteroid, and it never generates a chunk to satisfy a sweep - if
  the range reaches past the built window, the answer is simply thinner;
* the gas giant is not a world population, so a sweep does not report it. Making it
  one is a world-generation decision, not a scanner one.

## Verifying

```powershell
godot --headless --path . --script tests/scanner_test.gd
tools\testing\run_tests.ps1 -Suite scanner_test
```

The suite's thirteen phases: the disc, naming thresholds, silence, range and damage,
one-sweep-at-a-time, energy, pacing, delivery on both channels, interruptions,
upgrades, signals, the real world field, teardown.