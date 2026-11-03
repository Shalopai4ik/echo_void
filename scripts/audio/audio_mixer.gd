class_name AudioMixer

## The project's bus names, and the one seam a future settings menu talks to.
##
## Sub-stage 1.5 asks for a mixer that is "organized understandably" and for the
## volume knobs to exist before the menu that will drive them does. Both live here:
## `default_bus_layout.tres` carries the buses and their starting levels, and every
## runtime change goes through one of the functions below rather than a raw
## `AudioServer` call scattered through the ship.
##
## The hierarchy is a mixing decision, not decoration:
##
##     Master
##     |- Ambience          the void: the gas giant, later a hull creak, a distant thing
##     |- Ship              every sound the player's own hull makes
##     |   |- ShipEngines   the continuous thruster layers
##     |   |- ShipSystems   short signals, the boost tank, the stabilization switch
##     |   `- ShipImpacts   collisions, kept apart so a hit can be raised without
##     |                    raising the engines with it
##     `- UI                menus and prompts, which must never be ducked by a burn
##
## A settings menu therefore needs no knowledge of the ship: it sets `Master` for
## overall volume, `Ship` for "the ship", `ShipEngines` for the thrusters,
## `ShipSystems` for the signals, `ShipImpacts` for collisions. `Ship` moving means
## its three children move with it and `Ambience`/`UI` stay where they were, which
## is exactly the split the spec asks for.
##
## Every helper is failure-tolerant on purpose. A project without the layout - a
## bare test scene, a build that forgot to ship the `.tres` - answers `Master` for
## any missing bus instead of raising an error from the audio thread. `has_bus()`
## is what a caller checks when it genuinely needs to know the difference.

const MASTER := &"Master"
const AMBIENCE := &"Ambience"
const SHIP := &"Ship"
const SHIP_ENGINES := &"ShipEngines"
const SHIP_SYSTEMS := &"ShipSystems"
const SHIP_IMPACTS := &"ShipImpacts"
const UI := &"UI"

## The buses the layout is expected to carry, in creation order. Read by the ship's
## audio component (to pick a fallback) and by the regression test (to prove the
## layout actually arrived).
const ALL := [MASTER, AMBIENCE, SHIP, SHIP_ENGINES, SHIP_SYSTEMS, SHIP_IMPACTS, UI]


## The bus index for a name, or `Master` when the name is not in the layout. A
## `StringName` in, an `int` out: every `AudioServer` call wants the index, and no
## caller should have to remember that `-1` has to be folded to a usable bus.
static func index(bus: StringName) -> int:
	var found := AudioServer.get_bus_index(bus)
	return found if found >= 0 else 0


## Whether the running project really has this bus. The one honest question when a
## caller's behaviour differs between "quiet" and "silently rerouted to Master".
static func has_bus(bus: StringName) -> bool:
	return AudioServer.get_bus_index(bus) >= 0


## Bus level in decibels. Reading a missing bus reads Master, which is the value
## that was actually in force.
static func volume_db(bus: StringName) -> float:
	return AudioServer.get_bus_volume_db(index(bus))


## Bus level as a 0..1 linear amplitude, the unit a settings slider prefers. The
## clamp keeps a mis-set `+12 dB` from being handed back as a gain above 1.0.
static func volume_linear(bus: StringName) -> float:
	return clampf(db_to_linear(volume_db(bus)), 0.0, 1.0)


static func set_volume_db(bus: StringName, db: float) -> void:
	AudioServer.set_bus_volume_db(index(bus), db)


static func set_volume_linear(bus: StringName, linear: float) -> void:
	AudioServer.set_bus_volume_db(index(bus), linear_to_db(clampf(linear, 0.0, 1.0)))


static func set_muted(bus: StringName, muted: bool) -> void:
	AudioServer.set_bus_mute(index(bus), muted)


static func is_muted(bus: StringName) -> bool:
	return AudioServer.is_bus_mute(index(bus))