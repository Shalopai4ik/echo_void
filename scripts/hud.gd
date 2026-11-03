extends Control

## Flat diegetic-ish HUD: mission bullets, shield/hull bars with glyphs,
## long-range radar and the scanner prompt. Authored for a 960x540 viewport.
##
## The bars read the ship. The radar does not: it holds the last picture the
## scanner took, so what the pilot flies at is what he paid for, and contacts
## slide off the edge as he flies away from them until he sweeps again.

const ACCENT := Color(0.24, 0.80, 0.92)
const TRACK := Color(0.02, 0.13, 0.18)
const BAR_FILL := Color(0.20, 0.78, 0.90)
const HULL_FILL := Color(0.34, 0.86, 0.72)
const HULL_LOW := Color(0.92, 0.44, 0.30)
const BAR_EDGE := Color(0.62, 0.95, 1.0)
const CONTACT_HOT := Color(0.85, 0.34, 0.28)
const CONTACT_COOL := Color(0.55, 0.90, 1.0)

const BAR_POS := Vector2(78.0, 464.0)
const BAR_SIZE := Vector2(166.0, 18.0)
const BAR_STEP := 38.0
const ICON_POS := Vector2(40.0, 462.0)
const ICON_SIZE := Vector2(24.0, 30.0)
const BULLET_X := 40.0
const BULLET_SIZE := 6.0
const BULLET_DROP := 8.0
const ROW_NAMES := ["MissionTitle", "Objective1", "Objective2", "Objective3"]

## World pixels the radar disc covers. Measured off the reference: the dish spans
## a little over three ship lengths, so a stone on the glass is the size it really
## is next to the fighter. A sweep catches a handful of rocks, not the whole belt.
@export var radar_center := Vector2(838.0, 92.0)
@export var radar_radius := 76.0
## How long a sweep's picture stays useful before it is simply stale.
@export var radar_range := 880.0

@export_group("Shield bar")
## The shield runs off the bar instead of snapping: the solid fill closes on the
## true value at this rate, and a pale tail of what was just lost drains behind it
## at `ghost_drain` after sitting still for `ghost_hold` seconds. Fast enough that
## the glass never claims armour the ship no longer has for long.
@export var shield_drain := 11.0
@export var ghost_drain := 1.6
@export var ghost_hold := 0.22

var _shield := 1.0
var _hull := 1.0
var _shield_fill := 1.0
var _shield_ghost := 1.0
var _hold := 0.0
var _settled := false
var _wreck := false
var _hurt := 0.0
var _last_hull := 1.0
var _contacts: Array = []
var _swept := 0.0

var _ship: Node2D
var _belt: Node2D

var _time := 0.0
var _sweep := 0.0
var _pulse := -1.0
var _rows: Array[float] = []
var _track_box := StyleBoxFlat.new()
var _fill_box := StyleBoxFlat.new()
var _glow_box := StyleBoxFlat.new()

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	for row_name in ROW_NAMES:
		_rows.append((get_node(row_name) as Control).position.y)
	_track_box.bg_color = TRACK
	_track_box.set_corner_radius_all(int(BAR_SIZE.y * 0.5))
	_track_box.anti_aliasing = true
	_fill_box.corner_radius_top_left = int(BAR_SIZE.y * 0.5)
	_fill_box.corner_radius_bottom_left = int(BAR_SIZE.y * 0.5)
	_fill_box.corner_radius_top_right = 2
	_fill_box.corner_radius_bottom_right = 2
	_fill_box.anti_aliasing = true
	_glow_box.corner_radius_top_left = int(BAR_SIZE.y * 0.5)
	_glow_box.corner_radius_bottom_left = int(BAR_SIZE.y * 0.5)
	_glow_box.corner_radius_top_right = 2
	_glow_box.corner_radius_bottom_right = 2
	_glow_box.anti_aliasing = true
	_find_ship()
	_scan()

func _process(delta: float) -> void:
	_time += delta
	_sweep = fmod(_sweep + delta * 0.9, TAU)
	_hurt = maxf(_hurt - delta * 2.2, 0.0)
	if _pulse >= 0.0:
		_pulse += delta * 0.9
		if _pulse > 1.0:
			_pulse = -1.0
	if Input.is_action_just_pressed("scan"):
		_pulse = 0.0
		_scan()
	_read_ship(delta)
	queue_redraw()

# ------------------------------------------------------------------ live state

func _find_ship() -> void:
	if _ship == null or not is_instance_valid(_ship):
		_ship = get_tree().get_first_node_in_group("player")
	if _belt == null or not is_instance_valid(_belt):
		_belt = get_tree().get_first_node_in_group("asteroid_field")

## Pull the bars off the ship rather than tracking its signals: the HUD is a
## sibling under a CanvasLayer and would otherwise have to care about load order.
func _read_ship(delta: float) -> void:
	_find_ship()
	if _ship == null or not _ship.has_method("shield_ratio"):
		return
	_shield = _ship.shield_ratio()
	_hull = _ship.hull_ratio()
	_wreck = bool(_ship.get("destroyed"))
	if _hull < _last_hull - 0.001:
		_hurt = 1.0
	_last_hull = _hull
	_drain_shield(delta)


## The bar chases the real number instead of snapping to it. The solid fill closes
## on the truth fast, and a pale tail of what was just lost holds for a beat and
## then runs off - so a hit reads as armour bleeding away, not as a jump cut, and
## the glass never claims shield the ship does not have for longer than a few
## frames.
func _drain_shield(delta: float) -> void:
	if not _settled:
		_shield_fill = _shield
		_shield_ghost = _shield
		_settled = true
		return
	if _shield >= _shield_fill:
		# the shield climbing back is already a smooth motion; do not lag it
		_shield_fill = _shield
	_shield_ghost = maxf(_shield_ghost, _shield_fill)
	if _shield_fill > _shield:
		# easing alone never arrives: without the landing, the tail below would
		# be held off forever by a fill that is still technically "draining"
		var next := lerpf(_shield_fill, _shield, 1.0 - exp(-shield_drain * delta))
		_shield_fill = _shield if next - _shield < 0.004 else next
		if _shield_fill > _shield:
			_hold = ghost_hold
	if _hold > 0.0:
		_hold = maxf(_hold - delta, 0.0)
	elif _shield_ghost > _shield_fill:
		_shield_ghost = maxf(_shield_ghost - delta * ghost_drain, _shield_fill)


## What the glass shows right now, and the tail still running off it.
func shield_display() -> float:
	return _shield_fill


func shield_ghost() -> float:
	return _shield_ghost

func _scan() -> void:
	_find_ship()
	_contacts.clear()
	if _ship == null or _belt == null or not _belt.has_method("radar_contacts"):
		return
	_contacts = _belt.radar_contacts(_ship.global_position, radar_range)
	_swept = _time


## The picture currently on the glass, as the world positions the last sweep
## caught. A copy: the only way to change what the radar shows is to scan.
func contacts() -> Array:
	return _contacts.duplicate()

# ---------------------------------------------------------------------- drawing

func _draw() -> void:
	_draw_bullets()
	_draw_bar(0, _shield_fill, BAR_FILL, _shield_ghost)
	_draw_shield_glyph()
	_draw_bar(1, _hull, HULL_LOW if _hull < 0.35 else HULL_FILL)
	_draw_core_glyph()
	_draw_radar()

func _draw_bullets() -> void:
	for top in _rows:
		var r := Rect2(BULLET_X, top + BULLET_DROP, BULLET_SIZE, BULLET_SIZE)
		draw_rect(r, Color(ACCENT, 0.75))
		draw_rect(r.grow(1.5), Color(ACCENT, 0.12))

func _draw_bar(index: int, ratio: float, tone: Color, ghost := -1.0) -> void:
	var origin: Vector2 = BAR_POS + Vector2(0.0, BAR_STEP * index)
	var filled := BAR_SIZE.x * clampf(ratio, 0.0, 1.0)
	var flash := _hurt * (1.0 - float(index))

	if filled > 2.0:
		_glow_box.bg_color = Color(tone, 0.09)
		var fill_rect := Rect2(origin, Vector2(filled, BAR_SIZE.y))
		draw_style_box(_glow_box, Rect2(fill_rect.position - Vector2(6.0, 9.0),
			fill_rect.size + Vector2(12.0, 18.0)))
		draw_style_box(_glow_box, Rect2(fill_rect.position - Vector2(2.0, 4.0),
			fill_rect.size + Vector2(4.0, 8.0)))
		draw_rect(Rect2(fill_rect.position + Vector2(4.0, BAR_SIZE.y),
			Vector2(maxf(filled - 8.0, 0.0), 6.0)), Color(tone, 0.05))

	_track_box.bg_color = TRACK.lerp(Color(0.30, 0.05, 0.05), flash * 0.8)
	draw_style_box(_track_box, Rect2(origin, BAR_SIZE))
	if ghost > ratio + 0.002:
		# the armour that has just gone: a pale tail running off the live end
		var lost := BAR_SIZE.x * (minf(ghost, 1.0) - ratio)
		draw_rect(Rect2(origin + Vector2(filled, 0.0), Vector2(lost, BAR_SIZE.y)),
			Color(BAR_EDGE, 0.30))
		draw_rect(Rect2(origin + Vector2(filled + lost - 1.0, 2.0), Vector2(1.0, BAR_SIZE.y - 4.0)),
			Color(BAR_EDGE, 0.45))
	if filled > 2.0:
		_fill_box.bg_color = tone.lerp(Color(1.0, 0.85, 0.8), flash * 0.5)
		draw_style_box(_fill_box, Rect2(origin, Vector2(filled, BAR_SIZE.y)))
		draw_rect(Rect2(origin + Vector2(1.0, 1.0), Vector2(filled - 2.0, 1.0)),
			Color(BAR_EDGE, 0.65))
		draw_rect(Rect2(origin + Vector2(filled - 3.0, 2.0), Vector2(2.0, BAR_SIZE.y - 4.0)),
			Color(BAR_EDGE, 0.8))
	if _wreck:
		# an empty hull reads as a fault, not as a bar that happens to be short
		var stripe := 0.5 + 0.5 * sin(_time * 7.0)
		draw_rect(Rect2(origin, BAR_SIZE), Color(HULL_LOW, 0.18 + 0.18 * stripe))

func _draw_shield_glyph() -> void:
	var p := ICON_POS
	var s := ICON_SIZE
	var pts := PackedVector2Array([
		p + Vector2(s.x * 0.5, s.y * 0.04),
		p + Vector2(s.x * 0.96, s.y * 0.24),
		p + Vector2(s.x * 0.96, s.y * 0.55),
		p + Vector2(s.x * 0.5, s.y * 0.97),
		p + Vector2(s.x * 0.04, s.y * 0.55),
		p + Vector2(s.x * 0.04, s.y * 0.24),
	])
	draw_colored_polygon(pts, Color(0.06, 0.22, 0.28, 0.85))
	var closed := pts.duplicate()
	closed.append(pts[0])
	draw_polyline(closed, Color(ACCENT, 0.95), 1.5, true)
	draw_line(p + Vector2(s.x * 0.5, s.y * 0.26), p + Vector2(s.x * 0.5, s.y * 0.66),
		Color(ACCENT, 0.6), 1.5, true)

## Reactor core: the hull is what is left when the shield is gone.
func _draw_core_glyph() -> void:
	var c := ICON_POS + Vector2(0.0, BAR_STEP) + ICON_SIZE * 0.5
	var s := ICON_SIZE
	var pts := PackedVector2Array([
		c + Vector2(0.0, -s.y * 0.46),
		c + Vector2(s.x * 0.42, 0.0),
		c + Vector2(0.0, s.y * 0.46),
		c + Vector2(-s.x * 0.42, 0.0),
	])
	draw_colored_polygon(pts, Color(0.06, 0.22, 0.28, 0.85))
	var closed := pts.duplicate()
	closed.append(pts[0])
	draw_polyline(closed, Color(ACCENT, 0.95), 1.5, true)
	var live := 0.55 + 0.45 * sin(_time * 2.4)
	draw_colored_polygon(PackedVector2Array([
		c + Vector2(0.0, -s.y * 0.2),
		c + Vector2(s.x * 0.18, 0.0),
		c + Vector2(0.0, s.y * 0.2),
		c + Vector2(-s.x * 0.18, 0.0),
	]), Color(ACCENT, 0.35 + 0.4 * live * _hull))

func _draw_radar() -> void:
	var c := radar_center
	var r := radar_radius

	# only a needle: the reference keeps the dish unclouded
	draw_line(c, c + Vector2.from_angle(_sweep) * r, Color(ACCENT, 0.16), 1.0, true)

	draw_arc(c, r, 0.0, TAU, 128, Color(ACCENT, 0.08), 6.0, true)
	draw_arc(c, r, 0.0, TAU, 128, Color(ACCENT, 0.62), 2.0, true)
	draw_arc(c, r * 0.855, 0.0, TAU, 96, Color(ACCENT, 0.22), 1.0, true)
	draw_line(c - Vector2(r, 0.0), c + Vector2(r, 0.0), Color(ACCENT, 0.10), 1.0, true)
	draw_line(c - Vector2(0.0, r), c + Vector2(0.0, r), Color(ACCENT, 0.10), 1.0, true)

	for i in 8:
		var a := float(i) * TAU / 8.0 - PI * 0.5
		var major := i % 2 == 0
		var dir := Vector2.from_angle(a)
		var length := 6.0 if major else 3.0
		draw_line(c + dir * (r + 1.0), c + dir * (r + 1.0 + length),
			Color(ACCENT, 0.55 if major else 0.22), 1.0, true)

	_draw_contacts(c, r)

	if _pulse >= 0.0:
		draw_arc(c, lerpf(r * 0.15, r * 1.2, _pulse), 0.0, TAU, 96,
			Color(ACCENT, 0.5 * (1.0 - _pulse)), 2.0, true)

	_draw_own_marker(c)

## The last sweep's picture, re-projected every frame from the world positions it
## caught: contacts drift to the rim and fall off as the ship moves on. Each stone
## is drawn as its own collision silhouette at the dish's scale, so the radar is a
## wireframe of the near field rather than a swarm of identical dots.
func _draw_contacts(c: Vector2, r: float) -> void:
	if _ship == null:
		return
	var k := r / maxf(radar_range, 1.0)
	# world -> dish: the ship's own nose has to point up, so everything is turned
	# by the bearing of the ship plus a quarter turn
	var frame := -_ship.rotation - PI * 0.5
	for contact in _contacts:
		var local: Vector2 = (contact["at"] - _ship.global_position).rotated(frame)
		var dist := local.length()
		if dist > radar_range:
			continue
		var centre := c + local * k
		var tone: Color = CONTACT_HOT if contact["hot"] else CONTACT_COOL
		var fade := 0.5 + 0.5 * (1.0 - dist / radar_range)
		var blink := 0.75 + 0.25 * sin(_time * 2.2 + centre.x)
		var line := Color(tone, 0.85 * fade * blink)
		var drawn := false
		for piece in contact["shape"]:
			var poly: PackedVector2Array = piece
			if poly.size() < 3:
				continue
			drawn = true
			var ring := PackedVector2Array()
			for v in poly:
				ring.append(centre + (v * k).rotated(contact["rot"] + frame))
			ring.append(ring[0])
			draw_colored_polygon(ring, Color(tone, 0.07 * fade))
			draw_polyline(ring, line, 1.0, true)
		if not drawn:
			draw_rect(Rect2(centre - Vector2(1.0, 1.0), Vector2(2.0, 2.0)), line)

func _draw_own_marker(c: Vector2) -> void:
	var chevron := PackedVector2Array([
		c + Vector2(0.0, -9.0),
		c + Vector2(6.5, 6.0),
		c + Vector2(0.0, 2.5),
		c + Vector2(-6.5, 6.0),
	])
	var halo := 0.10 + 0.04 * sin(_time * 3.0)
	if _wreck:
		halo = 0.35
	for i in 3:
		var pts := PackedVector2Array()
		for v in chevron:
			pts.append(c + (v - c) * (1.0 + 0.25 * float(i + 1)))
		var tone := HULL_LOW if _wreck else Color(0.55, 0.95, 1.0)
		draw_colored_polygon(pts, Color(tone, halo * (1.0 - 0.25 * float(i))))
	draw_colored_polygon(chevron, Color(0.80, 0.98, 1.0, 0.95))
	draw_circle(c + Vector2(0.0, 3.0), 1.2, Color(0.9, 1.0, 1.0, 0.9))
