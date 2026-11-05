extends Node
class_name ShipSystems

## The ship's internal architecture: one hub, four responsibilities, no globals.
##
## This node is a child of the hull (`Ship/Systems`) and it is the only thing the
## rest of the ship has to know about. It owns the three systems that answer for the
## hull's internals - `ShipEnergySystem`, `ShipHealthSystem`, `ShipDamageRouter` - and
## the registry of every device mounted on the ship. It also owns the two things that
## are genuinely cross-cutting and therefore belong to nobody else:
##
## - **the bus.** One `system_event` signal and one `receive_event()` call per device.
##   A device never holds a reference to another device, and a screen never reaches
##   into a device: everything is a `ShipSystemEvent`.
## - **the translation of the flight model's own signals.** `ShipController` already
##   reports a classified contact (`ship_collision_detected`) and a raw one
##   (`obstacle_hit`); this hub listens to the classified one and hands it to the
##   damage router. The controller is not edited for this, not subclassed, and does
##   not know the layer exists.
##
## Why a node, when the three systems themselves are `RefCounted`: a node is how this
## project injects dependencies (see `docs/architecture.md` - there are no autoloads,
## and every suite runs headless because of it). A component finds its hub by walking
## up the tree, so a device dropped into the scene is installed. A hub built as an
## autoload would make every suite depend on a global, and it would make two ships in
## one scene share a power budget.
##
## Why the hub does no per-frame work: every number this layer owns changes only when
## something happens - a device is mounted, a switch is thrown, a hit lands. The one
## exception is the energy reserve, and it gets its own child node (`ShipEnergyClock`)
## instead of a `_process` here, so the hub stays exactly as testable as it was. A
## `_process` on the hub would walk a handful of devices sixty times a second to
## conclude that nothing had changed. The test suite asserts the absence of one.
##
## What the layer deliberately does not do: it does not model fuel, heat, reactor wear,
## or delete a dead hull. As of stage 4.3 it does own the hull's pool and the cost of a
## collision; as of 4.5 the destruction latch also cuts the plant and puts every device
## OFFLINE. Destruction is still a signal and a latch, not a scene change, because what a
## wreck should do to the camera, the HUD and the run is a later decision.

## A device joined the ship. Emitted after it is configured, connected and on the bus,
## so a listener that reacts to this can already read a real state.
signal component_registered(component: ShipComponent)
## A device left the ship. Emitted after it is off the bus and out of the registry.
signal component_unregistered(component: ShipComponent)
## Any device's condition moved. The convenience signal a HUD wants; the full event
## with the same information arrives on `system_event`.
signal system_state_changed(component_id: String, previous: int, current: int)
## Every message on the ship's internal bus, in the order it happened.
signal system_event(event: ShipSystemEvent)
## The hull's own integrity moved, 0..1.
signal hull_integrity_changed(ratio: float)
## The hull's own condition moved - the three words, applied to the skin itself.
signal hull_state_changed(previous: int, current: int)
## The hull took damage: what was actually applied, what is left, the maximum and the
## caller's own source string. Emitted after the ledger is written, so a listener that
## reads `hull_integrity()` here sees the wound it was told about.
signal hull_damaged(amount: float, integrity: float, maximum: float, source: String)
## The hull fell to or below `critical_hull_ratio`. Once per crossing, not per hit.
signal hull_critical(ratio: float)
## The hull reached zero integrity. Once, and then no further damage is accepted.
signal hull_destroyed
## The reserve moved: its level 0..1, the charge and the tank it sits in. Emitted once
## per physics frame while the hull is drawing or regenerating, not on every allocation.
signal energy_changed(ratio: float, charge: float, capacity: float)
## The reserve crossed its low line. Once per crossing, so a listener may treat it as
## an alarm; `energy_changed` is the level to read afterwards.
signal energy_low(ratio: float)
## The reserve hit zero and the bus went dark. Devices are already at grant 0.
signal energy_depleted
## The reserve climbed back above the restart line and the bus is live again.
signal energy_restored
## A device asked to start and the reserve could not pay its switch-on cost. Nothing
## was spent and the device is still off.
signal activation_refused(component_id: String, cost: float, available: float)
## A device asked to start and was refused for a non-energy reason: `destroyed` (the
## hull is a wreck), `wrecked` (the device is out of integrity) or `unknown` (no such
## id). Nothing moved and nothing was spent.
signal activation_denied(component_id: String, reason: String)

## The tuning resource. Assigned in `Ship.tscn` from
## `assets/ship/systems_parameters.tres`; a hand-built hub gets the defaults, which
## are the shipping numbers.
@export var parameters: ShipSystemsParameters

## The three systems. Public because a panel, a test and the next sub-stage all read
## them directly - they are the layer's own nouns, not implementation details.
var energy: ShipEnergySystem
var health: ShipHealthSystem
var damage: ShipDamageRouter

## The clock that steps the reserve. A node of its own because this hub deliberately
## has no per-frame method (stage 4.1 asserts it): the clock ticks, the hub stays quiet.
var clock: ShipEnergyClock

## The registry, in registration order. A dictionary for the lookups and an array for
## the iteration, because both orders matter: a report prints in the order the devices
## were mounted, and a lookup must not care.
var _components := {}
var _order: Array[String] = []

## The hull this hub serves. Untyped on purpose: a test fixture may be any node that
## carries the ship's signals, and the hub only ever asks it for them.
var _ship: Node
var _hull_state: int = ShipSystemState.Value.NOMINAL
## Latches for the two alarms above. A hull that has been critical is not re-announced
## on every subsequent hit, and a wreck does not emit `hull_destroyed` twice.
var _hull_critical := false
var _hull_destroyed := false
var _dispatch_depth := 0
## Latched while one contact is being turned into a wound. A device that calls
## `report_impact()` from `receive_event()` would otherwise nest the whole path - event,
## hit, hull wound, device wound - on top of itself and charge the hull once per hop.
var _routing_impact := false


func _enter_tree() -> void:
	_ship = get_parent()
	_build(settings())
	_bind_ship()


func _exit_tree() -> void:
	_unbind_ship()


## Called every time the tuning resource is replaced: the three systems and every
## mounted device are re-pointed at it, and the allocation is recomputed. This is the
## one supported way to retune a live hull, which is why it exists at all.
func set_parameters(params: ShipSystemsParameters) -> void:
	parameters = params if params != null else ShipSystemsParameters.new()
	if energy == null:
		_build(parameters)
		return
	energy.set_parameters(parameters)
	health.set_parameters(parameters)
	damage.set_parameters(parameters)
	for component in components():
		component.configure(parameters)
	energy.allocate()
	_refresh_hull_state()
	_sync_hull_latches()
	_sync_bus()


func settings() -> ShipSystemsParameters:
	if parameters == null:
		parameters = ShipSystemsParameters.new()
	return parameters


## The hull this hub is mounted on, or null for a hub built outside a ship.
func ship() -> Node:
	return _ship


func _build(params: ShipSystemsParameters) -> void:
	energy = ShipEnergySystem.new(params)
	health = ShipHealthSystem.new(params)
	damage = ShipDamageRouter.new(params)
	damage.world = _ship_world()
	_hull_state = ShipSystemState.Value.NOMINAL
	_hull_critical = false
	_hull_destroyed = false
	energy.charge_changed.connect(_on_energy_charge_changed)
	energy.low_charge.connect(_on_energy_low)
	energy.depleted.connect(_on_energy_depleted)
	energy.restored.connect(_on_energy_restored)
	# One clock for the life of the hub. A rebuild (a retune, a re-entry into the tree)
	# re-points it at the new tank rather than growing a second ticking node.
	if clock == null or not is_instance_valid(clock):
		clock = ShipEnergyClock.new()
		clock.name = "EnergyClock"
		add_child(clock)
	clock.attach(energy)


## The ship's collision thresholds, if the hull has a `world` resource. Optional by
## design: the hub must work with a hull that has no world tuning at all.
func _ship_world() -> ShipWorldParameters:
	if _ship == null:
		return null
	return _ship.get("world") as ShipWorldParameters


## Listen to the flight model without touching it. The signal is looked up by name
## because `ShipController` is not imported here - the hub serves any hull that speaks
## the ship's own collision protocol, and a test fixture can therefore speak it too.
func _bind_ship() -> void:
	if _ship == null:
		return
	var callable := Callable(self, "_on_ship_collision")
	if _ship.has_signal("ship_collision_detected") \
			and not _ship.is_connected("ship_collision_detected", callable):
		_ship.connect("ship_collision_detected", callable)


func _unbind_ship() -> void:
	if _ship == null:
		return
	var callable := Callable(self, "_on_ship_collision")
	if _ship.is_connected("ship_collision_detected", callable):
		_ship.disconnect("ship_collision_detected", callable)


func _on_ship_collision(info: Dictionary) -> void:
	report_impact(info)


# -------------------------------------------------------------- the registry ---

## Put a device in the registry and on the bus. Called by `ShipComponent._ready()`
## through the ancestor lookup; public because a test, a save-game loader or a spawner
## may mount a device that is not in the tree yet.
##
## Re-registering the same node is a no-op that returns true; a *different* node
## claiming an id that is taken is refused with a warning, because two devices behind
## one id is a bug that would otherwise surface as a mysterious extra power draw.
func register_component(component: ShipComponent) -> bool:
	if component == null or not is_instance_valid(component):
		return false
	var id := component.resolved_id()
	if id.is_empty():
		push_warning("ShipSystems: refused a component with no id")
		return false
	var taken: ShipComponent = _components.get(id)
	if taken == component:
		return true
	if taken != null:
		push_warning("ShipSystems: id \"%s\" is already taken by %s" % [id, taken])
		return false
	# A hub that has not entered the tree yet has no systems to talk to; build them so
	# a loader that mounts a device first and adds the hull second does not crash.
	if energy == null:
		_build(settings())
	component.configure(settings())
	_components[id] = component
	if not _order.has(id):
		_order.append(id)
	_connect_component(component)
	component_registered.emit(component)
	energy.register(component)
	return true


func unregister_component(component: ShipComponent) -> void:
	if component == null:
		return
	var id := component.resolved_id()
	if _components.get(id) != component:
		return
	_disconnect_component(component)
	_components.erase(id)
	_order.erase(id)
	energy.unregister(component)
	component_unregistered.emit(component)


func component(id: String) -> ShipComponent:
	var found = _components.get(id)
	if found == null or not is_instance_valid(found):
		return null
	return found


func has_component(id: String) -> bool:
	return component(id) != null


## Every mounted device, in registration order. A fresh array: a caller may free a
## device while iterating without invalidating this hub's own bookkeeping.
func components() -> Array[ShipComponent]:
	var list: Array[ShipComponent] = []
	for id in _order:
		var found: ShipComponent = component(id)
		if found != null:
			list.append(found)
	return list


func component_ids() -> Array[String]:
	return _order.duplicate()


## The state of one device as data, or an empty dictionary for an unknown id. This is
## the read side of the control system: a panel, a save or a research device asks here
## instead of reaching into another device's fields.
func equipment_status(id: String) -> Dictionary:
	var target := component(id)
	return {} if target == null else target.status()


## Every mounted device's status, in registration order - the same shape a single
## `equipment_status()` returns. A fresh array of fresh dictionaries.
func equipment_statuses() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for target in components():
		out.append(target.status())
	return out


func count() -> int:
	return _components.size()


func _connect_component(component: ShipComponent) -> void:
	component.state_changed.connect(_on_component_state_changed.bind(component))
	component.power_changed.connect(_on_component_power_changed.bind(component))
	component.enabled_changed.connect(_on_component_enabled_changed.bind(component))


func _disconnect_component(component: ShipComponent) -> void:
	var state_callable: Callable = _on_component_state_changed.bind(component)
	var power_callable: Callable = _on_component_power_changed.bind(component)
	var enabled_callable: Callable = _on_component_enabled_changed.bind(component)
	if component.state_changed.is_connected(state_callable):
		component.state_changed.disconnect(state_callable)
	if component.power_changed.is_connected(power_callable):
		component.power_changed.disconnect(power_callable)
	if component.enabled_changed.is_connected(enabled_callable):
		component.enabled_changed.disconnect(enabled_callable)


func _on_component_state_changed(previous: int, current: int, component: ShipComponent) -> void:
	var id := component.resolved_id()
	system_state_changed.emit(id, previous, current)
	dispatch(ShipSystemEvent.state_changed(id, previous, current))
	# A device that has just gone offline is no longer drawing, and one that has just
	# come back is asking again. Re-sharing the budget here is what makes the two
	# facts true of the other devices in the same frame instead of in the next one.
	energy.allocate()


func _on_component_power_changed(ratio: float, component: ShipComponent) -> void:
	dispatch(ShipSystemEvent.power_changed(component.resolved_id(), ratio))


func _on_component_enabled_changed(enabled: bool, component: ShipComponent) -> void:
	dispatch(ShipSystemEvent.toggled(component.resolved_id(), enabled))
	energy.allocate()


# ------------------------------------------------------------- switches -------

## Throw a device's crew switch. Returns false when there is no such device, or when
## the ship refused to light it: the device is wrecked, the hull is destroyed, or the
## reserve could not pay the switch-on cost - a caller that got an id from a save file
## finds out instead of assuming.
##
## Switching one device never touches another: the freed appetite is shared out again
## on the next allocation, which is what makes "the sensor is off, the drill gets the
## power" true rather than merely plausible.
func set_enabled(id: String, value: bool) -> bool:
	var target := component(id)
	if target == null:
		return false
	target.set_enabled(value)
	return target.enabled == value


## Flip one device. Returns true when the switch moved, false when the id is unknown or
## the ship refused the start - a `true` after switching a lit device off means it is
## now off, which is why the answer is "did the flip happen", not "is it on".
func toggle_enabled(id: String) -> bool:
	var target := component(id)
	if target == null:
		return false
	var wanted := not target.enabled
	target.set_enabled(wanted)
	return target.enabled == wanted


## Every device on one switch - the "everything but life support" lever a bridge
## crew reaches for. Iterates a copy, because a device may react by mounting another.
func set_all_enabled(value: bool) -> void:
	for target in components():
		target.set_enabled(value)


func is_enabled(id: String) -> bool:
	var target := component(id)
	return target != null and target.enabled


# ---------------------------------------------------------------- condition ----

## Take integrity off one device. `source` is free text for the log - "impact",
## "arc", "fire" - and is never interpreted. Returns the amount actually applied.
func apply_damage(id: String, amount: float, source: String = "") -> float:
	var target := component(id)
	if target == null:
		return 0.0
	var applied := health.damage(target, amount)
	if applied > 0.0:
		dispatch(ShipSystemEvent.damaged(id, applied, target.integrity, source))
	return applied


func repair(id: String, amount: float, source: String = "") -> float:
	var target := component(id)
	if target == null:
		return 0.0
	var applied := health.repair(target, amount)
	if applied > 0.0:
		dispatch(ShipSystemEvent.repaired(id, applied, target.integrity, source))
	return applied


## The hull's skin takes the hit. Same clamping as a device, in the hull's own points,
## and the same three states: there is no fourth word for "the hull is at 40%".
##
## This is the only door damage comes through, whatever produced it - a collision, an
## arc, a scripted event - and `source` is free text for the log and for
## `damage_source_scale`. A wreck accepts nothing: once integrity is zero every call
## returns 0, so a rock grinding on a dead hull cannot keep emitting wounds.
func apply_hull_damage(amount: float, source: String = "") -> float:
	if _hull_destroyed:
		return 0.0
	var applied := health.damage_hull(amount * damage_scale_for(source))
	if applied <= 0.0:
		return 0.0
	hull_damaged.emit(applied, health.hull_integrity, health.hull_max(), source)
	hull_integrity_changed.emit(health.hull_ratio())
	dispatch(ShipSystemEvent.damaged("", applied, health.hull_ratio(), source))
	_refresh_hull_state()
	_note_hull_thresholds()
	return applied


func repair_hull(amount: float) -> float:
	var applied := health.repair_hull(amount)
	if applied <= 0.0:
		return 0.0
	# Repair is not part of this sub-stage, but the door already exists; if it is used,
	# the alarms have to follow the number back up or a repaired hull stays "destroyed".
	if health.hull_ratio() > 0.0:
		_hull_destroyed = false
	if health.hull_ratio() > settings().critical_hull_ratio:
		_hull_critical = false
	# The plant comes back with the hull, before anything is told about the integrity:
	# a listener that reacts to `hull_integrity_changed` must not see a live hull with a
	# dark bus, and every device's state is re-derived from the rule, not re-enabled.
	_sync_bus()
	hull_integrity_changed.emit(health.hull_ratio())
	dispatch(ShipSystemEvent.repaired("", applied, health.hull_ratio(), "repair"))
	_refresh_hull_state()
	return applied


## The hull's current points. `hull_ratio()` is the fraction the states use.
func hull_integrity() -> float:
	return health.hull_integrity


func hull_max_integrity() -> float:
	return health.hull_max()


## Extra multiplier a damage source carries, from `damage_source_scale`. Unknown
## sources cost exactly what the caller asked for, so adding a hazard never requires
## editing the damage system.
func damage_scale_for(source: String) -> float:
	var table: Dictionary = settings().damage_source_scale
	if not table.has(source):
		return 1.0
	var value := float(table[source])
	if not is_finite(value) or value < 0.0:
		return 1.0
	return value


func is_hull_critical() -> bool:
	return _hull_critical


func is_hull_destroyed() -> bool:
	return _hull_destroyed or health.hull_is_lost()


func hull_ratio() -> float:
	return health.hull_ratio()


func hull_state() -> int:
	return _hull_state


## The worst condition of anything on the ship: the hull, or any mounted device.
## "How is the ship?" answered with one of the three words, which is the only shape a
## HUD or a voice line can use.
func state() -> int:
	var worst := _hull_state
	for target in components():
		worst = ShipSystemState.worst(worst, target.state)
	return worst


func state_name() -> String:
	return ShipSystemState.name_of(state())


func _refresh_hull_state() -> void:
	var next := health.hull_state()
	if next == _hull_state:
		return
	var previous := _hull_state
	_hull_state = next
	hull_state_changed.emit(previous, next)
	dispatch(ShipSystemEvent.state_changed("", previous, next))


## The two hull alarms, one crossing each. Destroyed outranks critical: a hit that
## takes the hull straight from whole to zero must not announce "critical" first.
##
## A destroyed hull is also the moment the ship stops working: the plant is cut first,
## which zeroes every grant through the ordinary allocation, and then every device is
## asked to re-derive its condition so one with no appetite cannot keep reporting
## NOMINAL on a wreck. Both happen before the signal, so a listener woken by
## `hull_destroyed` already sees a ship that is off.
func _note_hull_thresholds() -> void:
	var ratio := hull_ratio()
	if not _hull_destroyed and ratio <= 0.0:
		_hull_destroyed = true
		_sync_bus()
		hull_destroyed.emit()
		dispatch(ShipSystemEvent.custom("", "hull_destroyed", {
			"maximum": hull_max_integrity(),
		}))
		return
	if not _hull_critical and ratio <= settings().critical_hull_ratio:
		_hull_critical = true
		hull_critical.emit(ratio)
		dispatch(ShipSystemEvent.custom("", "hull_critical", {
			"ratio": ratio, "integrity": hull_integrity(),
			"maximum": hull_max_integrity(),
		}))


## Re-read the alarms after a retune or a repair. No signals here: this is the state
## catching up with a number somebody else moved, not a new event.
func _sync_hull_latches() -> void:
	var ratio := hull_ratio()
	if ratio > settings().critical_hull_ratio:
		_hull_critical = false
	if ratio > 0.0:
		_hull_destroyed = false


## Keep the plant and the devices in step with the hull's latch. One call instead of a
## second copy of the rule in every caller: a hull that is not a wreck has a live bus,
## a wreck has none, and every device's condition is derived again from that answer.
## `set_bus_online()` is a no-op unless the answer actually moved, so this is cheap.
func _sync_bus() -> void:
	energy.set_bus_online(not is_hull_destroyed())
	_refresh_component_states()


## Ask every device to re-derive its own condition after a change it did not make.
## Nothing is written by the hub: `refresh_state()` is the component's own rule, run
## once more, and a device whose answer did not move emits nothing.
func _refresh_component_states() -> void:
	for target in components():
		target.refresh_state()


# -------------------------------------------------------------------- power ----

## Register an auxiliary source (a wing, a battery, a tapped anomaly), in power units.
func add_power_source(id: String, units: float) -> void:
	energy.add_source(id, units)


func remove_power_source(id: String) -> void:
	energy.remove_source(id)


func power_output() -> float:
	return energy.output()


func power_demand() -> float:
	return energy.demand()


func power_granted() -> float:
	return energy.granted()


func is_brownout() -> bool:
	return energy.is_starved()


# ------------------------------------------------------------------- energy -----

## The reserve level, 0..1. A hull with no reserve reads 1.0.
func energy_ratio() -> float:
	return energy.charge_ratio()


func energy_charge() -> float:
	return energy.charge()


func energy_capacity() -> float:
	return energy.capacity()


func is_energy_low() -> bool:
	return energy.is_low()


func is_energy_depleted() -> bool:
	return energy.is_depleted()


## Put energy back - a dock, a fuel cell, a scenario grant. Returns what fit.
func add_energy(amount: float) -> float:
	return energy.add_charge(amount)


## Force the level, clamped to the tank. For a save file, a scenario or a test.
func set_energy(charge: float) -> void:
	energy.set_charge(charge)


## Can this device be lit right now, without spending anything? A UI button may ask
## every frame; the answer is a pure check. Two questions in one: is the device allowed
## to start at all (hull alive, device not wrecked), and can the reserve pay the surge.
## `cost` below zero means "ask the device".
func can_activate(target, cost := -1.0) -> bool:
	var blocked := activation_block_reason(target)
	if not blocked.is_empty():
		return false
	var device := _resolve_component(target)
	if device != null and device.enabled:
		return true
	return energy.can_afford(_activation_cost(target, cost))


## Why this device cannot be lit, in one word, or "" when it can: `destroyed` (the
## hull is at zero), `wrecked` (the device is at or below its offline line), `unknown`
## (no such id). Energy is not part of the answer - that is `can_activate()`.
func activation_block_reason(target) -> String:
	var device := _resolve_component(target)
	if device == null:
		if target is String or target is StringName:
			return "unknown"
		return ""
	if is_hull_destroyed():
		return "destroyed"
	return device.start_block_reason()


## Try to light a device and pay its switch-on cost, atomically. Returns false when the
## device may not start or the reserve is short; nothing is spent, and the refusal goes
## out as a signal and as an event, so a panel and a log can both say why the switch did
## not move.
##
## The component calls this from `set_enabled()`, which is why a device mounted
## anywhere on the ship gets the check without knowing the energy system exists.
func request_activation(target, cost := -1.0) -> bool:
	var device := _resolve_component(target)
	var id := _target_id(target)
	var blocked := activation_block_reason(target)
	if not blocked.is_empty():
		activation_denied.emit(id, blocked)
		dispatch(ShipSystemEvent.custom(id, "activation_denied", {"reason": blocked}))
		return false
	if device != null and device.enabled:
		return true
	var price := _activation_cost(target, cost)
	if price <= 0.0:
		return true
	if energy.try_spend(price):
		return true
	activation_refused.emit(id, price, energy.charge())
	dispatch(ShipSystemEvent.custom(id, "activation_refused", {
		"cost": price, "charge": energy.charge(), "capacity": energy.capacity(),
	}))
	return false


## A one-off draw by an arbitrary device action - a scan pulse, a drill stroke. Same
## atomic rule as activation: it either costs exactly `amount` once or nothing at all.
##
## A wreck does not spend the ship's reserve and neither does a wrecked device: the same
## two refusals `request_activation()` makes, at the same door, so an action cannot be
## paid for by hardware that is already gone. The refusal goes out as `energy_refused`
## with a `reason`, which keeps the event shape the old refusal already had.
func spend_energy(component_id: String, amount: float) -> bool:
	var target := component(component_id)
	var blocked := ""
	if is_hull_destroyed():
		blocked = "destroyed"
	elif target != null and not target.can_start():
		blocked = "wrecked"
	if not blocked.is_empty():
		dispatch(ShipSystemEvent.custom(component_id, "energy_refused", {
			"cost": amount, "charge": energy.charge(), "capacity": energy.capacity(),
			"reason": blocked,
		}))
		return false
	if energy.try_spend(amount):
		return true
	dispatch(ShipSystemEvent.custom(component_id, "energy_refused", {
		"cost": amount, "charge": energy.charge(), "capacity": energy.capacity(),
	}))
	return false


func _resolve_component(target) -> ShipComponent:
	if target is ShipComponent:
		var device: ShipComponent = target
		return device
	if target is String or target is StringName:
		return component(String(target))
	return null


func _target_id(target) -> String:
	var device := _resolve_component(target)
	if device != null:
		return device.resolved_id()
	if target is String or target is StringName:
		return String(target)
	return ""


func _activation_cost(target, cost: float) -> float:
	if cost >= 0.0:
		return cost
	var device := _resolve_component(target)
	if device == null:
		return 0.0
	return device.activation_energy_cost


func _on_energy_charge_changed(charge: float, capacity: float) -> void:
	var ratio := 1.0 if capacity <= 0.0 else clampf(charge / capacity, 0.0, 1.0)
	energy_changed.emit(ratio, charge, capacity)


func _on_energy_low(ratio: float) -> void:
	energy_low.emit(ratio)
	dispatch(ShipSystemEvent.energy_low(ratio, energy.charge(), energy.capacity()))


func _on_energy_depleted() -> void:
	energy_depleted.emit()
	dispatch(ShipSystemEvent.energy_depleted(energy.charge(), energy.capacity()))


func _on_energy_restored() -> void:
	energy_restored.emit()
	dispatch(ShipSystemEvent.energy_restored(energy.charge_ratio(),
		energy.charge(), energy.capacity()))


# ---------------------------------------------------------------------- bus ----

## Put something on the bus in a device's own words. The hub adds no interpretation:
## the topic is the device's, and every listener sees the same event.
func publish(component_id: String, topic: String, data: Dictionary = {}) -> void:
	dispatch(ShipSystemEvent.equipment(component_id, topic, data))


## Broadcast an event to every listener, then to every mounted device. The only entry
## point: a system that wants to say something builds an event and calls this.
##
## The depth guard is not decoration. A device that publishes from `receive_event()`
## is a loop, and a loop on a bus with no stop condition takes the whole game down on
## the first frame it happens. Eight hops is far more than any honest chain needs.
func dispatch(event: ShipSystemEvent) -> void:
	if event == null:
		return
	if _dispatch_depth >= 8:
		push_warning("ShipSystems: event chain dropped at %s" % event.describe())
		return
	_dispatch_depth += 1
	system_event.emit(event)
	for target in components():
		target.receive_event(event)
	_dispatch_depth -= 1


## The bridge from the flight model. Public so an external system - a scripted hazard,
## a test, a replay - can hand the ship an impact without pretending to be a body.
##
## The event goes out first and the wound lands second, so a listener that hears "the
## hull was hit" and then reads `hull_ratio()` sees the number the hit produced. With
## `impact_damage_enabled` off the event still goes out and nothing is spent - the
## switch is for a scene that wants the contact without the consequence.
func report_impact(info: Dictionary) -> ShipSystemEvent:
	# The bus is the one place a device can start an impact from inside a handler. The
	# dispatch depth guard would stop the event storm at eight hops, but every hop would
	# already have applied its own hull wound - so the impact itself refuses to nest.
	if _routing_impact:
		print("ShipSystems: nested impact report ignored")
		return null
	_routing_impact = true
	damage.world = _ship_world()
	var event := damage.route_impact(info)
	var hit := hit_component(info)
	if hit != null:
		event.data["hit_component"] = hit.resolved_id()
		event.data["hit_distance"] = _hit_distance(hit, info)
		event.data["hit_is_estimate"] = true
	var severity := String(event.data.get("severity", "LIGHT"))
	var cost := damage.damage_for(severity) if settings().impact_damage_enabled else 0.0
	event.data["hull_damage"] = cost
	dispatch(event)
	if cost > 0.0:
		var applied := apply_hull_damage(cost, "impact")
		if hit != null:
			_wound_hit_component(hit, applied)
	_routing_impact = false
	return event


## The mounted device nearest the impact's estimated contact point, or null when no
## device is close enough. The flight model's point is an estimate (the nearest surface
## along the centre-to-centre line), so this is a coarse "which compartment" answer, not
## a manifold query: a device is placed by the nearest Node2D above it in the tree, and
## a device with no 2D ancestor cannot be located and is never chosen.
##
## Public because a panel, a test or a scripted hazard may want the same answer without
## going through a whole impact.
func hit_component(info: Dictionary) -> ShipComponent:
	var radius := settings().component_hit_radius
	if radius <= 0.0:
		return null
	var point: Vector2 = info.get("contact_point", Vector2.ZERO)
	var best: ShipComponent = null
	var best_distance := radius
	for component in components():
		if component == null or not is_instance_valid(component):
			continue
		var where: Variant = _component_position(component)
		if where == null:
			continue
		var place: Vector2 = where
		var distance := place.distance_to(point)
		if distance <= best_distance and (best == null or distance < best_distance):
			best = component
			best_distance = distance
	return best


## The world position a device occupies: the nearest Node2D at or above it, stopping at
## the hub (the ship's own body is not a device position). Null for a plain `Node`
## device, which is honest - a component with no place in space cannot be hit in one.
func _component_position(component: ShipComponent) -> Variant:
	var node := component as Node
	while node != null and node != self:
		if node is Node2D:
			return (node as Node2D).global_position
		node = node.get_parent()
	return null


func _hit_distance(component: ShipComponent, info: Dictionary) -> float:
	var where: Variant = _component_position(component)
	if where == null:
		return -1.0
	var place: Vector2 = where
	return place.distance_to(info.get("contact_point", Vector2.ZERO))


## A device that took the hit loses part of itself, scaled from the hull's loss. The
## same one-off rule as every other wound: `apply_damage()` clamps, the device derives
## its own state, and the bus hears one `DAMAGE_TAKEN` with the device's id.
func _wound_hit_component(component: ShipComponent, hull_applied: float) -> void:
	var scale := settings().impact_device_damage_scale
	if scale <= 0.0 or hull_applied <= 0.0:
		return
	var fraction := hull_applied / maxf(hull_max_integrity(), 0.0001)
	apply_damage(component.resolved_id(), fraction * scale, "impact")


# ------------------------------------------------------------------- report ----

## The lines the debug panel prints. Built here rather than in the overlay so a
## headless run can read the layer's state without a renderer - the same rule
## `EngineController.report()` and `BoostSystem.report()` follow.
func report() -> Array[String]:
	var devices := components()
	var lines: Array[String] = ["systems    %d mounted  %s" % [devices.size(), state_name()]]
	lines.append_array(energy.report())
	lines.append_array(health.report())
	lines.append("devices    %3d%% mean integrity" % int(roundf(
		health.average_ratio(devices) * 100.0)))
	lines.append_array(damage.report())
	for target in devices:
		lines.append("device     " + target.status_line())
	return lines