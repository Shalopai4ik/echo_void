extends Node
class_name ThreatAttention

## What the thing in the dark hears of the ship.
##
## The creature does not cheat: it never reads the hull's position directly.
## It reads this node - a running "attention" figure built from what the ship
## actually does - and the signals on the air (flares, decoys). The rules are
## few and stable, so a pilot can learn them:
##
##   * a hull at rest makes almost no noise; speed, the boost and the
##     thrusters make some;
##   * a scanner sweep is the loudest thing the ship can do (a silenced dish,
##     bought as an upgrade, is half as loud);
##   * a running analysis hums quietly the whole time it runs;
##   * a flare or a decoy is a burst of its own - loud, but somewhere else;
##   * the deeper the ship is towards the giant, the better it is heard.
##
## Attention rises with noise, falls in silence, and the mission scales the
## whole thing (zero during the briefing, so the first minutes are calm).

signal attention_changed(value: float)
## A loud event: what made it and where. The creature uses the last position
## it heard as its best guess of where the ship is.
signal noise_spike(amount: float, position: Vector2, reason: String)

const GROUP := "threat_attention"
const WORLD_PAUSABLE_GROUP := "world_pausable"
## The direction of the gas giant from the start: "deeper" means along it.
const DEPTH_AXIS := Vector2(0.6, -0.8)

## Attention lost per second of silence.
@export_range(0.0, 20.0, 0.1) var decay_per_sec: float = 1.6
## Attention gained per second at noise 1.0.
@export_range(0.0, 50.0, 0.1) var gain_per_sec: float = 7.0
## Spike sizes, in attention points.
@export var spike_scan: float = 9.0
@export var spike_flare: float = 5.0
@export var spike_decoy: float = 3.0
@export var spike_research_done: float = 4.0
## How far along the depth axis the ship must be before the giant's pull
## doubles how well it is heard.
@export_range(1000.0, 60000.0, 100.0, "suffix:px") var depth_full_px: float = 16000.0

## Set by the mission: 0 - nothing listens, 1 - full rules.
var threat_scale: float = 0.0

var _attention: float = 0.0
var _noise: float = 0.0
var _last_heard: Vector2 = Vector2.ZERO
var _heard_at: float = -1000.0
var _ship: Node2D = null
var _systems: Node = null
var _scanner: Node = null
var _research: Node = null


func _ready() -> void:
	add_to_group(GROUP)
	add_to_group(WORLD_PAUSABLE_GROUP)
	call_deferred("_bind")


func _bind() -> void:
	var tree := get_tree()
	_ship = GameNodes.ship(tree)
	if _ship == null:
		return
	_systems = _ship.get_node_or_null("Systems")
	if _systems == null:
		return
	_scanner = _systems.get_node_or_null("Scanner")
	_research = _systems.get_node_or_null("Research")
	if _systems.has_signal("system_event") and not _systems.is_connected("system_event", _on_system_event):
		_systems.connect("system_event", _on_system_event)


## ------------------------------------------------------------------ reading ---

func attention() -> float:
	return _attention


func noise() -> float:
	return _noise


## Where the creature last heard the ship, and how long ago (game seconds).
func last_heard_position() -> Vector2:
	return _last_heard


func seconds_since_heard() -> float:
	return ShipSystemEvent.now() - _heard_at


## How deep a point is towards the giant, 0..1.
func depth_of(point: Vector2) -> float:
	return clampf(point.dot(DEPTH_AXIS) / depth_full_px, 0.0, 1.0)


func ship() -> Node2D:
	return _ship


## The level the HUD shows: 0 calm, 1 noticed, 2 searching, 3 close. The
## creature itself reports its own state; this is only the ear.
func level() -> int:
	if _attention >= 70.0:
		return 3
	if _attention >= 45.0:
		return 2
	if _attention >= 20.0:
		return 1
	return 0


## ------------------------------------------------------------------ writing ---

## A sudden sound. `position` is where it happened.
func add_spike(amount: float, position: Vector2, reason: String) -> void:
	if threat_scale <= 0.0 or amount <= 0.0:
		return
	var scaled := amount * threat_scale * (1.0 + depth_of(position))
	_set_attention(_attention + scaled)
	_last_heard = position
	_heard_at = ShipSystemEvent.now()
	noise_spike.emit(scaled, position, reason)


## Calm the listener down: a decoy that drew it away, a creature that gave up.
func soothe(amount: float) -> void:
	_set_attention(_attention - amount)


func set_attention(value: float) -> void:
	_set_attention(value)


func _set_attention(value: float) -> void:
	var v := clampf(value, 0.0, 100.0)
	if is_equal_approx(v, _attention):
		return
	_attention = v
	attention_changed.emit(_attention)


## ------------------------------------------------------------------- the ear ---

func _physics_process(delta: float) -> void:
	if _ship == null or not is_instance_valid(_ship):
		_bind()
		return
	_noise = _measure_noise()
	var gain := _noise * gain_per_sec * threat_scale * (1.0 + depth_of(_ship.global_position))
	var next := _attention + (gain - decay_per_sec) * delta
	_set_attention(next)
	if _noise > 0.35 and threat_scale > 0.0:
		_last_heard = _ship.global_position
		_heard_at = ShipSystemEvent.now()


## The ship's noise right now, 0..~1.5.
func _measure_noise() -> float:
	var n := 0.0
	if _ship.has_method("speed"):
		n += clampf(float(_ship.call("speed")) / 1400.0, 0.0, 1.0) * 0.3
	var boost: Variant = _ship.get("boost")
	if boost != null and bool(boost.get("active")):
		n += 0.45
	if _scanner != null and is_instance_valid(_scanner) and _scanner.has_method("is_scanning"):
		if bool(_scanner.call("is_scanning")):
			n += 0.9 * _scanner_noise_factor()
	if _research != null and is_instance_valid(_research) and _research.has_method("is_researching"):
		if bool(_research.call("is_researching")):
			n += 0.18
	return n


func _scanner_noise_factor() -> float:
	if _scanner == null:
		return 1.0
	var v: Variant = _scanner.get("noise_factor")
	return float(v) if v != null else 1.0


func _on_system_event(event: ShipSystemEvent) -> void:
	if event == null or _ship == null:
		return
	var topic := str(event.data.get("topic", "")) if event.data is Dictionary else ""
	match topic:
		"scan_started":
			add_spike(spike_scan * _scanner_noise_factor(), _ship.global_position, "scan")
		"signal_activated":
			add_spike(spike_flare, _ship.global_position, "flare")
		"decoy_launched":
			add_spike(spike_decoy, _ship.global_position, "decoy")
		"research_completed":
			var data: Dictionary = event.data.get("data", {}) if event.data is Dictionary else {}
			var extra := float(data.get("disturbance", 0.0)) if data is Dictionary else 0.0
			add_spike(spike_research_done + extra, _ship.global_position, "research")
