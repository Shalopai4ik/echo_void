extends ShipComponent
class_name ShipSignalLight

const SignalMessage := preload("res://scripts/signal/signal_message.gd")
const SignalBroadcaster := preload("res://scripts/signal/signal_broadcaster.gd")
const ShipSystems := preload("res://scripts/ship/systems/ship_systems.gd")

## A signal light: a one-shot beacon the pilot drops into space.
##
## It is a `ShipComponent`, mounted under `Ship/Systems`. It draws no running
## power: the pilot pays one activation cost out of the reserve, the beacon burns
## for `duration_sec`, then removes itself from the air. While it burns it
## broadcasts a `SignalMessage` through `SignalBroadcaster`, so anything in the
## world can hear it and decide whether to react. The light only shouts; it never
## decides who listens.
##
## Future upgrades touch the exports or swap in a profile resource; no new device
## type is needed.

@export_range(0.0, 5000.0, 1.0, "suffix:units") var activation_cost: float = 20.0
@export_range(0.0, 600.0, 0.5, "suffix:sec") var duration_sec: float = 15.0
@export_range(0.0, 900.0, 0.5, "suffix:sec") var cooldown_sec: float = 45.0
@export_range(0.0, 8.0, 0.1) var intensity: float = 1.0
@export_range(0.0, 4096.0, 10.0, "suffix:px") var radius_px: float = 600.0

signal signal_activated(duration_sec: float, intensity: float, radius_px: float)
signal signal_deactivated(reason: String)
signal signal_finished()
signal signal_refused(reason: String)

var _active: bool = false
var _ends_at: float = 0.0
var _cooldown_until: float = 0.0
var _source_id: String = ""

func activate() -> bool:
	if _active:
		return true
	var now := ShipSystemEvent.now()
	if now < _cooldown_until:
		_refuse("cooldown")
		return false
	var hub_node := _systems()
	if hub_node == null:
		_refuse("blocked")
		return false
	var hub := hub_node as ShipSystems
	if hub == null:
		_refuse("blocked")
		return false
	var blocked := hub.activation_block_reason(component_id)
	if not blocked.is_empty():
		_refuse(blocked)
		return false
	if not hub.can_activate(component_id, activation_cost):
		_refuse("energy")
		return false
	if not hub.spend_energy(component_id, activation_cost):
		_refuse("energy")
		return false
	var saved := activation_energy_cost
	activation_energy_cost = 0.0
	hub.set_enabled(component_id, true)
	activation_energy_cost = saved
	if not enabled:
		hub.add_energy(activation_cost)
		_refuse("blocked")
		return false
	_active = true
	_ends_at = now + maxf(duration_sec, 0.0)
	_cooldown_until = _ends_at + maxf(cooldown_sec, 0.0)
	_source_id = "signal_light:%s" % resolved_id()
	var msg := SignalMessage.new(_source_id, _source_position(), intensity,
		radius_px, "signal_light", now, duration_sec)
	var broadcaster := _broadcaster()
	if broadcaster != null:
		broadcaster.broadcast(msg)
	signal_activated.emit(duration_sec, intensity, radius_px)
	publish("signal_activated", {
		"source_id": _source_id,
		"duration_sec": duration_sec,
		"intensity": intensity,
		"radius_px": radius_px,
		"at": now,
	})
	set_physics_process(true)
	return true

func is_signaling() -> bool:
	return _active

func time_remaining() -> float:
	if not _active:
		return 0.0
	return maxf(_ends_at - ShipSystemEvent.now(), 0.0)

func cooldown_remaining() -> float:
	var now := ShipSystemEvent.now()
	if _active:
		return 0.0
	return maxf(_cooldown_until - now, 0.0)

func set_intensity(value: float) -> void:
	intensity = clampf(value, 0.0, 8.0)

func set_radius(value: float) -> void:
	radius_px = clampf(value, 0.0, 4096.0)

func set_duration(value: float) -> void:
	duration_sec = clampf(value, 0.0, 600.0)

func set_cooldown(value: float) -> void:
	cooldown_sec = clampf(value, 0.0, 900.0)

func set_activation_cost(value: float) -> void:
	activation_cost = maxf(value, 0.0)

func can_activate_now() -> bool:
	if _active:
		return false
	if ShipSystemEvent.now() < _cooldown_until:
		return false
	var hub_node := _systems()
	if hub_node == null:
		return false
	var hub := hub_node as ShipSystems
	if hub == null:
		return false
	var blocked := hub.activation_block_reason(component_id)
	if not blocked.is_empty():
		return false
	return hub.can_activate(component_id, activation_cost)

func status() -> Dictionary:
	return {
		"id": resolved_id(),
		"title": display_name(),
		"state_name": "SIGNALING" if _active else ShipSystemState.name_of(state),
		"active": _active,
		"enabled": enabled,
		"time_remaining": time_remaining(),
		"cooldown_remaining": cooldown_remaining(),
		"duration_sec": duration_sec,
		"cooldown_sec": cooldown_sec,
		"intensity": intensity,
		"radius_px": radius_px,
		"activation_cost": activation_cost,
		"can_activate": can_activate_now(),
	}

## End the burn early: the switch went off, the bus starved it, the hull died.
func _end_signal(reason: String) -> void:
	if not _active:
		return
	_active = false
	set_physics_process(false)
	var hub_node := _systems()
	if hub_node != null:
		var hub := hub_node as ShipSystems
		if hub != null:
			hub.set_enabled(component_id, false)
	var broadcaster := _broadcaster()
	if broadcaster != null and not _source_id.is_empty():
		broadcaster.retract(_source_id)
	signal_deactivated.emit(reason)
	publish("signal_deactivated", {
		"source_id": _source_id,
		"reason": reason,
		"at": ShipSystemEvent.now(),
	})
	if reason == "finished":
		signal_finished.emit()
		publish("signal_finished", {
			"source_id": _source_id,
			"at": ShipSystemEvent.now(),
		})
	_cooldown_until = ShipSystemEvent.now() + maxf(cooldown_sec, 0.0)
	_source_id = ""

func _physics_process(_delta: float) -> void:
	if not _active:
		set_physics_process(false)
		return
	var hub_node := _systems()
	if hub_node == null:
		_end_signal("hull_destroyed")
		return
	if bool(hub_node.call("is_hull_destroyed")):
		_end_signal("hull_destroyed")
		return
	if not enabled:
		_end_signal("switched_off")
		return
	if float(hub_node.call("energy_charge")) <= 0.0:
		_end_signal("unpowered")
		return
	if not is_operational():
		_end_signal("unpowered")
		return
	if ShipSystemEvent.now() >= _ends_at:
		_end_signal("finished")

func _refuse(reason: String) -> void:
	signal_refused.emit(reason)
	publish("signal_refused", {
		"source_id": component_id,
		"reason": reason,
		"at": ShipSystemEvent.now(),
	})

func _systems() -> Node:
	if systems != null and is_instance_valid(systems):
		return systems
	var node := get_parent()
	while node != null:
		if node.has_method("spend_energy") and node.has_method("publish"):
			return node
		node = node.get_parent()
	return null

func _source_position() -> Vector2:
	var node := get_parent()
	while node != null:
		if node is Node2D:
			return (node as Node2D).global_position
		node = node.get_parent()
	return Vector2.ZERO

func _broadcaster() -> SignalBroadcaster:
	var root := get_tree().get_root()
	if root == null:
		return null
	var child := root.get_node_or_null("SignalBroadcaster")
	if child != null:
		return child as SignalBroadcaster
	return null
