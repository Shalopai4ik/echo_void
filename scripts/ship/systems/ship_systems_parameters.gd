extends Resource
class_name ShipSystemsParameters

## The tuning surface of the ship's internal architecture (stage 4.1).
##
## Four kinds of number live here, one group per responsibility of the layer - and
## deliberately no more than that. This file is the seam between the architecture
## and the mechanics that land in the sub-stages after it:
##
## - **Power** is the budget the energy system shares out. `reactor_output` is what
##   the reactor makes available before any auxiliary source is registered, and the
##   two ratios are where a grant stops counting as enough. The **Energy** group is
##   the reserve the bus draws from: a capacity, a regeneration rate and the two
##   charge lines a panel warns at. `reactor_output` stays the peak the bus can
##   deliver; a hull whose load outruns `energy_recharge_rate` slowly empties the
##   reserve. Nothing here burns fuel, heats up or wears out - that is still the
##   next sub-stage's job, and it will read and write exactly this group.
## - **Condition** is where integrity stops being "fine". The two lines are what turn
##   a number into the three states the brief asks for.
## - **Impacts** is where a collision becomes hurt. The numbers are here, and the
##   switch is *off*: routing an impact through the ship is architecture and is
##   tested, while deciding what a 600 px/s ram costs is balance, and balance is the
##   next sub-stage's job. Leaving it off also means the shipped game behaves exactly
##   as it did before this layer existed.
## - **Hull** is the same two condition lines applied to the hull's own integrity,
##   which the health system keeps separately from any device's.
##
## Every number is a ratio or a unitless "power unit", never a newton, a watt or a
## hit point. That is the same rule `BoostSystem` follows with its 0..1 tank: the day
## the real unit is known, it is known in one place, and no file has to be re-derived
## from a number somebody guessed here.

@export_group("Power")
## What the reactor makes available before auxiliaries, in power units. The default
## is comfortable for a hull with a handful of devices: the layer must not starve a
## ship that has not been tuned for it yet, and a starved hull reads as a bug in the
## architecture rather than as a design decision.
@export_range(0.0, 5000.0, 1.0, "suffix:units") var reactor_output: float = 240.0
## A grant at or below this fraction of what a device asked for means the device is
## running on nothing. It is checked before `damaged_power_ratio`, so 0.0 here would
## leave a brownout reading as merely damaged.
@export_range(0.0, 1.0, 0.01) var offline_power_ratio: float = 0.05
## A grant below this fraction - but above the offline line - means the device works
## badly. This is the number that makes a brownout visible in the device's own state
## instead of only in the panel's power total.
@export_range(0.0, 1.0, 0.01) var damaged_power_ratio: float = 0.5

@export_group("Energy")
## How much energy the reserve holds, in the same abstract power units the bus
## speaks. One unit of load for one second costs one unit of charge. Zero disables
## the reserve entirely: the bus then behaves exactly as it did in stage 4.1 - an
## unlimited reactor - which is the escape hatch for a test hull or a debugging map.
@export_range(0.0, 100000.0, 10.0, "suffix:units") var energy_capacity: float = 1200.0
## Units the reserve gains per second, before anything is drawn from it. This is the
## sustained generation, deliberately separate from `reactor_output`, which is the
## peak the bus may deliver at any instant: a hull whose devices ask for more than
## this rate slowly drains the reserve instead of starving immediately.
@export_range(0.0, 5000.0, 1.0, "suffix:units/s") var energy_recharge_rate: float = 60.0
## Charge at or below this fraction is a warning, not a failure: the ship still runs.
## `ShipEnergySystem` raises `low_charge` once per crossing, so a listener may treat it
## as an alarm rather than as a level to poll.
@export_range(0.0, 1.0, 0.01) var energy_low_ratio: float = 0.25
## After a full depletion the bus stays dead until the reserve is back above this
## fraction. Without this line a hull at one unit of charge would flap between
## "everything offline" and "everything online" every physics frame.
@export_range(0.0, 1.0, 0.01) var energy_restart_ratio: float = 0.1

@export_group("Condition")
## Integrity below this makes a device DAMAGED. Above it, damage is not yet a word
## the ship uses - which is what keeps a scratch from being reported as a fault.
@export_range(0.0, 1.0, 0.01) var damaged_integrity: float = 0.6
## Integrity at or below this makes a device OFFLINE: it is no longer a working part
## of the ship, whether or not the crew switch is on.
@export_range(0.0, 1.0, 0.01) var offline_integrity: float = 0.15
## What fraction of its capability a DAMAGED device keeps, reported by
## `ShipComponent.efficiency()`. One number for the whole hull on purpose: the
## per-device curves belong to the mechanics sub-stage, and an architecture that
## guesses at them would have to be unpicked later.
@export_range(0.0, 1.0, 0.01) var damaged_efficiency: float = 0.5

@export_group("Impacts")
## Whether a contact with the world is allowed to cost the hull integrity. On: stage
## 4.3 is the damage model, and a hull that cannot be hurt by the rock it just hit is a
## hull with a mechanic nobody can use. The impact event is raised either way, so a
## scripted scene can turn the cost off and still hear the contact.
@export var impact_damage_enabled: bool = true
## Hull integrity lost to a LIGHT contact - a scrape, a nudge while station-keeping.
## The three numbers below are the per-band cost of a collision, in the same points
## `hull_max_integrity` is measured in.
@export_range(0.0, 100000.0, 0.1) var light_impact_damage: float = 0.01
## Hull integrity lost to a MEDIUM contact - the band a pilot would call a hit.
@export_range(0.0, 100000.0, 0.1) var medium_impact_damage: float = 0.05
## Hull integrity lost to a HEAVY contact - a full-cruise ram into a boulder.
@export_range(0.0, 100000.0, 0.1) var heavy_impact_damage: float = 0.15
## How close a mounted device has to be to the contact point to count as the thing that
## was struck, in world px. The point itself is the flight model's estimate (nearest
## surface along the centre-to-centre line), so this is a coarse test on purpose: it
## answers "which compartment", not "which bolt". 0 disables location entirely.
@export_range(0.0, 2000.0, 5.0, "suffix:px") var component_hit_radius: float = 90.0
## Fraction of the hull's *applied* damage that the struck device also takes, in device
## ratio units. 0 keeps the location in the impact event but spares the device; 0.5 means
## a hit that took 10% off the hull takes 5% off the device.
@export_range(0.0, 4.0, 0.05) var impact_device_damage_scale: float = 0.5

@export_group("Hull")
## What a whole hull is worth, in hit points. The default of 1.0 keeps the layer's
## original ratio: damage numbers are read as fractions of the hull. Raise it to 100 or
## 1000 for a game that wants visible hit points, and scale the three impact numbers
## above with it - `hull_integrity` is stored in these points, `hull_ratio` is the
## fraction that the state rules and the HUD consume.
@export_range(0.001, 100000.0, 1.0, "suffix:points") var hull_max_integrity: float = 1.0
## Hull ratio at or below which the hull is CRITICAL. Raised once when crossed, so it is
## an alarm rather than a level; the three-word condition (`damaged_integrity`) is a
## separate, coarser line and is not replaced by this one.
@export_range(0.0, 1.0, 0.01) var critical_hull_ratio: float = 0.25
## Extra multiplier per damage source: `{"arc": 0.5, "fire": 1.5}`. A source that is not
## in the table costs exactly what the caller asked for, so a new hazard needs no edit
## here at all. Keys are the same free-text `source` strings the damage API already
## takes; values are clamped away from negative and non-finite numbers.
@export var damage_source_scale: Dictionary = {}