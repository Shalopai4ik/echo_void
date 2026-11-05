extends Control

## Flat diegetic-ish HUD: mission bullets, shield/hull bars with glyphs,
## long-range radar and the scanner prompt. Authored for a 960x540 viewport.
##
## The bars read the ship. The radar does not: it holds the last picture the
## scanner took, so what the pilot flies at is what he paid for, and contacts
## slide off the edge as he flies away from them until he sweeps again.
##
## One HUD, two hulls. The legacy hull carries armour and reports it through
## `shield_ratio()`, so it gets the bars and the glyphs. The current hull has no
## armour at all, and a glass that shows full bars for a ship that cannot be
## hurt is a lie - so the current slice gets a telemetry block instead, and the
## bars come back by themselves the day `ShipController` grows a shield. The
## radar works with either hull: the legacy field hands over its contacts, the
## current world field is asked for its bodies and they are dressed in the same
## shape.

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

## The current slice has no armour to show, so it shows what it does have: a
## telemetry block where the legacy bars sit, bottom-left, out of the radar's
## way and clear of the scanner prompt in the other corner.
const TELEMETRY_POS := Vector2(40.0, 452.0)
const TELEMETRY_STEP := 18.0
const TELEMETRY_FONT_SIZE := 14

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
## The current slice's world field. The legacy one is `_belt`; both answer the
## radar, each in its own way.
var _world: Node2D
## Optional objective provider: a node in the "mission" group that answers
## `objective_lines() -> Array[String]` and may answer
## `objective_title() -> String`.
var _mission: Node
## Which hull the glass is talking to: "legacy", "current" or "" before the
## first ship shows up.
var _slice := ""
var _armour := false
var _rows_visible := true
var _row_nodes: Array[Control] = []
var _row_texts: Array[String] = []

var _time := 0.0
var _sweep := 0.0
var _pulse := -1.0
var _rows: Array[float] = []
var _track_box := StyleBoxFlat.new()
var _fill_box := StyleBoxFlat.new()
var _glow_box := StyleBoxFlat.new()

## Cached telemetry to avoid rebuilding strings every frame
var _telemetry_cache: Array[String] = []
var _telemetry_dirty := true
var _cached_speed := -1
var _cached_mode := ""
var _cached_state := ""
var _cached_boost := -1
var _cached_live := -1
var _cached_chunks := -1
var _cached_asteroids := -1
var _cached_debris := -1
var _cached_decor := -1

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	for row_name in ROW_NAMES:
		var row := get_node_or_null(row_name) as Control
		if row == null:
			continue
		_rows.append(row.position.y)
		_row_nodes.append(row)
		_row_texts.append((row as Label).text if row is Label else "")
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
	if _ship == null or not is_instance_valid(_ship):
		_ship = get_tree().get_first_node_in_group("ship")


func _find_world() -> void:
	if _belt == null or not is_instance_valid(_belt):
		_belt = get_tree().get_first_node_in_group("asteroid_field")
	if _world == null or not is_instance_valid(_world):
		_world = get_tree().get_first_node_in_group("world_field")


func _find_mission() -> void:
	if _mission == null or not is_instance_valid(_mission):
		_mission = get_tree().get_first_node_in_group("mission")

## Pull the bars off the ship rather than tracking its signals: the HUD is a
## sibling under a CanvasLayer and would otherwise have to care about load order.
func _read_ship(delta: float) -> void:
	_find_ship()
	_find_world()
	_find_mission()
	_armour = _ship != null and _ship.has_method("shield_ratio")
	_slice = ""
	if _ship != null:
		_slice = "legacy" if _armour else "current"
	if _armour:
		_shield = _ship.shield_ratio()
		_hull = _ship.hull_ratio()
		_wreck = bool(_ship.get("destroyed"))
		if _hull < _last_hull - 0.001:
			_hurt = 1.0
		_last_hull = _hull
		_drain_shield(delta)
	
	## Mark telemetry dirty when ship/world values change
	if _ship != null and _ship.has_method("speed"):
		var spd := roundi(_ship.speed())
		if spd != _cached_speed:
			_cached_speed = spd
			_telemetry_dirty = true
	if _ship != null and _ship.has_method("mode_name"):
		var mode := str(_ship.mode_name())
		if mode != _cached_mode:
			_cached_mode = mode
			_telemetry_dirty = true
	if _ship != null and _ship.has_method("state_name"):
		var state := str(_ship.state_name())
		if state != _cached_state:
			_cached_state = state
			_telemetry_dirty = true
	var boost_obj: Variant = _ship.get("boost") if _ship != null else null
	if boost_obj != null and boost_obj.has_method("percent"):
		var bpct := roundi(boost_obj.percent())
		if bpct != _cached_boost:
			_cached_boost = bpct
			_telemetry_dirty = true
	
	## Check world stats
	if _world != null and is_instance_valid(_world) and _world.has_method("stats"):
		var stats: Dictionary = _world.stats()
		var live := int(stats.get("live", 0))
		var chunks := int(stats.get("chunks", 0))
		if live != _cached_live or chunks != _cached_chunks:
			_cached_live = live
			_cached_chunks = chunks
			_telemetry_dirty = true
		var categories: Dictionary = stats.get("categories", {})
		var kinds: Dictionary = stats.get("kinds", {})
		# The stones are counted by their plane rather than by their category: a
		# plane is what the pilot actually sees, and it goes on meaning "stones"
		# whether that population is solid or drawn on a far decorative plane.
		var ast := int(categories.get("asteroid", 0))
		var plane: Dictionary = kinds.get("asteroids", {})
		if plane.has("live"):
			ast = int(plane["live"])
		var deb := int(categories.get("debris", 0))
		var dec := int(categories.get("decorative", 0))
		if plane.has("solid") and not bool(plane["solid"]):
			# a decorative stone is already part of the decor figure; counting it
			# twice would make the panel look like it had found more world than it has
			dec = maxi(dec - ast, 0)
		if ast != _cached_asteroids or deb != _cached_debris or dec != _cached_decor:
			_cached_asteroids = ast
			_cached_debris = deb
			_cached_decor = dec
			_telemetry_dirty = true
	
	_refresh_rows()


## The objective rows are the legacy slice's authored mission text. The current
## slice has no mission system yet and does not pretend to have one - the rows
## come back the moment a provider (the "mission" group) shows up.
func _refresh_rows() -> void:
	var provider := _mission != null and is_instance_valid(_mission) \
		and _mission.has_method("objective_lines")
	var wanted := _slice != "current" or provider
	if provider:
		_apply_objectives()
	else:
		_restore_objectives()
	for row in _row_nodes:
		row.visible = wanted
	_rows_visible = wanted


func _apply_objectives() -> void:
	if _row_nodes.is_empty() or not _mission.has_method("objective_lines"):
		return
	if _mission.has_method("objective_title"):
		var title := _row_nodes[0] as Label
		if title != null:
			var want := str(_mission.objective_title())
			if title.text != want:
				title.text = want
	var lines: Array = _mission.objective_lines()
	for i in range(1, _row_nodes.size()):
		var label := _row_nodes[i] as Label
		if label == null:
			continue
		var want := str(lines[i - 1]) if i - 1 < lines.size() else ""
		if label.text != want:
			label.text = want


func _restore_objectives() -> void:
	for i in _row_nodes.size():
		if i >= _row_texts.size():
			break
		var label := _row_nodes[i] as Label
		if label != null and label.text != _row_texts[i]:
			label.text = _row_texts[i]


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
	_find_world()
	_contacts.clear()
	if _ship == null:
		return
	if _belt != null and is_instance_valid(_belt) and _belt.has_method("radar_contacts"):
		_contacts = _belt.radar_contacts(_ship.global_position, radar_range)
		_mark_solid()
		_swept = _time
		return
	if _world != null and is_instance_valid(_world) and _world.has_method("bodies"):
		_contacts = _world_contacts()
		_mark_solid()
		_swept = _time


## The current slice's stones, dressed in the same shape the legacy field hands
## over: a world position, the body's own turn and the collision silhouette, so
## the dish draws the rock at its true proportion and not as a dot that says
## nothing about size.
func _world_contacts() -> Array:
	var out: Array = []
	if _world == null or not _world.has_method("bodies"):
		return out
	for body in _world.bodies():
		if not is_instance_valid(body):
			continue
		var at: Vector2 = body.global_position
		if at.distance_to(_ship.global_position) > radar_range:
			continue
		var shape: Array = []
		var piece: Variant = body.get("piece")
		if piece is PackedVector2Array and (piece as PackedVector2Array).size() >= 3:
			shape.append(piece)
		var extent := 0.0
		var raw: Variant = body.get("extent")
		if raw != null:
			extent = float(raw)
		out.append({"at": at, "rot": body.global_rotation, "shape": shape,
			"hot": extent > 60.0})
	return out


## Whether a silhouette can be filled at all. A stone cut from the alpha of its
## own picture can come out with a doubled edge or a notch, and a fill that
## cannot be triangulated is an engine error, so the radar asks once per sweep
## and draws such a stone as an outline alone.
func _is_solid(shape: Variant) -> bool:
	if not shape is Array:
		return false
	for poly in (shape as Array):
		if not poly is PackedVector2Array:
			continue
		var clean := _clean_ring(poly as PackedVector2Array)
		if clean.size() >= 3 and not Geometry2D.triangulate_polygon(clean).is_empty():
			return true
	return false


## A polygon without doubled edges and without a doubled closing point: the
## shape the engine can actually fill.
func _clean_ring(points: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for v in points:
		if out.is_empty() or out[out.size() - 1].distance_squared_to(v) > 0.01:
			out.append(v)
	if out.size() >= 2 and out[0].distance_squared_to(out[out.size() - 1]) <= 0.01:
		out.remove_at(out.size() - 1)
	return out


func _mark_solid() -> void:
	for contact in _contacts:
		contact["solid"] = _is_solid(contact.get("shape", []))


## The picture currently on the glass, as the world positions the last sweep
## caught. A copy: the only way to change what the radar shows is to scan.
func contacts() -> Array:
	return _contacts.duplicate()

# ---------------------------------------------------------------------- drawing

func _draw() -> void:
	if _rows_visible:
		_draw_bullets()
	if _armour:
		_draw_bar(0, _shield_fill, BAR_FILL, _shield_ghost)
		_draw_shield_glyph()
		_draw_bar(1, _hull, HULL_LOW if _hull < 0.35 else HULL_FILL)
		_draw_core_glyph()
	else:
		_draw_telemetry()
	_draw_radar()


## What a hull without armour can still be honest about: how fast it is going,
## what it is doing, how much boost is left and how much world is around it.
func _draw_telemetry() -> void:
	var lines := telemetry_lines()
	if lines.is_empty():
		return
	var font := get_theme_default_font()
	if font == null:
		return
	var y := TELEMETRY_POS.y
	for line in lines:
		draw_string(font, Vector2(TELEMETRY_POS.x, y), line,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, TELEMETRY_FONT_SIZE,
			Color(0.66, 0.79, 0.84, 0.95))
		y += TELEMETRY_STEP


## The readouts themselves, as lines - the drawing above and any test read the
## same list, so what the glass says and what the glass shows cannot drift apart.
func telemetry_lines() -> Array[String]:
	if _telemetry_dirty:
		_telemetry_cache.clear()
		if _ship == null or not is_instance_valid(_ship):
			_telemetry_dirty = false
			return _telemetry_cache
		if _ship.has_method("speed"):
			_telemetry_cache.append("СКОРОСТЬ   %d px/s" % _cached_speed)
		if _ship.has_method("mode_name"):
			_telemetry_cache.append("РЕЖИМ      %s" % _cached_mode)
		if _ship.has_method("state_name"):
			_telemetry_cache.append("СОСТОЯНИЕ  %s" % _cached_state)
		var boost_obj: Variant = _ship.get("boost")
		if boost_obj != null and boost_obj.has_method("percent"):
			_telemetry_cache.append("ЗАРЯД      %d%%" % _cached_boost)
		if _world != null and is_instance_valid(_world) and _world.has_method("stats"):
			_telemetry_cache.append("МИР        %d тел / %d чанков" % [_cached_live, _cached_chunks])
			_telemetry_cache.append("ОБЪЕКТЫ    камни %d / обломки %d / декор %d" % [_cached_asteroids, _cached_debris, _cached_decor])
		_telemetry_dirty = false
	return _telemetry_cache


## What the glass believes it is attached to. A test reads this instead of
## guessing from the drawing.
func hud_state() -> Dictionary:
	return {
		"slice": _slice,
		"ship_bound": _ship != null and is_instance_valid(_ship),
		"armour": _armour,
		"contacts": _contacts.size(),
		"rows": _rows_visible,
		"telemetry": telemetry_lines(),
	}

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
		var solid := bool(contact.get("solid", true))
		for piece in contact["shape"]:
			var poly: PackedVector2Array = piece
			if poly.size() < 3:
				continue
			var ring := PackedVector2Array()
			for v in poly:
				ring.append(centre + (v * k).rotated(contact["rot"] + frame))
			var clean := _clean_ring(ring)
			if clean.size() < 3:
				continue
			drawn = true
			if solid:
				draw_colored_polygon(clean, Color(tone, 0.07 * fade))
			var closed := clean.duplicate()
			closed.append(closed[0])
			draw_polyline(closed, line, 1.0, true)
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
