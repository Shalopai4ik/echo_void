extends Node
class_name ShipComponent

## A device the ship carries: one sensor, one drill, one reactor monitor.
##
## This is the whole of what "equipment" means in this architecture, and it is a
## `Node` rather than a resource for one reason: a device is placed in the scene by
## the person building the hull, it may draw something, and it must be able to come
## and go with the tree. What it is *not* is a second flight model - a component owns
## no velocity, applies no force and never touches `ShipController`. Its job is to
## say four things about itself and to answer when the ship tells it something:
##
##     identity     component_id / title
##     appetite     nominal_power_draw / power_priority
##     condition    enabled / integrity -> state
##     voice        the four signals below, plus publish() for its own vocabulary
##
## Mounting one is the whole installation procedure: drop the node under
## `Ship/Systems` (or under another node that is), and the component finds the hub by
## walking up the tree in `_ready()`. No registration call, no global, no list to
## edit - which is the requirement that a new onboard device must not need a change
## to the ship's code.
##
## Two rules keep it from becoming a tangle:
##
## 1. **The component does not decide its own state.** `state` is derived by
##    `ShipSystemState.evaluate()` from the switch, the integrity, the power that was
##    actually granted, and whether the hull is still a ship. A device cannot declare
##    itself nominal after being wrecked, and a test can prove it by moving the inputs.
## 2. **The component does not talk to another component.** It publishes an event to
##    the hub; whoever cares hears it through `receive_event()`. Direct references
##    between devices are how equipment ends up impossible to reorder.
##
## The base class deliberately ships with no `_process` and no `_physics_process`:
## a device that needs per-frame work adds its own, and the hull of an unpowered
## survey ship stays free of sixty calls a second that do nothing.

## The derived condition moved. Emitted after the switch or the numbers changed, so a
## listener always sees a state that matches the fields it can read right now.
signal state_changed(previous: int, current: int)
## The share of its appetite the energy system granted this device, 0..1.
signal power_changed(ratio: float)
## Integrity moved, in either direction.
signal integrity_changed(integrity: float)
## The crew switch moved. Emitted after `state_changed`, so a listener that reacts to
## the switch already sees the state the switch produced.
signal enabled_changed(enabled: bool)
## The ship refused to light this device: the reserve could not pay the switch-on cost,
## the hull is destroyed, or the device itself is wrecked. Emitted *instead* of
## `enabled_changed`: the device is still off. Nothing is spent on a power refusal; the
## hub's `activation_denied()` carries the one-word reason for the other two.
signal activation_refused(cost: float)

## The stable name the hub files this device under. Left empty, the node's own name
## is used in snake_case - which is what makes dropping a node into the scene enough
## to install it.
@export var component_id: String = ""
## What the panel and a log call it. Falls back to the node name.
@export var title: String = ""
## Who gets power first when there is not enough. Higher wins; equal priorities are
## served in the order the devices registered, so the order is never a coin toss.
@export_range(0, 1000, 1) var power_priority: int = 0
## What the device wants from the bus, in `ShipSystemsParameters` power units. Zero
## means passive: it is granted 1.0 and never appears in a brownout.
@export_range(0.0, 5000.0, 1.0, "suffix:units") var nominal_power_draw: float = 0.0
## Power units this device feeds back into the bus while it works - a generator, an
## auxiliary reactor, a charged battery. Zero, the default, means "consumer only", which
## is every device that existed before this seam: mounting one changes nothing. The
## supply is scaled by what is left of the device, so damaging a power source is a real
## brownout for its neighbours and wrecking it is a real one for the ship.
@export_range(0.0, 5000.0, 1.0, "suffix:units") var power_supply: float = 0.0
## Whether the device is on the bus when the scene starts. A hull that ships with a
## dead sensor says so here rather than in code.
@export var starts_enabled: bool = true
## What it costs to throw the switch from off to on, in `ShipSystemsParameters` power
## units - a one-off, not a rate. `nominal_power_draw` is what the device then costs per
## second; this is the surge that lights it. Zero means the switch is free, and a hull
## without a systems layer behaves exactly as it did before the reserve existed.
@export_range(0.0, 5000.0, 1.0, "suffix:units") var activation_energy_cost: float = 0.0

## The crew switch. Off means the device is off the bus and draws nothing.
var enabled := true
## What is left of it, 0..1. The health system is the only writer.
var integrity := 1.0
## What the energy system granted it, 0..1 of `nominal_power_draw`.
var power_ratio := 1.0
## The derived condition, `ShipSystemState.Value`.
var state: int = ShipSystemState.Value.NOMINAL

## The hub this device registered with, or null for one built outside a ship.
## Typed as `Node` and called through `call()` on purpose: `ShipSystems` names
## `ShipComponent` and this file names `ShipSystems`, and a static cycle between two
## `class_name` scripts is a problem the compiler should not have to solve for a
## single back-reference.
var systems: Node

var _parameters: ShipSystemsParameters
var _fallback: ShipSystemsParameters


func _ready() -> void:
	if component_id.is_empty():
		component_id = String(name).to_snake_case()
	enabled = starts_enabled
	_attach()


## Find the hub on the way up the tree and register with it. The hub is recognised by
## its own interface rather than by a path or a group: a ship built in code, a device
## under an intermediate container and a test fixture all work the same way.
func _attach() -> void:
	var node := get_parent()
	while node != null:
		if node.has_method("register_component") and node.has_method("publish") \
				and node.has_method("settings"):
			systems = node
			node.call("register_component", self)
			return
		node = node.get_parent()


func _exit_tree() -> void:
	if systems != null and is_instance_valid(systems) and systems.has_method("unregister_component"):
		systems.call("unregister_component", self)
	systems = null


## Called by the hub when the device is registered and again whenever the tuning
## resource is replaced. Not for the device to call itself.
func configure(parameters: ShipSystemsParameters) -> void:
	_parameters = parameters
	_refresh_state()


## The tuning resource in force, or the shipping defaults for a device built without
## a ship around it.
func settings() -> ShipSystemsParameters:
	if _parameters != null:
		return _parameters
	if _fallback == null:
		_fallback = ShipSystemsParameters.new()
	return _fallback


## The id the hub files this device under.
func resolved_id() -> String:
	if not component_id.is_empty():
		return component_id
	return String(name).to_snake_case()


## A human-readable name for a panel line.
func display_name() -> String:
	return title if not title.is_empty() else resolved_id()


## Does this device want a share of the bus right now? Deliberately does *not* consult
## `state`: the state depends on the grant, and the grant would depend on the state -
## the two would chase each other. The switch and the integrity are enough, and they
## are the two things a device cannot change behind the energy system's back.
func draws_power() -> bool:
	return enabled and integrity > settings().offline_integrity


## What this device is actually feeding the bus right now, in power units. Zero for a
## consumer, and zero for a generator that is off, wrecked, or mounted on a hull that is
## no longer a ship. The rest of the time it is the nameplate `power_supply` scaled by
## what is left of the device, so a damaged generator browns out its neighbours instead
## of switching them off in one step.
##
## Deliberately reads integrity, never the power grant: the grant depends on the bus
## output, and the output would then depend on the grant - a loop with no fixed point.
func supplied_power() -> float:
	if power_supply <= 0.0 or not is_finite(power_supply):
		return 0.0
	if not enabled or not can_start():
		return 0.0
	if systems != null and is_instance_valid(systems) \
			and systems.has_method("is_hull_destroyed") \
			and bool(systems.call("is_hull_destroyed")):
		return 0.0
	return maxf(power_supply, 0.0) * clampf(integrity, 0.0, 1.0)


## How much of its capability the device may use: 1.0 nominal, the resource's
## `damaged_efficiency` when damaged, 0 when offline. This is the number a device's
## own code multiplies by - and the reason a brownout is felt rather than merely
## printed.
func efficiency() -> float:
	match state:
		ShipSystemState.Value.NOMINAL:
			return 1.0
		ShipSystemState.Value.DAMAGED:
			return settings().damaged_efficiency
		_:
			return 0.0


func is_operational() -> bool:
	return ShipSystemState.is_operational(state)


## Can the hull's damage allow this device to be lit at all? This is the physical
## question; whether the reserve can pay the switch-on price is the hub's. A device at
## or below `offline_integrity` is a wreck: it may still have its crew switch on (the
## switch is not damage), but it cannot be switched *on* and it draws nothing.
func can_start() -> bool:
	return integrity > settings().offline_integrity


## Why the switch cannot move, in one word, or "" when it can. `destroyed` belongs to
## the hull and is answered by the hub; this file only knows its own condition.
func start_block_reason() -> String:
	return "" if can_start() else "wrecked"


## Flip the crew switch. Called by the hub's `set_enabled()` and by the device itself;
## the state change is derived here, so nothing can be switched on and left broken.
##
## `enabled == value` is checked first, which is what makes the switch-on cost a
## one-off: an already-lit device (or a second button press in the same frame) cannot
## pay for the same activation twice. When the reserve is short the switch does not
## move and `activation_refused` is emitted instead.
func set_enabled(value: bool) -> void:
	if enabled == value:
		return
	if value and not _request_start_energy():
		activation_refused.emit(activation_energy_cost)
		return
	enabled = value
	_refresh_state()
	enabled_changed.emit(enabled)


## Ask the ship whether this device may be lit: the hull must not be a wreck and the
## reserve must cover the switch-on price. A device outside a ship (a fixture, a node
## under construction) has no ship to ask and is allowed to start - the check exists to
## be honest about a mounted device, not to make a component unusable alone.
##
## Free devices ask too, because a wrecked hull must refuse even a switch that costs
## nothing. The hub's `request_activation()` performs the same checks itself, so a
## caller that reaches around this method still cannot light a wreck.
func _request_start_energy() -> bool:
	if systems == null or not is_instance_valid(systems) \
			or not systems.has_method("request_activation"):
		return true
	return bool(systems.call("request_activation", self))


## Written by the health system only. Clamped, because a negative integrity or one
## above 1.0 would make every comparison downstream meaningless. A non-finite value
## (NaN from a broken formula) is refused rather than clamped: `clampf()` keeps a NaN,
## and one NaN would make the device's state depend on comparison order for ever.
func set_integrity(value: float) -> void:
	if not is_finite(value):
		return
	var next := clampf(value, 0.0, 1.0)
	if is_equal_approx(next, integrity):
		return
	integrity = next
	integrity_changed.emit(integrity)
	_refresh_state()


## Written by the energy system only: the fraction of the appetite that was granted.
## Non-finite input is refused for the same reason as integrity: a NaN grant would
## leave the device reading NOMINAL while it is fed nothing.
func set_power_ratio(value: float) -> void:
	if not is_finite(value):
		return
	var next := clampf(value, 0.0, 1.0)
	if is_equal_approx(next, power_ratio):
		return
	power_ratio = next
	power_changed.emit(power_ratio)
	_refresh_state()


## Re-derive the condition from what the device and the ship say right now. The hub
## calls this when something outside the device changed the answer - the hull became a
## wreck, or a repair gave it a hull again - rather than writing `state` itself.
func refresh_state() -> void:
	_refresh_state()


## Ask the hub to put something on the bus in this device's own words. This is how a
## sensor says "contact" without the sensor ever knowing who is listening.
func publish(topic: String, data: Dictionary = {}) -> void:
	if systems != null and is_instance_valid(systems) and systems.has_method("publish"):
		systems.call("publish", resolved_id(), topic, data)


## Everything the hub publishes, delivered to every device - including the one that
## published it, which is why a device that does not want its own echo checks
## `event.component_id` first. Empty here on purpose: the base class has no opinion
## about topics, and a subclass that wants them overrides this rather than a signal
## connection it would have to undo in `_exit_tree()`.
func receive_event(_event: ShipSystemEvent) -> void:
	pass


## One line for the hub's report: id, state, grant and integrity. The numbers are the
## ones the state was derived from, which is what makes the line arguable.
func status_line() -> String:
	return "%-10s %-7s p=%.2f i=%.2f%s" % [resolved_id(),
		ShipSystemState.name_of(state), power_ratio, integrity,
		"" if enabled else " (off)"]


## The same information as `status_line()`, as data. A panel, a save file or a later
## research system reads this instead of reaching into the fields, so the device keeps
## one public shape even when its own mechanics grow.
func status() -> Dictionary:
	return {
		"id": resolved_id(),
		"title": display_name(),
		"enabled": enabled,
		"state": state,
		"state_name": ShipSystemState.name_of(state),
		"integrity": integrity,
		"efficiency": efficiency(),
		"power_ratio": power_ratio,
		"demand": nominal_power_draw if draws_power() else 0.0,
		"supply": supplied_power(),
		"available": is_operational(),
		"can_start": can_start(),
		"block_reason": start_block_reason(),
	}


func _refresh_state() -> void:
	var next := ShipSystemState.evaluate(enabled, integrity, power_ratio, settings(),
		_hull_alive())
	if next == state:
		return
	var previous := state
	state = next
	state_changed.emit(previous, state)


## Is the ship itself still a ship? Answered by the hub, and true for a device that has
## no hub: a fixture is not on a wreck. The lookup is by method name for the same reason
## `_request_start_energy()` uses one - this file must not import the hub's script.
func _hull_alive() -> bool:
	if systems == null or not is_instance_valid(systems) \
			or not systems.has_method("is_hull_destroyed"):
		return true
	return not bool(systems.call("is_hull_destroyed"))