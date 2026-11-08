extends Node2D
class_name Leviathan

## The thing that lives around the giant.
##
## It is huge and it is mostly not here. It is a position in the world and a
## state, and the pilot meets it through what it does: a contact that should
## not be on the scope, the radio going to static, a call from very far away,
## the brood it sends, and - rarely - its shape passing under the ship.
##
## Behaviour is a small state machine driven by `ThreatAttention` (what it
## hears of the ship) and by the signals on the air (flares and decoys). It is
## never random about *whether* it comes; only small details are rolled. The
## rules a pilot can learn:
##
##   * a quiet ship is lost; a loud ship is found;
##   * it goes to the last place it heard you, not to where you are;
##   * a burning flare is more interesting than a ship, a decoy less so;
##   * after it gives up it stays away for a while - there is always a calm.
##
## The mission sets `aggression`: 0 asleep, 1 watches, 2 searches, 3 hunts
## (sends the brood), 4 the finale (shows itself).

enum State { HIDDEN, OBSERVING, INVESTIGATING, APPROACHING, MANIFEST, RETREATING }

const STATE_NAMES := ["HIDDEN", "OBSERVING", "INVESTIGATING", "APPROACHING", "MANIFEST", "RETREATING"]
const STATE_TEXT := ["ТИШИНА", "НАБЛЮДЕНИЕ", "ПОИСК", "СБЛИЖЕНИЕ", "ПРОЯВЛЕНИЕ", "ОТХОД"]
const GROUP := "leviathan"
const WORLD_PAUSABLE_GROUP := "world_pausable"
const BROOD_SCRIPT := preload("res://scripts/threat/brood_hunter.gd")
## The most brood that can be out at once.
const MAX_BROOD := 3

signal state_changed(previous: int, current: int)
## A flare or a decoy drew it away from the ship.
signal lured(kind: String, at: Vector2)
signal brood_spawned(count: int)
signal manifested()

@export_group("Distances")
@export var observe_distance: float = 4200.0
@export var approach_distance: float = 1600.0
@export var far_distance: float = 9000.0
@export var arrive_radius: float = 450.0
@export_group("Speeds")
@export var drift_speed: float = 140.0
@export var search_speed: float = 340.0
@export var hunt_speed: float = 420.0
@export var retreat_speed: float = 520.0
@export_group("Timing")
@export var linger_sec: float = 7.0
@export var hunt_sec: float = 32.0
@export var calm_sec: float = 75.0
@export var manifest_sec: float = 11.0
@export var manifest_cooldown_sec: float = 300.0

## Set by the mission director.
var aggression: int = 0

var _state: int = State.HIDDEN
var _target: Vector2 = Vector2.ZERO
var _timer: float = 0.0
var _calm_until: float = 0.0
var _quiet_for: float = 0.0
var _brood_this_hunt: bool = false
var _manifest_ready_at: float = 0.0
var _lure_id: String = ""
var _attention: ThreatAttention = null
var _time: float = 0.0
var _manifest_t: float = 0.0
var _manifest_from: Vector2 = Vector2.ZERO
var _manifest_to: Vector2 = Vector2.ZERO
## Forces a manifestation the next time the state machine can show itself.
var _manifest_requested: bool = false
## Whether the last frame drew the shape (one more redraw clears it).
var _was_drawn: bool = false


func _ready() -> void:
	add_to_group(GROUP)
	add_to_group(WORLD_PAUSABLE_GROUP)
	z_index = -20
	# build the brood's frames now: the first hunt must not stall on 22 PNGs
	BroodHunter._shared_frames()
	visible = true


## ------------------------------------------------------------------ reading ---

func state() -> int:
	return _state


func state_name() -> String:
	return STATE_NAMES[_state]


func state_text() -> String:
	return STATE_TEXT[_state]


func distance_to_ship() -> float:
	var ship := _ship()
	return INF if ship == null else global_position.distance_to(ship.global_position)


func is_near() -> bool:
	return _state == State.APPROACHING or _state == State.MANIFEST


## What the scanner learns of it: nothing but a shape.
func world_object_info() -> Dictionary:
	return {"title": "НЕОПОЗНАННЫЙ ОБЪЕКТ", "description": "Масса не определяется."}


## ----------------------------------------------------------------- commands ---

func set_aggression(value: int) -> void:
	aggression = clampi(value, 0, 4)
	if aggression == 0 and _state != State.HIDDEN:
		_go(State.RETREATING)


## The finale asks for the shape to appear as soon as it can.
func request_manifest() -> void:
	_manifest_requested = true
	_manifest_ready_at = 0.0


## Start a hunt now, from wherever it is (the finale, a scripted event).
func force_hunt() -> void:
	var ship := _ship()
	if ship == null:
		return
	_target = ship.global_position
	_lure_id = ""
	_calm_until = 0.0
	if _state == State.APPROACHING:
		_timer = 0.0
	_go(State.APPROACHING)


## Put it somewhere specific (the finale, a test).
func place(at: Vector2) -> void:
	global_position = at


## ---------------------------------------------------------------- behaviour ---

func _physics_process(delta: float) -> void:
	_time += delta
	var ship := _ship()
	if ship == null:
		return
	if _attention == null or not is_instance_valid(_attention):
		_attention = get_tree().get_first_node_in_group(ThreatAttention.GROUP) as ThreatAttention
		if _attention == null:
			return
	var att := _attention.attention()
	var now := ShipSystemEvent.now()
	_timer += delta
	_update_scan_presence()

	# a burning signal is more interesting than a ship
	if _state in [State.OBSERVING, State.INVESTIGATING, State.APPROACHING]:
		var lure := _best_lure()
		if not lure.is_empty() and str(lure["source_id"]) != _lure_id:
			_lure_id = str(lure["source_id"])
			_target = lure["position"]
			_go(State.INVESTIGATING)
			lured.emit(str(lure["kind"]), _target)
		elif not lure.is_empty():
			_target = lure["position"]

	match _state:
		State.HIDDEN:
			_drift_far(ship, delta)
			if aggression >= 1 and now >= _calm_until and att >= 20.0:
				_go(State.OBSERVING)
		State.OBSERVING:
			var heard := _attention.last_heard_position()
			var want := heard + (global_position - heard).normalized() * observe_distance
			_move_towards(want, drift_speed * 1.6, delta)
			_quiet_for = _quiet_for + delta if att < 12.0 else 0.0
			if _quiet_for > 18.0 or aggression < 1:
				_go(State.RETREATING)
			elif aggression >= 3 and att >= 72.0:
				_target = heard
				_go(State.APPROACHING)
			elif aggression >= 2 and att >= 45.0:
				_target = heard
				_go(State.INVESTIGATING)
		State.INVESTIGATING:
			if _lure_id.is_empty() and _attention.seconds_since_heard() < 2.0:
				_target = _attention.last_heard_position()
			if _move_towards(_target, search_speed, delta):
				if _timer > linger_sec + 3.0:
					_finish_search(ship, att)
			else:
				_timer = minf(_timer, 3.0)
			if aggression >= 3 and att >= 72.0 and _lure_id.is_empty():
				_go(State.APPROACHING)
		State.APPROACHING:
			if not _lure_id.is_empty():
				_go(State.INVESTIGATING)
				return
			var close := global_position.distance_to(ship.global_position)
			# it follows the noise; a ship that goes silent slips away
			if _attention.noise() > 0.12 or close < approach_distance * 1.4:
				_target = ship.global_position
				_quiet_for = 0.0
			else:
				_quiet_for += delta
			var stand := _target + (global_position - _target).normalized() * approach_distance
			_move_towards(stand, hunt_speed, delta)
			if close < approach_distance * 1.6 and not _brood_this_hunt:
				_spawn_brood(ship, att)
			if (aggression >= 4 or _manifest_requested or att >= 92.0) \
					and now >= _manifest_ready_at and close < approach_distance * 2.0:
				_begin_manifest(ship)
			elif _timer > hunt_sec or _quiet_for > 9.0:
				_go(State.RETREATING)
		State.MANIFEST:
			_manifest_t += delta
			var k := clampf(_manifest_t / manifest_sec, 0.0, 1.0)
			global_position = _manifest_from.lerp(_manifest_to, k * k * (3.0 - 2.0 * k))
			if _manifest_t >= manifest_sec:
				_go(State.RETREATING)
		State.RETREATING:
			var away := (global_position - ship.global_position).normalized()
			if away == Vector2.ZERO:
				away = Vector2.UP
			_move_towards(ship.global_position + away * far_distance, retreat_speed, delta)
			if global_position.distance_to(ship.global_position) > far_distance * 0.9 or _timer > 25.0:
				_attention.soothe(35.0)
				_calm_until = now + calm_sec
				_go(State.HIDDEN)
	# only the manifestation is drawn
	if _state == State.MANIFEST or _was_drawn:
		queue_redraw()
	_was_drawn = _state == State.MANIFEST


func _finish_search(ship: Node2D, att: float) -> void:
	var close := global_position.distance_to(ship.global_position)
	var hearing := 900.0 + _attention.noise() * 2600.0
	if not _lure_id.is_empty():
		# it found a flare or a decoy and nothing behind it
		_attention.soothe(22.0)
		_lure_id = ""
		_go(State.OBSERVING)
	elif aggression >= 3 and close < hearing:
		_go(State.APPROACHING)
	else:
		_attention.soothe(12.0)
		_go(State.OBSERVING if att > 15.0 else State.RETREATING)


func _go(next: int) -> void:
	if next == _state:
		return
	var previous := _state
	_state = next
	_timer = 0.0
	_quiet_for = 0.0
	if next == State.APPROACHING:
		_brood_this_hunt = false
	if next == State.RETREATING or next == State.HIDDEN:
		_lure_id = ""
	state_changed.emit(previous, next)


func _drift_far(ship: Node2D, delta: float) -> void:
	var off := global_position - ship.global_position
	if off.length() < far_distance * 0.7 or off.length() > far_distance * 1.6:
		var dir := off.normalized() if off != Vector2.ZERO else Vector2.RIGHT
		_move_towards(ship.global_position + dir * far_distance, retreat_speed, delta)
	else:
		_move_towards(global_position + off.orthogonal().normalized() * 300.0, drift_speed, delta)


## Returns true once arrived.
func _move_towards(point: Vector2, speed: float, delta: float) -> bool:
	var to := point - global_position
	var d := to.length()
	if d <= arrive_radius:
		return true
	global_position += to / d * minf(speed * delta, d)
	return false


## The most interesting signal it can hear, weighted by kind.
func _best_lure() -> Dictionary:
	var broadcaster := get_tree().get_root().get_node_or_null("SignalBroadcaster")
	if broadcaster == null or not broadcaster.has_method("messages"):
		return {}
	var best := {}
	var best_score := 0.0
	var ship_score := 0.35 + (_attention.noise() if _attention != null else 0.0)
	for msg in broadcaster.call("messages"):
		var kind := str(msg.get("kind", ""))
		var weight := 0.0
		if kind.begins_with("signal_light"):
			weight = 1.4
		elif kind.begins_with("decoy"):
			weight = 0.7
		if weight <= 0.0:
			continue
		var pos: Vector2 = msg.get("position", Vector2.ZERO)
		var reach := float(msg.get("radius_px", 0.0)) * 3.0 + 3000.0
		var d := pos.distance_to(global_position)
		if d > reach:
			continue
		var score := weight * float(msg.get("intensity", 1.0)) * (1.0 - d / reach * 0.5)
		if score > best_score and score > ship_score:
			best_score = score
			best = msg
	return best


func _spawn_brood(ship: Node2D, att: float) -> void:
	if aggression < 3:
		return
	_brood_this_hunt = true
	var alive := get_tree().get_nodes_in_group(BroodHunter.GROUP).size()
	if alive >= MAX_BROOD:
		return
	var count := 1
	if att > 82.0:
		count += 1
	if aggression >= 4:
		count += 1
	count = mini(count, MAX_BROOD - alive)
	var host := get_parent()
	var from_dir := (global_position - ship.global_position).normalized()
	for i in count:
		var hunter: Node2D = BROOD_SCRIPT.new()
		var angle := from_dir.angle() + (float(i) - float(count - 1) * 0.5) * 0.6
		hunter.global_position = ship.global_position + Vector2.RIGHT.rotated(angle) * 1350.0
		host.add_child(hunter)
	brood_spawned.emit(count)


func _begin_manifest(ship: Node2D) -> void:
	_manifest_requested = false
	_manifest_ready_at = ShipSystemEvent.now() + manifest_cooldown_sec
	_manifest_t = 0.0
	var side := Vector2.RIGHT.rotated(randf() * TAU)
	_manifest_from = ship.global_position - side * 2600.0 + side.orthogonal() * 500.0
	_manifest_to = ship.global_position + side * 2600.0 - side.orthogonal() * 300.0
	global_position = _manifest_from
	_go(State.MANIFEST)
	if not _brood_this_hunt:
		_spawn_brood(ship, 90.0)
	manifested.emit()


## The scanner can see a shape when the thing is close enough to be a shape.
func _update_scan_presence() -> void:
	var visible_to_scan := _state in [State.OBSERVING, State.INVESTIGATING,
		State.APPROACHING, State.MANIFEST]
	if visible_to_scan and not is_in_group("scan_target"):
		add_to_group("scan_target")
	elif not visible_to_scan and is_in_group("scan_target"):
		remove_from_group("scan_target")


func _ship() -> Node2D:
	return GameNodes.ship(get_tree())


## Only the manifestation is drawn: a vast dark body sliding under the ship,
## its outline barely lighter than space, one red light in it.
func _draw() -> void:
	if _state != State.MANIFEST:
		return
	var k := clampf(_manifest_t / manifest_sec, 0.0, 1.0)
	var fade := sin(k * PI)
	var dir := (_manifest_to - _manifest_from).normalized()
	var rot := dir.angle()
	var body := PackedVector2Array()
	var length := 2600.0
	var girth := 620.0
	for i in 40:
		var t := float(i) / 39.0
		var x := lerpf(-length * 0.5, length * 0.5, t)
		var w := girth * sin(t * PI) * (0.75 + 0.25 * sin(t * 9.0 + _time * 0.7))
		body.append(Vector2(x, -w).rotated(rot))
	for i in 40:
		var t := 1.0 - float(i) / 39.0
		var x := lerpf(-length * 0.5, length * 0.5, t)
		var w := girth * sin(t * PI) * (0.8 + 0.2 * cos(t * 7.0 - _time * 0.5))
		body.append(Vector2(x, w).rotated(rot))
	draw_colored_polygon(body, Color(0.0, 0.0, 0.01, 0.78 * fade))
	var rim := body.duplicate()
	rim.append(body[0])
	draw_polyline(rim, Color(0.25, 0.45, 0.6, 0.18 * fade), 40.0, true)
	draw_polyline(rim, Color(0.45, 0.7, 0.85, 0.45 * fade), 8.0, true)
	for n in 24:
		var u := float(n) / 23.0
		var p := Vector2(lerpf(-length * 0.4, length * 0.35, u), sin(u * 17.0) * girth * 0.4).rotated(rot)
		draw_circle(p, 10.0 + 6.0 * sin(_time * 2.0 + n), Color(0.9, 0.2, 0.15, 0.25 * fade))
	# tendrils
	for j in 7:
		var base := Vector2(lerpf(-length * 0.35, length * 0.2, float(j) / 6.0), 0.0)
		var pts := PackedVector2Array()
		for s in 14:
			var u := float(s) / 13.0
			pts.append((base + Vector2(-u * 900.0, sin(u * 5.0 + _time + j) * 220.0 * u
				+ (girth * 0.8 if j % 2 == 0 else -girth * 0.8) * u)).rotated(rot))
		draw_polyline(pts, Color(0.0, 0.0, 0.02, 0.6 * fade), 40.0 - float(j) * 3.0)
	var eye := Vector2(length * 0.32, -girth * 0.15).rotated(rot)
	var pulse := 0.6 + 0.4 * sin(_time * 3.0)
	draw_circle(eye, 90.0, Color(0.6, 0.02, 0.02, 0.18 * fade * pulse))
	draw_circle(eye, 34.0, Color(0.95, 0.12, 0.08, 0.7 * fade * pulse))
	draw_circle(eye, 12.0, Color(1.0, 0.7, 0.5, 0.9 * fade))
