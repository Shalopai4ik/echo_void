extends ShipComponent
class_name ShipScanner

## A survey sensor: one sweep, one disc of space, one list of contacts.
##
## This is a `ShipComponent`, so it is mounted the way every device is - a node under
## `Ship/Systems` and nothing else. It draws power through the bus, its condition and
## its grant arrive through the same `set_power_ratio()` seam as every other device,
## and `ShipSystems.spend_energy()` - written for exactly this - pays for a pulse. No
## edit to the hub, the energy system or the health system was needed to add it.
##
## What a sweep is:
##
## 1. it asks the world for the objects inside a disc once (`objects_near()`), and
##    raises any phantom signatures from the world's hash. That is the whole cost,
##    and it is paid once per sweep rather than once per frame;
## 2. it decides, per object, whether its return is strong enough to be reported and
##    whether it is strong enough to be named. The numbers come from
##    `ScanSignature`, so this file has no list of kinds in it;
## 3. it hands the contacts out one at a time across `sweep_seconds`, then reports
##    the whole list. A scan is a sweep the pilot watches, not an instant answer.
##
## Two doors lead out, because two different things will listen. Godot signals for
## whoever holds the device (a panel, a research stage, a test), and `publish()` for
## the ship's own bus, which is how a system that has never heard of the scanner can
## still react to its results. Both carry the same dictionaries.
##
## What it deliberately does not do: no interface, no experience, no discovery log,
## no marker on the HUD. It answers "what is out there" and stops. It also holds no
## reference to a `Node` in a contact - an object can be recycled the moment a chunk
## is unloaded, so a contact carries the object's stable `chunk:item` id and the
## position it had at the time of the sweep.

const HASH := preload("res://scripts/space_background/space_hash.gd")
const PROFILE := preload("res://scripts/scan/scanner_profile.gd")
## The group a world manager joins to be scannable. Looked up by group rather than
## by path, so a ship in a test scene finds a test world and a ship in the game
## finds the field - the same injection rule the rest of this layer follows.
const WORLD_GROUP := "world_field"
## A sweep may not be shorter than this, whatever the profile says: a zero-length
## sweep would still emit a start and a finish in the same frame.
const MIN_SWEEP_SECONDS := 0.1

## A sweep started: its radius and how long it will take.
signal scan_started(range_px: float, seconds: float)
## One contact, as it arrives. Emitted during the sweep, nearest first.
signal contact_found(contact: Dictionary)
## The sweep finished. Carries every contact, the same dictionaries `contact_found`
## delivered, and the same list `last_contacts()` now returns.
signal scan_completed(contacts: Array)
## The sweep was cut short - the switch went off, the grant went to zero, the hull
## became a wreck. `last_contacts()` then holds the contacts that had already
## arrived and `progress()` reads zero.
signal scan_cancelled(reason: String)
## The order was refused and nothing was spent: `busy` (a sweep is running),
## `offline` (the sensor could not be lit), `unpowered` (the bus starved it) or
## `energy` (the reserve could not pay for the pulse).
signal scan_refused(reason: String)

## What this device can find and what a sweep costs. Replaced at run time by an
## upgrade; never edited in place per ship clone.
@export var profile: ScannerProfile
## Multiplies the profile's radius. The seam a future upgrade turns.
@export_range(0.1, 8.0, 0.05) var range_multiplier := 1.0
## Multiplies every measured return, which is what makes a weak, distant signature
## nameable. The seam a future upgrade turns.
@export_range(0.1, 8.0, 0.05) var sensitivity := 1.0
## Ordering a sweep lights the sensor if it is switched off. One command, one key;
## a crew that wants the device cold can switch it off again, and nothing is spent
## on a cold sensor because a sweep still has to be ordered.
@export var auto_start := true

## The sweep in flight. Public reads, private writes: `is_scanning()`,
## `progress()`, `contacts()` and `last_contacts()` are the read side.
var _scanning := false
var _elapsed := 0.0
var _sweep_seconds := 0.0
var _range := 0.0
var _origin := Vector2.ZERO
## Every contact this sweep accepted, nearest first. Revealed one at a time.
var _contacts: Array = []
var _revealed := 0
## The picture the last finished sweep took. A copy, because a panel may hold it
## while the next sweep is already running.
var _last: Array = []
var _refuse_reason := ""

## A world manager handed in by a scene or a test. Null means "find it by group".
var world_override: Node
var _found_world: Node


func _ready() -> void:
	super()
	# The base class ships with no per-frame method on purpose. This device needs one
	# only while a sweep is in flight, and turns it off again the moment it is not.
	set_physics_process(false)
	if profile == null:
		profile = PROFILE.new()
	state_changed.connect(_on_state_changed)
	enabled_changed.connect(_on_enabled_changed)


# ----------------------------------------------------------------- the command ---

## Order a sweep. Returns false when the order was refused, and `refuse_reason()`
## says which of the four reasons it was; nothing is spent on a refusal.
func start_scan() -> bool:
	_refuse_reason = ""
	if _scanning:
		return _refuse("busy")
	if profile == null:
		profile = PROFILE.new()
	if not _light_sensor():
		return _refuse("offline")
	if not is_operational():
		return _refuse("unpowered")
	if not _pay_for_sweep():
		return _refuse("energy")
	_origin = _hull_position()
	_range = range_now()
	_sweep_seconds = sweep_seconds_now()
	_contacts = _collect(_origin, _range)
	_revealed = 0
	_elapsed = 0.0
	_scanning = true
	set_physics_process(true)
	scan_started.emit(_range, _sweep_seconds)
	publish("scan_started", {"range": _range, "seconds": _sweep_seconds})
	return true


## Cut a sweep short. Nothing is refunded - the pulse was already paid for, and the
## contacts that had arrived stay in `last_contacts()`.
func cancel_scan(reason := "aborted") -> void:
	if not _scanning:
		return
	_scanning = false
	set_physics_process(false)
	_last = _contacts.slice(0, _revealed).duplicate(true)
	_contacts = []
	_revealed = 0
	scan_cancelled.emit(reason)
	publish("scan_cancelled", {"reason": reason, "count": _last.size()})


func is_scanning() -> bool:
	return _scanning


## How far through the sweep, 0..1. Reads 0 when nothing is running.
func progress() -> float:
	if not _scanning or _sweep_seconds <= 0.0:
		return 0.0
	return clampf(_elapsed / _sweep_seconds, 0.0, 1.0)


## The contacts that have arrived so far in the running sweep.
func contacts() -> Array:
	return _contacts.slice(0, _revealed).duplicate(true)


## The picture the last sweep took - the whole list if it finished, the revealed
## part of it if it was cancelled. Never null, so a panel can print it blind.
func last_contacts() -> Array:
	return _last.duplicate(true)


## Why the last order was refused, or "" when it was not.
func refuse_reason() -> String:
	return _refuse_reason


## The radius this hull would sweep right now, after upgrades and damage.
##
## Damage shortens the sweep because the dish is partly gone, not because the sensor
## happens to be switched off: a cold device reads its full range, so a panel can
## show what the hull *could* do before the pilot commits a pulse to it.
func range_now() -> float:
	if profile == null:
		return 0.0
	return maxf(profile.range_px * maxf(range_multiplier, 0.0) * _health_scale(0.35, 1.0), 0.0)


## How long the next sweep would take, after upgrades and damage. A hurt dish takes
## longer to integrate the same picture, which is the other half of what damage means
## to a sensor.
func sweep_seconds_now() -> float:
	if profile == null:
		return MIN_SWEEP_SECONDS
	return maxf(profile.sweep_seconds / _health_scale(0.5, 1.0), MIN_SWEEP_SECONDS)


## Energy a sweep costs right now, in `ShipSystemsParameters` power units.
func sweep_cost_now() -> float:
	return maxf(profile.sweep_energy_cost, 0.0) if profile != null else 0.0


## The seam an upgrade uses: a better dish is a multiplier, not a rewritten device.
func set_range_multiplier(value: float) -> void:
	range_multiplier = clampf(value, 0.1, 8.0)


## The other half of that seam: a better receiver names weaker returns.
func set_sensitivity(value: float) -> void:
	sensitivity = clampf(value, 0.1, 8.0)


## Swap the vocabulary wholesale - a better sensor that finds kinds this one cannot.
func set_profile(value: ScannerProfile) -> void:
	profile = value if value != null else PROFILE.new()


## A world manager handed in by a scene or a test. Null restores the group lookup.
func set_world(node: Node) -> void:
	world_override = node
	_found_world = null


## The world that answers `objects_near()`, or null in a scene that has none. Found
## through the tree, never imported: this file must not depend on the field's script.
func world() -> Node:
	if world_override != null and is_instance_valid(world_override):
		return world_override
	if not is_inside_tree():
		return null
	if _found_world != null and is_instance_valid(_found_world) and _found_world.is_inside_tree():
		return _found_world
	_found_world = get_tree().get_first_node_in_group(WORLD_GROUP)
	return _found_world


# ------------------------------------------------------------------- the sweep ---

func _physics_process(delta: float) -> void:
	if not _scanning:
		set_physics_process(false)
		return
	if not enabled:
		cancel_scan("switched_off")
		return
	if not is_operational():
		cancel_scan("unpowered")
		return
	_elapsed = minf(_elapsed + maxf(delta, 0.0), _sweep_seconds)
	# Contacts are spaced across the sweep by index rather than by a timer, so a
	# long sweep and a short one hand the same picture out in the same order, and a
	# frame that ran long cannot skip one.
	var total := _contacts.size()
	if total > 0:
		var due := int(floor(_elapsed / _sweep_seconds * float(total) + 0.000001))
		while _revealed < due and _revealed < total:
			_reveal_one()
	if _elapsed >= _sweep_seconds:
		_finish()


func _reveal_one() -> void:
	var contact: Dictionary = _contacts[_revealed]
	_revealed += 1
	contact_found.emit(contact.duplicate(true))


func _finish() -> void:
	var total := _contacts.size()
	while _revealed < total:
		_reveal_one()
	_scanning = false
	set_physics_process(false)
	_last = _contacts.duplicate(true)
	_contacts = []
	_revealed = 0
	scan_completed.emit(_last.duplicate(true))
	publish("scan_completed", {
		"range": _range,
		"seconds": _sweep_seconds,
		"count": _last.size(),
		"contacts": _last,
	})


# ---------------------------------------------------------------- collecting ---

## The contacts one sweep accepts, nearest first. The world does the walking - it
## owns the chunk grid - and everything this file does per candidate is arithmetic
## on numbers it already has.
func _collect(origin: Vector2, radius: float) -> Array:
	var out: Array = []
	var source := world()
	if source != null and source.has_method("objects_near"):
		var raw: Array = source.call("objects_near", origin, radius, _candidate_limit())
		for node in raw:
			if node == null or not is_instance_valid(node):
				continue
			var contact := _read_object(node, origin, radius)
			if not contact.is_empty():
				out.append(contact)
	for signature in profile.phantoms():
		_raise_phantoms(signature, origin, radius, out)
	out.sort_custom(_nearest_first)
	if out.size() > profile.max_contacts:
		out.resize(profile.max_contacts)
	return out


func _candidate_limit() -> int:
	return maxi(profile.max_contacts, 1) * maxi(profile.candidate_factor, 1)


## One world object, read through its own interface and the profile. An empty
## dictionary means "not a contact": too far, too faint, or not a thing this profile
## is meant to find.
func _read_object(node: Node, origin: Vector2, radius: float) -> Dictionary:
	var at := origin
	if node is Node2D:
		at = (node as Node2D).global_position
	var distance := at.distance_to(origin)
	if distance > radius:
		return {}
	var population := String(node.get_meta("population", ""))
	var groups: Array = node.get_groups()
	var object_kind := WorldObjects.kind_of(node)
	var signature := profile.signature_for(population, groups, object_kind)
	if signature == null:
		return {}
	var strength := _measure(signature, distance, radius)
	if not signature.detects(strength):
		return {}
	return _contact(node, signature, at, distance, strength, origin, population,
		signature.identifies(strength))


## A contact in the one shape every listener gets. `title` and `info` are the two
## fields that carry what the pilot is allowed to know, and both stay empty until
## the return is strong enough to name the thing.
func _contact(node: Node, signature: ScanSignature, at: Vector2, distance: float,
		strength: float, origin: Vector2, population: String,
		identified: bool) -> Dictionary:
	var title := ""
	var info := {}
	if identified:
		title = _title_of(node, signature)
		info = _revealed_info(node, signature)
	return {
		"id": _stable_id(node),
		"source": "object",
		"kind": signature.kind if identified else signature.uncertain_kind,
		"signature": signature.id,
		"identified": identified,
		"title": title,
		"position": at,
		"distance": distance,
		"bearing": (at - origin).angle(),
		"strength": strength,
		"population": population,
		"info": info,
		"at": ShipSystemEvent.now(),
	}


## A signal with no object behind it. Rolled over a lattice with the world's own
## hash, so the same cell raises the same anomaly on every sweep and on every visit;
## the contact's id is the cell, which is what a research stage will need in order to
## attach content to it later.
func _raise_phantoms(signature: ScanSignature, origin: Vector2, radius: float,
		out: Array) -> void:
	# A profile may ask for a tiny lattice; one sweep must still walk a bounded
	# number of cells, so the cell never falls below a sixteenth of the range.
	var cell := maxf(maxf(signature.phantom_cell, 16.0), radius / 16.0)
	var seed := _world_seed(signature)
	var lo := Vector2i(int(floor((origin.x - radius) / cell)),
		int(floor((origin.y - radius) / cell)))
	var hi := Vector2i(int(floor((origin.x + radius) / cell)),
		int(floor((origin.y + radius) / cell)))
	for gy in range(lo.y, hi.y + 1):
		for gx in range(lo.x, hi.x + 1):
			if HASH.hashf(gx, gy, signature.phantom_salt, seed) >= signature.phantom_chance:
				continue
			var at := Vector2((float(gx) + 0.5) * cell, (float(gy) + 0.5) * cell)
			var distance := at.distance_to(origin)
			if distance > radius:
				continue
			var strength := _measure(signature, distance, radius)
			if not signature.detects(strength):
				continue
			var identified := signature.identifies(strength)
			out.append({
				"id": "sig:%d,%d" % [gx, gy],
				"source": "signal",
				"kind": signature.kind if identified else signature.uncertain_kind,
				"signature": signature.id,
				"identified": identified,
				"title": _title_of(null, signature) if identified else "",
				"position": at,
				"distance": distance,
				"bearing": (at - origin).angle(),
				"strength": strength,
				"population": "",
				"info": {},
				"at": ShipSystemEvent.now(),
			})


## How strong this signature's return is at this distance. Linear falloff raised to
## a soft power: a contact at half range still reads as itself, and only the rim of
## the disc is a whisper. Sensitivity and condition multiply in, which is the whole
## difference between a good dish and a damaged one.
func _measure(signature: ScanSignature, distance: float, radius: float) -> float:
	if signature == null or radius <= 0.0:
		return 0.0
	var reach := clampf(1.0 - distance / radius, 0.0, 1.0)
	if reach <= 0.0:
		return 0.0
	return clampf(signature.strength * pow(reach, 0.85) * maxf(sensitivity, 0.0)
		* _health_scale(0.45, 1.0), 0.0, 1.0)


## The identity of a world object across a chunk unload and a rebuild: the chunk it
## was planned into and the `cell:slot` the field gave it. Falls back to the instance
## id for an object the field did not place, which is honest - that object has no
## stable identity to offer.
func _stable_id(node: Node) -> String:
	var chunk_id := String(node.get_meta("chunk_id", ""))
	var item_id := String(node.get_meta("item_id", ""))
	if not chunk_id.is_empty() and not item_id.is_empty():
		return "%s:%s" % [chunk_id, item_id]
	return "obj:%d" % node.get_instance_id()


func _title_of(node: Node, signature: ScanSignature) -> String:
	if not signature.title.is_empty():
		return signature.title
	if node != null and WorldObjects.supports_info(node):
		var given: Dictionary = node.world_object_info()
		var own := String(given.get("title", ""))
		if not own.is_empty():
			return own
	return signature.fallback_title()


## The object's own numbers, filtered through the signature. A survey at range
## learns a size; it does not learn what is inside a wreck.
func _revealed_info(node: Node, signature: ScanSignature) -> Dictionary:
	var out := {}
	if signature.reveal_keys.is_empty() or not WorldObjects.supports_info(node):
		return out
	var given: Dictionary = node.world_object_info()
	for key in signature.reveal_keys:
		if given.has(key):
			out[key] = given[key]
	return out


func _nearest_first(a: Dictionary, b: Dictionary) -> bool:
	return float(a["distance"]) < float(b["distance"])


# ------------------------------------------------------------------- plumbing ---

## Light the sensor if the order came in for a cold device. The switch is still the
## base class's: a wreck or a dry reserve refuses here exactly as it would there.
func _light_sensor() -> bool:
	if enabled:
		return true
	if not auto_start:
		return false
	set_enabled(true)
	return enabled


## Pay for the pulse through the hub, atomically. A device mounted outside a ship
## has no reserve to draw on and, like every other energy seam in this layer, is
## allowed to work - a fixture is not a hull.
func _pay_for_sweep() -> bool:
	var cost := sweep_cost_now()
	if cost <= 0.0:
		return true
	if systems != null and is_instance_valid(systems) and systems.has_method("spend_energy"):
		return bool(systems.call("spend_energy", resolved_id(), cost))
	return true


## Where the sweep is taken from: the hull's position, found by walking up to the
## nearest `Node2D`. This file never names `ShipController`.
func _hull_position() -> Vector2:
	var node := get_parent()
	while node != null:
		if node is Node2D:
			return (node as Node2D).global_position
		node = node.get_parent()
	return Vector2.ZERO


## How much of the dish is still there, as a multiplier between `floor_at` and
## `ceiling`. Read from `integrity` rather than from `efficiency()` on purpose: a
## sensor that is merely switched off is not a damaged sensor, and a panel has to be
## able to show its range before the pilot lights it. A wreck is never measured here,
## because the sweep refuses before a number matters.
func _health_scale(floor_at: float, ceiling: float) -> float:
	return lerpf(floor_at, ceiling, clampf(integrity, 0.0, 1.0))


## The world's own seed, so a phantom does not move when the pilot flies back.
func _world_seed(signature: ScanSignature) -> int:
	var source := world()
	if source != null and source.has_method("get_seed"):
		return int(source.call("get_seed"))
	return signature.fallback_seed


func _refuse(reason: String) -> bool:
	_refuse_reason = reason
	scan_refused.emit(reason)
	return false


func _on_state_changed(_previous: int, current: int) -> void:
	# A switch that goes off changes the derived state before it raises
	# `enabled_changed`, so the reason has to be read from the switch here as well -
	# otherwise every deliberate switch-off would be reported as a brownout.
	if not _scanning or ShipSystemState.is_operational(current):
		return
	cancel_scan("unpowered" if enabled else "switched_off")


func _on_enabled_changed(value: bool) -> void:
	if _scanning and not value:
		cancel_scan("switched_off")


## The player's command. `R` is already the scanner key the HUD listens to, and this
## device answers the same one: the glass and the contact list are one verb to the
## pilot. Ignored while the game is paused, because a sweep is a game event.
func _unhandled_input(event: InputEvent) -> void:
	if not get_tree().paused and event.is_action_pressed("scan"):
		start_scan()


## The base class's status plus this device's own numbers, so a panel and a test
## read a scanner through the same `equipment_status()` they read anything else.
func status() -> Dictionary:
	var out := super()
	out["scanning"] = _scanning
	out["scan_progress"] = progress()
	out["scan_range"] = range_now()
	out["scan_seconds"] = sweep_seconds_now()
	out["scan_cost"] = sweep_cost_now()
	out["scan_contacts"] = _last.size()
	out["scan_last_refusal"] = _refuse_reason
	return out