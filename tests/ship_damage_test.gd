extends SceneTree

## Sub-stage 4.3 verification: the hull's pool and what a collision costs it.
## Run: godot --headless --path . --script tests/ship_damage_test.gd
##
## The layer already owned a ratio, a damage router and a collision bridge. This suite
## holds what the damage stage added to them:
##
## 1. boot: a full hull with a current and a maximum value, no alarms;
## 2. a retune to a 100-point pool keeps the hull's condition;
## 3. direct damage: the ledger moves, the signals and the event fire, nothing physical
##    moves with them;
## 4. per-source multipliers, including bad entries that are ignored;
## 5. invalid damage (zero, negative, NaN, infinity) is refused whole;
## 6. the critical alarm fires once per crossing;
## 7. destruction: zero, one signal, no negative pool, no further wounds;
## 8. per-device hit location: the nearest placed device is named and takes its share,
##    a device outside the radius is untouched, and both the radius and the share can be
##    turned off;
## 9. a real rock flown into: one contact, one wound, one damage event, and the hull is
##    not thrown faster than it arrived;
## 10. report and teardown.
##
## Physics is deliberately left alone throughout: the suite asserts the hull's velocity
## and position do not change when damage is applied, which is the separation the
## sub-stage is built on.

const SHIP_SCENE := preload("res://scenes/ship/Ship.tscn")
const ROCK_SCENE := preload("res://scenes/obstacles/Rock.tscn")

var _failed := 0
var _checks := 0
var _root: Node2D
var _ship: ShipController
var _hub: ShipSystems
var _base: ShipSystemsParameters
var _rock: RigidBody2D

var _wounds := 0
var _last_wound := 0.0
var _critical_events := 0
var _destroyed_events := 0
var _integrity_events := 0
var _damage_events := 0
var _device_damage_events := 0
var _mounts: Array[Node] = []


## A device that does nothing except exist. It is mounted under a Node2D in the hit
## phase, because a device with no place in space cannot be located.
class Probe extends ShipComponent:
	pass


func _initialize() -> void:
	call_deferred("_run")


func _ok(name: String, condition: bool, detail := "") -> void:
	_checks += 1
	print(("PASS  " if condition else "FAIL  ") + name + "   " + detail)
	if not condition:
		_failed += 1


func _steps(count: int) -> void:
	for i in count:
		await physics_frame


func _on_hull_damaged(amount: float, _integrity: float, _maximum: float,
		_source: String) -> void:
	_wounds += 1
	_last_wound = amount


func _on_hull_critical(_ratio: float) -> void:
	_critical_events += 1


func _on_hull_destroyed() -> void:
	_destroyed_events += 1


func _on_hull_integrity(_ratio: float) -> void:
	_integrity_events += 1


func _on_event(event: ShipSystemEvent) -> void:
	if event.kind == ShipSystemEvent.Kind.DAMAGE_TAKEN:
		if event.component_id == "":
			_damage_events += 1
		else:
			_device_damage_events += 1


## A hull worth `maximum` points whose collision bands are easy to read:
## LIGHT 1, MEDIUM 5, HEAVY 30.
func _fight_params(maximum := 100.0) -> ShipSystemsParameters:
	var p := ShipSystemsParameters.new()
	p.hull_max_integrity = maximum
	p.critical_hull_ratio = 0.25
	p.impact_damage_enabled = true
	p.light_impact_damage = 1.0
	p.medium_impact_damage = 5.0
	p.heavy_impact_damage = 30.0
	return p


## The same hull, with a hit radius and device damage turned on.
func _hit_params() -> ShipSystemsParameters:
	var p := _fight_params(100.0)
	p.component_hit_radius = 90.0
	p.impact_device_damage_scale = 0.5
	return p


## Mount a device where the test says. The Node2D is the device's place in space; the
## component itself is a plain Node, found by walking up, so this also proves the
## location rule does not require a second kind of device.
func _mounted(id: String, at: Vector2) -> ShipComponent:
	var mount := Node2D.new()
	mount.name = id.capitalize() + "Mount"
	var device := Probe.new()
	device.name = id.capitalize()
	device.component_id = id
	device.nominal_power_draw = 0.0
	mount.add_child(device)
	_hub.add_child(mount)
	mount.global_position = at
	_mounts.append(mount)
	return device


func _run() -> void:
	_root = Node2D.new()
	root.add_child(_root)
	_ship = SHIP_SCENE.instantiate()
	_root.add_child(_ship)
	_hub = _ship.get_node_or_null("Systems") as ShipSystems
	if _hub == null:
		print("RESULT: FAILED  Ship.tscn has no Systems node")
		quit(2)
		return
	_base = _hub.parameters
	_hub.hull_damaged.connect(_on_hull_damaged)
	_hub.hull_critical.connect(_on_hull_critical)
	_hub.hull_destroyed.connect(_on_hull_destroyed)
	_hub.hull_integrity_changed.connect(_on_hull_integrity)
	_hub.system_event.connect(_on_event)
	await _steps(3)

	_test_boot()
	_test_pool()
	_test_direct_damage()
	_test_sources()
	_test_invalid()
	_test_critical()
	_test_destruction()
	await _test_hit_location()
	await _test_collision()
	_test_report()
	await _teardown()

	print("")
	print("RESULT: ", "ALL PASS" if _failed == 0 else "FAILED %d of %d" % [_failed, _checks])
	quit(1 if _failed else 0)


# ---------------------------------------------------------------- 1. the boot ---

func _test_boot() -> void:
	print("-- boot")
	_ok("the hull has a maximum", _hub.hull_max_integrity() > 0.0,
		"%.1f points" % _hub.hull_max_integrity())
	_ok("the hull starts whole",
		is_equal_approx(_hub.hull_integrity(), _hub.hull_max_integrity()),
		"%.1f / %.1f" % [_hub.hull_integrity(), _hub.hull_max_integrity()])
	_ok("a whole hull reads 1.0", is_equal_approx(_hub.hull_ratio(), 1.0),
		"%.2f" % _hub.hull_ratio())
	_ok("a whole hull is not critical and not destroyed",
		not _hub.is_hull_critical() and not _hub.is_hull_destroyed())
	_ok("a whole hull is NOMINAL",
		_hub.hull_state() == ShipSystemState.Value.NOMINAL, _hub.state_name())


# ------------------------------------------------------------ 2. a bigger pool ---

func _test_pool() -> void:
	print("-- pool")
	_hub.set_parameters(_fight_params(100.0))
	_ok("the maximum follows the tuning resource",
		is_equal_approx(_hub.hull_max_integrity(), 100.0),
		"%.1f points" % _hub.hull_max_integrity())
	_ok("a whole hull is worth the full pool",
		is_equal_approx(_hub.hull_integrity(), 100.0),
		"%.1f points" % _hub.hull_integrity())
	_ok("a retune keeps the fraction, not the old points",
		is_equal_approx(_hub.hull_ratio(), 1.0), "%.2f" % _hub.hull_ratio())


# ------------------------------------------------------- 3. damage and physics ---

func _test_direct_damage() -> void:
	print("-- damage")
	_ship.global_position = Vector2(10.0, 20.0)
	_ship.linear_velocity = Vector2(123.0, 45.0)
	_ship.angular_velocity = 1.2
	var position := _ship.global_position
	var velocity := _ship.linear_velocity
	var spin := _ship.angular_velocity

	var wounds := _wounds
	var integrity_events := _integrity_events
	var damage_events := _damage_events
	var applied := _hub.apply_hull_damage(20.0, "impact")
	_ok("the requested amount is applied", is_equal_approx(applied, 20.0),
		"%.1f" % applied)
	_ok("the pool loses exactly that much",
		is_equal_approx(_hub.hull_integrity(), 80.0),
		"%.1f points" % _hub.hull_integrity())
	_ok("the ratio follows the pool", is_equal_approx(_hub.hull_ratio(), 0.8),
		"%.2f" % _hub.hull_ratio())
	_ok("the wound is signalled", _wounds == wounds + 1,
		"%d wounds" % _wounds)
	_ok("the signal carries the applied amount",
		is_equal_approx(_last_wound, 20.0), "%.1f" % _last_wound)
	_ok("the level change is signalled", _integrity_events == integrity_events + 1,
		"%d events" % _integrity_events)
	_ok("the wound reaches the bus", _damage_events == damage_events + 1,
		"%d events" % _damage_events)

	_ok("damage does not move the hull",
		_ship.global_position.is_equal_approx(position))
	_ok("damage does not change velocity",
		_ship.linear_velocity.is_equal_approx(velocity))
	_ok("damage does not change spin",
		is_equal_approx(_ship.angular_velocity, spin))


# --------------------------------------------------------- 4. damage sources ----

func _test_sources() -> void:
	print("-- sources")
	var p := _hub.settings()
	p.damage_source_scale = {
		"arc": 0.5,
		"fire": 2.0,
		"bad": -3.0,
		"broken": NAN,
	}
	_hub.set_parameters(p)
	_ok("an unknown source costs its full amount",
		is_equal_approx(_hub.damage_scale_for("unknown"), 1.0),
		"x%.1f" % _hub.damage_scale_for("unknown"))
	_ok("a source can be discounted",
		is_equal_approx(_hub.damage_scale_for("arc"), 0.5),
		"x%.1f" % _hub.damage_scale_for("arc"))
	_ok("a negative multiplier is ignored",
		is_equal_approx(_hub.damage_scale_for("bad"), 1.0),
		"x%.1f" % _hub.damage_scale_for("bad"))
	_ok("a non-finite multiplier is ignored",
		is_equal_approx(_hub.damage_scale_for("broken"), 1.0),
		"x%.1f" % _hub.damage_scale_for("broken"))

	_ok("a discounted hit takes the discounted amount",
		is_equal_approx(_hub.apply_hull_damage(10.0, "arc"), 5.0)
			and is_equal_approx(_hub.hull_integrity(), 75.0),
		"%.1f points" % _hub.hull_integrity())
	_ok("an amplified hit takes the amplified amount",
		is_equal_approx(_hub.apply_hull_damage(10.0, "fire"), 20.0)
			and is_equal_approx(_hub.hull_integrity(), 55.0),
		"%.1f points" % _hub.hull_integrity())
	_ok("a new source needs no table entry",
		is_equal_approx(_hub.apply_hull_damage(10.0, "ram"), 10.0)
			and is_equal_approx(_hub.hull_integrity(), 45.0),
		"%.1f points" % _hub.hull_integrity())


# ---------------------------------------------------------- 5. invalid damage ---

func _test_invalid() -> void:
	print("-- invalid")
	var before := _hub.hull_integrity()
	var wounds := _wounds
	_ok("a zero hit is refused", is_equal_approx(_hub.apply_hull_damage(0.0), 0.0))
	_ok("a negative hit is refused",
		is_equal_approx(_hub.apply_hull_damage(-5.0), 0.0))
	_ok("a NaN hit is refused",
		is_equal_approx(_hub.apply_hull_damage(NAN), 0.0))
	_ok("an infinite hit is refused",
		is_equal_approx(_hub.apply_hull_damage(INF), 0.0))
	_ok("a refused hit changes nothing",
		is_equal_approx(_hub.hull_integrity(), before) and _wounds == wounds,
		"%.1f points, %d wounds" % [_hub.hull_integrity(), _wounds])


# ------------------------------------------------------------- 6. critical ------

func _test_critical() -> void:
	print("-- critical")
	_ok("a healthy hull has not raised the alarm", _critical_events == 0,
		"%d events" % _critical_events)
	var applied := _hub.apply_hull_damage(20.0, "impact")
	_ok("the hull crossed the critical line",
		is_equal_approx(applied, 20.0)
			and is_equal_approx(_hub.hull_integrity(), 25.0),
		"%.1f points" % _hub.hull_integrity())
	_ok("the critical alarm fires on the crossing", _critical_events == 1,
		"%d events" % _critical_events)
	_ok("the hull reports critical", _hub.is_hull_critical())
	_hub.apply_hull_damage(5.0, "impact")
	_ok("a second hit does not repeat the alarm", _critical_events == 1,
		"%d events" % _critical_events)


# ----------------------------------------------------------- 7. destruction ------

func _test_destruction() -> void:
	print("-- destruction")
	var wounded := _wounds
	var damage_events := _damage_events
	var applied := _hub.apply_hull_damage(20.0, "impact")
	_ok("the last points are applied", is_equal_approx(applied, 20.0),
		"%.1f" % applied)
	_ok("the pool stops at zero",
		is_equal_approx(_hub.hull_integrity(), 0.0)
			and is_equal_approx(_hub.hull_ratio(), 0.0),
		"%.1f points" % _hub.hull_integrity())
	_ok("a wreck is OFFLINE",
		_hub.hull_state() == ShipSystemState.Value.OFFLINE, _hub.state_name())
	_ok("destruction is signalled once", _destroyed_events == 1,
		"%d events" % _destroyed_events)
	_ok("the hull reports destroyed", _hub.is_hull_destroyed())
	_ok("the wreck still reports its wound", _wounds == wounded + 1
		and _damage_events == damage_events + 1)

	var later := _hub.apply_hull_damage(50.0, "impact")
	_ok("a wreck accepts no further damage", is_equal_approx(later, 0.0))
	_ok("a wreck does not go negative", _hub.hull_integrity() >= 0.0,
		"%.1f points" % _hub.hull_integrity())
	_ok("a wreck does not re-announce itself",
		_destroyed_events == 1 and _wounds == wounded + 1,
		"%d destroyed, %d wounds" % [_destroyed_events, _wounds])


# ------------------------------------------------------- 8. per-device hit location ---

## The flight model reports an estimated contact point. This phase proves a mounted
## device near that point is named, takes its share, and that a device elsewhere is left
## alone - the "which compartment" answer stage 4.3 deliberately left open.
func _test_hit_location() -> void:
	print("-- hit location")
	_hub.set_parameters(_hit_params())
	_hub.repair_hull(1000.0)
	var sensor := _mounted("sensor", Vector2.ZERO)
	var far := _mounted("far", Vector2(500.0, 0.0))
	_ok("a placed device can be located",
		_hub.hit_component({"contact_point": Vector2.ZERO}) == sensor)

	var device_events := _device_damage_events
	var event := _hub.report_impact({
		"closing_speed": 600.0,
		"category": "HEAVY",
		"contact_point": Vector2.ZERO,
		"description": {"kind": "asteroid", "label": "synthetic"},
	})
	_ok("the impact names the device that was struck",
		String(event.data.get("hit_component", "")) == "sensor",
		String(event.data.get("hit_component", "")))
	_ok("the location is marked as an estimate",
		bool(event.data.get("hit_is_estimate", false)))
	_ok("the hull paid the band cost",
		is_equal_approx(_hub.hull_integrity(), 70.0),
		"%.1f points" % _hub.hull_integrity())
	_ok("the struck device lost half the hull's fraction",
		is_equal_approx(sensor.integrity, 0.85), "%.2f" % sensor.integrity)
	_ok("the untouched device kept everything",
		is_equal_approx(far.integrity, 1.0), "%.2f" % far.integrity)
	_ok("the device wound reached the bus", _device_damage_events == device_events + 1,
		"%d events" % (_device_damage_events - device_events))
	_ok("a contact elsewhere picks the other device",
		_hub.hit_component({"contact_point": Vector2(500.0, 0.0)}) == far)
	_ok("nothing is hit outside the radius",
		_hub.hit_component({"contact_point": Vector2(2000.0, 2000.0)}) == null)

	var p := _hub.settings()
	p.impact_device_damage_scale = 0.0
	_hub.set_parameters(p)
	var hull_before := _hub.hull_integrity()
	var device_before := sensor.integrity
	var quiet := _hub.report_impact({
		"closing_speed": 600.0,
		"category": "HEAVY",
		"contact_point": Vector2.ZERO,
		"description": {"kind": "asteroid", "label": "synthetic"},
	})
	_ok("a zero scale still reports the location",
		String(quiet.data.get("hit_component", "")) == "sensor")
	_ok("a zero scale spares the device",
		is_equal_approx(sensor.integrity, device_before), "%.2f" % sensor.integrity)
	_ok("the hull still paid",
		is_equal_approx(_hub.hull_integrity(), hull_before - 30.0),
		"%.1f points" % _hub.hull_integrity())

	p.component_hit_radius = 0.0
	_hub.set_parameters(p)
	_ok("a zero radius disables location",
		_hub.hit_component({"contact_point": Vector2.ZERO}) == null)

	for mount in _mounts:
		if is_instance_valid(mount):
			mount.queue_free()
	_mounts.clear()
	await _steps(2)
	_ok("the placed devices leave the bus", _hub.count() == 0,
		"%d left" % _hub.count())


# ------------------------------------------------------- 9. a real collision ----

func _test_collision() -> void:
	print("-- collision")
	_hub.set_parameters(_fight_params(100.0))
	_hub.repair_hull(1000.0)
	_ok("the scenario starts with a whole hull",
		is_equal_approx(_hub.hull_integrity(), 100.0)
			and not _hub.is_hull_destroyed(),
		"%.1f points" % _hub.hull_integrity())

	_ship.global_position = Vector2.ZERO
	_ship.rotation = 0.0
	_ship.linear_velocity = Vector2.ZERO
	_ship.angular_velocity = 0.0
	_rock = ROCK_SCENE.instantiate()
	_rock.set("shape", "04")
	_rock.set("px_scale", 2.0)
	_root.add_child(_rock)
	_rock.global_position = Vector2(700.0, 0.0)
	_rock.linear_velocity = Vector2.ZERO
	await _steps(2)

	var impacts := _hub.damage.impact_count
	var wounds := _wounds
	var damage_events := _damage_events
	_ship.linear_velocity = Vector2(650.0, 0.0)
	var waited := 0
	while _hub.damage.impact_count == impacts and waited < 180:
		await physics_frame
		waited += 1
	_ok("a real contact reaches the damage layer",
		_hub.damage.impact_count > impacts, "after %d frames" % waited)
	_ok("one contact wounds the hull once", _wounds == wounds + 1,
		"%d wounds" % (_wounds - wounds))
	_ok("one contact raises one damage event", _damage_events == damage_events + 1,
		"%d events" % (_damage_events - damage_events))
	var severity := String(_hub.damage.last_impact.get("severity", ""))
	_ok("the cost follows the classified band",
		severity == "HEAVY" and is_equal_approx(_hub.hull_integrity(), 70.0),
		"%s, %.1f points left" % [severity, _hub.hull_integrity()])

	var speed_after := _ship.linear_velocity.length()
	_ok("the contact does not amplify the hull's speed", speed_after <= 700.0,
		"%.0f px/s" % speed_after)
	_ok("the hull is still flying after the hit", speed_after > 50.0,
		"%.0f px/s" % speed_after)

	# Less than the controller's 0.3 s contact cooldown: the same contact must not pay
	# a second time just because the physics server kept reporting shapes.
	var wounds_after := _wounds
	await _steps(10)
	_ok("a repeated shape report is not a second wound", _wounds == wounds_after,
		"%d extra" % (_wounds - wounds_after))

	_ship.linear_velocity = Vector2.ZERO
	_ship.angular_velocity = 0.0
	if _rock != null and is_instance_valid(_rock):
		_rock.queue_free()
		_rock = null
	await _steps(2)


# --------------------------------------------------------------- 10. report -----

func _test_report() -> void:
	print("-- panel")
	var text := "\n".join(_hub.report())
	_ok("the panel prints the hull's points and maximum",
		text.contains("hull") and text.contains("/"))
	_ok("the panel still prints the impact line", text.contains("impacts"))
	for line in _hub.report():
		print("    " + line)


func _teardown() -> void:
	print("-- teardown")
	for device in _hub.components():
		device.queue_free()
	_hub.set_parameters(_base)
	_hub.repair_hull(10.0)
	await _steps(2)
	_ok("the hull returns to its shipping maximum",
		is_equal_approx(_hub.hull_max_integrity(), 1.0),
		"%.1f" % _hub.hull_max_integrity())
	_ok("the hull never exceeded its maximum",
		_hub.hull_integrity() <= _hub.hull_max_integrity() + 0.001,
		"%.3f / %.3f" % [_hub.hull_integrity(), _hub.hull_max_integrity()])
	_ok("the hull never went negative", _hub.hull_integrity() >= 0.0,
		"%.3f" % _hub.hull_integrity())
	_ok("the hull is whole again for the next suite",
		is_equal_approx(_hub.hull_ratio(), 1.0), "%.2f" % _hub.hull_ratio())