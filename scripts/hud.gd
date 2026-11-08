extends Control

## Flat diegetic-ish HUD: mission bullets, a telemetry block, long-range radar
## and the scanner prompt. Authored for a 960x540 viewport.
##
## The telemetry reads the ship. The radar does not: it holds the last picture
## the scanner took, so what the pilot flies at is what he paid for, and contacts
## slide off the edge as he flies away from them until he sweeps again.
##
## There is one hull, `ShipController`. It has no armour, so the glass shows what
## it does have - speed, mode, state, charge and the world around it - instead of
## full bars for a ship that cannot be hurt. The radar asks the world field for
## its bodies and draws each one's own collision silhouette.

const ACCENT := Color(0.20, 0.78, 0.94)
const ACCENT_BRIGHT := Color(0.62, 0.96, 1.0)
const PANEL_FILL := Color(0.008, 0.035, 0.055, 0.88)
const PANEL_EDGE := Color(0.12, 0.55, 0.68, 0.58)
const HULL_FILL := Color(0.14, 0.82, 0.94)
const ENERGY_FILL := Color(0.20, 0.62, 0.94)
const TEXT_DIM := Color(0.57, 0.76, 0.84, 0.92)
const TEXT_BRIGHT := Color(0.82, 0.95, 0.98, 1.0)
## Text drawn on a lit resource bar.
const BAR_INK := Color(0.01, 0.07, 0.11, 0.95)
const CONTACT_HOT := Color(0.85, 0.34, 0.28)
const CONTACT_COOL := Color(0.55, 0.90, 1.0)

const BULLET_X := 40.0
const BULLET_SIZE := 6.0
const BULLET_DROP := 8.0
const ROW_NAMES := ["MissionTitle", "Objective1", "Objective2", "Objective3"]
## Short captions under the four slot keys, in slot order.
const SLOT_NAMES := ["СКАН", "ИССЛ", "ЛОЖН", "ОГНИ"]

## The frame the glass was authored in. `canvas_items` stretch keeps every glyph
## and sprite at its authored proportion; with aspect `expand` the window only
## ever shows more than this on one axis - extra width on a 21:9 screen, extra
## height on a 5:4 one - instead of black bars. So a readout that hugs a corner
## is offset from DESIGN_SIZE and not pinned to an absolute pixel.
const DESIGN_SIZE := Vector2(960.0, 540.0)

## The current slice has no armour to show, so it shows what it does have: a
## telemetry block, bottom-left, out of the radar's way and clear of the scanner
## prompt in the other corner. The block is measured up from the bottom edge, not
## down from the top: its line count depends on what the hull can report, and a
## fixed first baseline would push the last line off a screen that has only the
## authored 540 px. The ability slot row owns the bottom-left corner, so the block
## stops above it - otherwise the two would be drawn through each other.
const TELEMETRY_X := 40.0
const TELEMETRY_BOTTOM := 96.0
const TELEMETRY_STEP := 15.0
const TELEMETRY_FONT_SIZE := 11
## Where the values start, so six readouts line up as a table. The authored lines
## are label + padding + value; the padding is what the draw splits on.
const TELEMETRY_VALUE_X := 96.0

## How often the world counters are re-read. `WorldField.stats()` builds a fresh
## dictionary per population, and the numbers move at streaming pace, not at frame
## pace - four samples a second is already faster than a pilot can read them.
const WORLD_SAMPLE_SECONDS := 0.25

## The group a modal panel joins while it is open. The radar sweep is a ship
## control too, so the glass asks before answering the scan key.
const MODAL_GROUP := "ui_modal"

## World pixels the radar disc covers. Measured off the reference: the dish spans
## a little over three ship lengths, so a stone on the glass is the size it really
## is next to the hull. A sweep catches a handful of rocks, not the whole belt.
@export var radar_center := Vector2(884.0, 454.0)
@export var radar_radius := 61.0
## How long a sweep's picture stays useful before it is simply stale.
@export var radar_range := 880.0

var _contacts: Array = []

var _ship: Node2D
## The ship's systems hub. Read for hull integrity and energy reserve.
var _systems: Node
## The world field that answers the radar and the world line of the telemetry.
var _world: Node2D
## Optional objective provider: a node in the "mission" group that answers
## `objective_lines() -> Array[String]` and may answer
## `objective_title() -> String`.
var _mission: Node
var _rows_visible := true
var _row_nodes: Array[Control] = []
var _row_texts: Array[String] = []

var _time := 0.0
var _sweep := 0.0
var _pulse := -1.0
var _rows: Array[float] = []

## Seconds since the world counters and the equipment list were last sampled.
var _world_clock := 0.0
## Whether the survey scanner is mounted. `status()` builds a dictionary, so the
## answer is cached on the world cadence instead of being asked every frame.
var _scanner_mounted := false
## The corner XP readout and the research desk feeding it. Found through the
## hull, the same way the telemetry finds `Systems`.
var _xp_badge: ResearchXpBadge
var _research: Node
## The slot registry: which device sits in each of the four slots and whether
## it is running. Found through its own group, like the world and the ship.
var _slots: EquipmentSlots
## The last slot readings, one dictionary per slot, in slot order.
var _slot_states: Array[Dictionary] = []
## The sector card's numbers, taken from the research desk.
var _sector: Dictionary = {}

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
var _phantoms: Array = []
var _flicker_left := 0.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_to_group("radar_overlay")
	add_to_group("hud_flicker")
	for row_name in ROW_NAMES:
		var row := get_node_or_null(row_name) as Control
		if row == null:
			continue
		_rows.append(row.position.y)
		_row_nodes.append(row)
		_row_texts.append((row as Label).text if row is Label else "")
	_xp_badge = get_node_or_null("XpBadge") as ResearchXpBadge
	_read_ship()
	_read_world()
	_scan()

## A contact with nothing behind it, put on the dish by the atmosphere for a
## few seconds: world position and seconds left.
func add_phantom(at: Vector2, seconds: float) -> void:
	_phantoms.append({"at": at, "left": seconds})


## The power bus stutters: the glass flickers for `seconds`.
func flicker(seconds: float) -> void:
	_flicker_left = maxf(_flicker_left, seconds)


func _process(delta: float) -> void:
	_time += delta
	if _flicker_left > 0.0:
		_flicker_left = maxf(_flicker_left - delta, 0.0)
		modulate.a = 1.0 if _flicker_left <= 0.0 else (0.25 if fmod(_time * 13.0, 1.0) < 0.35 else 0.9)
	for i in range(_phantoms.size() - 1, -1, -1):
		_phantoms[i]["left"] = float(_phantoms[i]["left"]) - delta
		if float(_phantoms[i]["left"]) <= 0.0:
			_phantoms.remove_at(i)
	_sweep = fmod(_sweep + delta * 0.9, TAU)
	if _pulse >= 0.0:
		_pulse += delta * 0.9
		if _pulse > 1.0:
			_pulse = -1.0
	if Input.is_action_just_pressed("scan") and not _modal_open():
		_pulse = 0.0
		_scan()
	_read_ship()
	# The ship's own numbers are cheap and change every physics frame; the world
	# counters and the equipment list rebuild dictionaries, so they are sampled on
	# their own cadence instead of once per frame.
	_world_clock += delta
	if _world_clock >= WORLD_SAMPLE_SECONDS:
		_world_clock = 0.0
		_read_world()
	queue_redraw()

# ------------------------------------------------------------------ live state

func _find_ship() -> void:
	if _ship == null or not is_instance_valid(_ship):
		_ship = get_tree().get_first_node_in_group("player")
	if _ship == null or not is_instance_valid(_ship):
		_ship = get_tree().get_first_node_in_group("ship")


func _find_world() -> void:
	if _world == null or not is_instance_valid(_world):
		_world = get_tree().get_first_node_in_group("world_field")


func _find_mission() -> void:
	if _mission == null or not is_instance_valid(_mission):
		_mission = get_tree().get_first_node_in_group("mission")


## The slot registry, found through the group it joins. A scene without one
## simply has no slots to draw.
func _find_slots() -> void:
	if _slots == null or not is_instance_valid(_slots):
		_slots = get_tree().get_first_node_in_group(EquipmentSlots.GROUP) as EquipmentSlots

## Pull the telemetry off the ship rather than tracking its signals: the HUD is a
## sibling under a CanvasLayer and would otherwise have to care about load order.
func _read_ship() -> void:
	_find_ship()
	_find_mission()
	if _research == null or not is_instance_valid(_research):
		_bind_research()
	if _ship != null and is_instance_valid(_ship):
		if _systems == null or not is_instance_valid(_systems):
			_systems = _ship.get_node_or_null("Systems")
	else:
		_systems = null

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

	_refresh_rows()


## The world counters and the mounted equipment. Both answer with freshly built
## dictionaries (`WorldField.stats()`, `ShipComponent.status()`), which is why they
## live on the slow cadence and not inside `_read_ship`.
func _read_world() -> void:
	_find_world()
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
	_scanner_mounted = _query_scanner_mounted()
	# The slots and the sector card are read on the same slow cadence: both are
	# built from dictionaries, and both move at the speed of a device changing
	# state, not at frame pace.
	_find_slots()
	_slot_states.clear()
	if _slots != null and is_instance_valid(_slots):
		_slot_states = _slots.slot_statuses()
	_sector = SectorObjective.build(_research)


## The objective rows are the current slice's authored mission text. There is no
## mission system yet and the glass does not pretend to have one - the rows come
## back the moment a provider (the "mission" group) shows up.
func _refresh_rows() -> void:
	var provider := _mission != null and is_instance_valid(_mission) \
		and _mission.has_method("objective_lines")
	var wanted := provider
	if provider:
		_apply_objectives()
	else:
		_restore_objectives()
	for row in _row_nodes:
		if row.visible != wanted:
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


## ------------------------------------------------------------------ research ---

## The corner badge reads the research desk itself, so a completed survey shows
## its reward in flight and a purchase shows its cost, with no second copy of the
## XP total anywhere. Found through the hull, connected once; a scene without a
## desk simply has no badge to feed.
func _bind_research() -> void:
	if _research != null and is_instance_valid(_research):
		return
	_research = null
	_find_ship()
	if _ship != null and is_instance_valid(_ship):
		_research = _ship.get_node_or_null("Systems/Research")
	if _research == null:
		return
	if _research.has_signal("xp_gained") and not _research.is_connected("xp_gained", _on_xp_gained):
		_research.xp_gained.connect(_on_xp_gained)
	if _research.has_signal("xp_spent") and not _research.is_connected("xp_spent", _on_xp_spent):
		_research.xp_spent.connect(_on_xp_spent)
	if _xp_badge != null and _research.has_method("get_xp"):
		_xp_badge.set_value(int(_research.get_xp()), false)


func _on_xp_gained(_amount: int, total: int) -> void:
	if _xp_badge != null:
		_xp_badge.set_value(total)


func _on_xp_spent(amount: int, total: int) -> void:
	if _xp_badge == null:
		return
	_xp_badge.set_value(total, false)
	_xp_badge.flash_spend(amount)


## Whether an interface panel has the keys. Only asked when the scan key is
## pressed, so the group lookup never runs on a frame that does not need it.
func _modal_open() -> bool:
	return not get_tree().get_nodes_in_group(MODAL_GROUP).is_empty()


func _scan() -> void:
	_find_ship()
	_find_world()
	_contacts.clear()
	if _ship == null:
		return
	if _world != null and is_instance_valid(_world) and _world.has_method("bodies"):
		_contacts = _world_contacts()
		_mark_solid()


## The world's stones: a world position, the body's own turn and the collision
## silhouette, so the dish draws the rock at its true proportion and not as a dot
## that says nothing about size.
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
	_draw_ship_status()
	_draw_objective_panel()
	_draw_telemetry()
	_draw_ability_slots()
	_draw_bullets()
	_draw_radar()


## Top-left ship status: the hull silhouette and two live resource bars.
func _draw_ship_status() -> void:
	var font := get_theme_default_font()
	if font == null:
		return
	var icon_center := Vector2(37.0, 42.0)
	draw_circle(icon_center, 26.0, Color(0.01, 0.12, 0.19, 0.82))
	draw_arc(icon_center, 26.0, 0.0, TAU, 64, ACCENT, 1.5, true)
	draw_arc(icon_center, 21.0, -PI * 0.85, PI * 0.85, 48, Color(ACCENT, 0.24), 1.0, true)

	# Compact cruiser silhouette, deliberately schematic rather than a texture.
	var hull := PackedVector2Array([
		Vector2(37.0, 19.0), Vector2(42.0, 35.0), Vector2(45.0, 53.0),
		Vector2(39.0, 58.0), Vector2(35.0, 50.0), Vector2(29.0, 58.0),
		Vector2(32.0, 35.0),
	])
	draw_colored_polygon(hull, Color(ACCENT_BRIGHT, 0.92))
	draw_line(Vector2(37.0, 20.0), Vector2(37.0, 55.0), Color(0.75, 0.96, 1.0, 0.9), 1.0, true)

	var hull_ratio := _ship_hull_ratio()
	var energy_ratio := _ship_energy_ratio()
	_draw_resource_bar(Rect2(88.0, 24.0, 148.0, 13.0), hull_ratio, HULL_FILL)
	_draw_resource_bar(Rect2(88.0, 45.0, 148.0, 13.0), energy_ratio, ENERGY_FILL)
	draw_string(font, Vector2(95.0, 35.0), "КОРПУС", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 9, BAR_INK if hull_ratio > 0.12 else TEXT_BRIGHT)
	draw_string(font, Vector2(95.0, 56.0), "ЭНЕРГИЯ", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 9, BAR_INK if energy_ratio > 0.15 else TEXT_BRIGHT)
	# the figure sits at the bar's right end: dark when the fill reaches under
	# it, light on the empty track, so it reads at any level
	draw_string(font, Vector2(207.0, 35.0), "%d%%" % roundi(hull_ratio * 100.0), HORIZONTAL_ALIGNMENT_RIGHT, 24.0, 9, _on_fill(hull_ratio))
	draw_string(font, Vector2(207.0, 56.0), "%d%%" % roundi(energy_ratio * 100.0), HORIZONTAL_ALIGNMENT_RIGHT, 24.0, 9, _on_fill(energy_ratio))


func _draw_resource_bar(rect: Rect2, ratio: float, fill: Color) -> void:
	draw_rect(rect, Color(0.01, 0.06, 0.10, 0.88), true)
	draw_rect(Rect2(rect.position + Vector2(1.0, 1.0), Vector2(maxf((rect.size.x - 2.0) * ratio, 0.0), rect.size.y - 2.0)), fill, true)
	var outline := PackedVector2Array([
		rect.position + Vector2(7.0, 0.0), rect.position + Vector2(rect.size.x, 0.0),
		rect.position + rect.size, rect.position + Vector2(0.0, rect.size.y),
		rect.position + Vector2(0.0, 7.0), rect.position,
	])
	draw_polyline(outline, Color(ACCENT, 0.78), 1.0, true)


func _ship_hull_ratio() -> float:
	if _systems != null and is_instance_valid(_systems) and _systems.has_method("hull_ratio"):
		return clampf(float(_systems.hull_ratio()), 0.0, 1.0)
	return 1.0


func _ship_energy_ratio() -> float:
	if _systems != null and is_instance_valid(_systems) and _systems.has_method("energy_ratio"):
		return clampf(float(_systems.energy_ratio()), 0.0, 1.0)
	return 1.0


## Top-right mission panel. It mirrors the reference's compact objective card.
##
## The card used to be a painted "0 / 1". It is not painted any more: the
## numbers come from the research desk, so the card says how many subjects the
## desk has seen and how many it has finished, and the goal is one studied
## object. The desk is the only source - there is no second counter here.
func _draw_objective_panel() -> void:
	var font := get_theme_default_font()
	if font == null:
		return
	var right := size.x - 18.0
	# 176 wide because the title measures 126 px at size 10 and starts 34 px in:
	# at the old 154 the word ran out over the border.
	var rect := Rect2(right - 196.0, 18.0, 196.0, 48.0)
	_draw_chamfered_panel(rect, 9.0)
	var icon := rect.position + Vector2(18.0, 24.0)
	draw_polyline(PackedVector2Array([icon + Vector2(0.0, -7.0), icon + Vector2(7.0, 0.0), icon + Vector2(0.0, 7.0), icon + Vector2(-7.0, 0.0), icon + Vector2(0.0, -7.0)]), ACCENT_BRIGHT, 1.0, true)
	var heading := "ИССЛЕДОВАТЬ СЕКТОР"
	var value := str(_sector.get("value_text", "0 / 1"))
	var state_text := str(_sector.get("state_text", "НЕ НАЧАТО"))
	# With the storyline running, the card names the chapter and counts every
	# object the desk has finished - the same desk entries, a longer goal.
	if _mission != null and is_instance_valid(_mission) and _mission.has_method("chapter_title"):
		heading = str(_mission.call("chapter_title"))
		value = "ИЗУЧЕНО: %d" % int(_sector.get("completed", 0))
		state_text = "В ПРОЦЕССЕ" if int(_sector.get("state", 0)) != SectorObjective.State.IDLE else "НЕ НАЧАТО"
	draw_string(font, rect.position + Vector2(34.0, 21.0), heading,
		HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 40.0, 10, TEXT_BRIGHT)
	var tone := TEXT_DIM
	match int(_sector.get("state", SectorObjective.State.IDLE)):
		SectorObjective.State.DONE:
			tone = ACCENT_BRIGHT
		SectorObjective.State.ACTIVE:
			tone = ACCENT
	draw_string(font, rect.position + Vector2(34.0, 37.0), "%s · %s" % [value, state_text],
		HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 44.0, 11, tone)


## Bottom-left equipment slots. The first four controls mirror the reference's
## compact module row. What each row shows is the slot registry's own reading:
## a lit icon for a device that is running, a dim one for a device that is
## mounted and off, and a faint one for an empty slot.
func _draw_ability_slots() -> void:
	var font := get_theme_default_font()
	if font == null:
		return
	var y := size.y - 78.0
	for i in 4:
		var rect := Rect2(24.0 + float(i) * 43.0, y, 38.0, 38.0)
		_draw_chamfered_panel(rect, 6.0, Color(0.01, 0.10, 0.16, 0.82), Color(ACCENT, 0.80))
		var state := _slot_state(i)
		var mounted := not bool(state.get("empty", true))
		var active := bool(state.get("enabled", false))
		_draw_slot_icon(rect.get_center(), i, active, mounted)
		# a trigger device shows its rack and its cooldown on the key itself
		var cool := float(state.get("cooldown_remaining", 0.0))
		if cool > 0.05:
			var shade := Rect2(rect.position + Vector2(2.0, 2.0), Vector2(rect.size.x - 4.0, rect.size.y - 4.0))
			draw_rect(shade, Color(0.0, 0.0, 0.0, 0.55))
			draw_string(font, rect.get_center() + Vector2(-rect.size.x * 0.5, 4.0), "%d" % ceili(cool),
				HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, 11, TEXT_BRIGHT)
		var charges := int(state.get("charges", -1))
		if charges >= 0:
			var tone := TEXT_BRIGHT if charges > 0 else CONTACT_HOT
			draw_string(font, rect.position + Vector2(rect.size.x - 13.0, 10.0), str(charges),
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, 9, tone)
		draw_string(font, rect.position + Vector2(0.0, rect.size.y + 12.0), "%d %s" % [i + 1, SLOT_NAMES[i]],
			HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, 8, TEXT_DIM)


## One slot's last reading. A slot the registry does not know about reads as
## empty rather than as an error.
func _slot_state(index: int) -> Dictionary:
	if index < 0 or index >= _slot_states.size():
		return {}
	return _slot_states[index]


## Ask the systems hub once whether the survey scanner is on the hull. Split from
## the cached answer because `status()` builds a fresh dictionary for every call.
func _query_scanner_mounted() -> bool:
	if _systems == null or not is_instance_valid(_systems) or not _systems.has_method("equipment_status"):
		return false
	return not (_systems.equipment_status("scanner") as Dictionary).is_empty()


## The slot row's four icons. A running device is bright, a mounted device that
## is off is dim, and an empty slot is barely there - the pilot can see at a
## glance which of the four keys has something behind it.
func _draw_slot_icon(center: Vector2, index: int, active: bool, mounted: bool = true) -> void:
	var tone := ACCENT_BRIGHT if active else (Color(ACCENT, 0.72) if mounted else Color(ACCENT, 0.28))
	match index:
		0:
			draw_polyline(PackedVector2Array([center + Vector2(0.0, -10.0), center + Vector2(8.0, -5.0), center + Vector2(0.0, 10.0), center + Vector2(-8.0, -5.0), center + Vector2(0.0, -10.0)]), tone, 1.0, true)
		1:
			draw_arc(center, 9.0, 0.0, TAU, 40, tone, 1.0, true)
			draw_line(center - Vector2(12.0, 0.0), center + Vector2(12.0, 0.0), tone, 1.0, true)
			draw_line(center - Vector2(0.0, 12.0), center + Vector2(0.0, -12.0), tone, 1.0, true)
		2:
			draw_polyline(PackedVector2Array([center + Vector2(2.0, -11.0), center + Vector2(-6.0, 1.0), center + Vector2(0.0, 1.0), center + Vector2(-2.0, 11.0), center + Vector2(7.0, -2.0), center + Vector2(1.0, -2.0), center + Vector2(2.0, -11.0)]), tone, 1.0, true)
		3:
			for i in 3:
				# Box-local, like every other slot: `center` is already the anchor.
				var yy := -8.0 + float(i) * 7.0
				draw_line(center + Vector2(-9.0, yy), center + Vector2(9.0, yy), tone, 1.0, true)


func _draw_chamfered_panel(rect: Rect2, cut: float, fill: Color = PANEL_FILL, edge: Color = PANEL_EDGE) -> void:
	var p := rect.position
	var s := rect.size
	var outline := PackedVector2Array([
		p + Vector2(cut, 0.0), p + Vector2(s.x - cut, 0.0), p + Vector2(s.x, cut),
		p + Vector2(s.x, s.y - cut), p + Vector2(s.x - cut, s.y), p + Vector2(cut, s.y),
		p + Vector2(0.0, s.y - cut), p + Vector2(0.0, cut),
	])
	draw_colored_polygon(outline, fill)
	var border := outline.duplicate()
	border.append(border[0])
	draw_polyline(border, edge, 1.0, true)


## What a hull without armour can still be honest about: how fast it is going,
## what it is doing, how much boost is left and how much world is around it.
func _draw_telemetry() -> void:
	var lines := flight_lines()
	if lines.is_empty():
		return
	var font := get_theme_default_font()
	if font == null:
		return
	var origin := telemetry_origin(lines.size())
	var y := origin.y
	for line in lines:
		var parts := _split_readout(line)
		draw_string(font, Vector2(origin.x, y), parts[0],
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, TELEMETRY_FONT_SIZE, TEXT_DIM)
		if not parts[1].is_empty():
			draw_string(font, Vector2(origin.x + TELEMETRY_VALUE_X, y), parts[1],
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, TELEMETRY_FONT_SIZE,
				Color(0.82, 0.95, 0.98, 0.95))
		y += TELEMETRY_STEP


## Label and value of one readout. The authored line pads the value with spaces;
## drawing both halves at fixed columns turns that padding into a real table
## instead of a ragged one, and leaves `telemetry_lines()` unchanged for readers.
func _split_readout(line: String) -> PackedStringArray:
	var cut := line.find("  ")
	if cut < 0:
		return PackedStringArray([line, ""])
	return PackedStringArray([line.substr(0, cut), line.substr(cut).strip_edges()])


## The readouts themselves, as lines - the drawing above and any test read the
## same list, so what the glass says and what the glass shows cannot drift apart.
func telemetry_lines() -> Array[String]:
	if _telemetry_dirty:
		_telemetry_cache.clear()
		if _ship == null or not is_instance_valid(_ship):
			_telemetry_dirty = false
			return _telemetry_cache
		if _ship.has_method("speed"):
			_telemetry_cache.append("СКОРОСТЬ   %d м/с" % roundi(_cached_speed / 10.0))
		if _ship.has_method("mode_name"):
			_telemetry_cache.append("РЕЖИМ      %s" % _cached_mode)
		if _ship.has_method("state_name"):
			_telemetry_cache.append("СОСТОЯНИЕ  %s" % _cached_state)
		var boost_obj: Variant = _ship.get("boost")
		if boost_obj != null and boost_obj.has_method("percent"):
			_telemetry_cache.append("ФОРСАЖ     %d%%" % _cached_boost)
		if _world != null and is_instance_valid(_world) and _world.has_method("stats"):
			_telemetry_cache.append("МИР        %d тел / %d чанков" % [_cached_live, _cached_chunks])
			_telemetry_cache.append("ОБЪЕКТЫ    камни %d / обломки %d / декор %d" % [_cached_asteroids, _cached_debris, _cached_decor])
		_telemetry_dirty = false
	return _telemetry_cache


## What the glass believes it is attached to. A test reads this instead of
## guessing from the drawing.
func hud_state() -> Dictionary:
	return {
		"ship_bound": _ship != null and is_instance_valid(_ship),
		"contacts": _contacts.size(),
		"rows": _rows_visible,
		"telemetry": telemetry_lines(),
		"research_xp": _xp_badge.value() if _xp_badge != null else -1,
		"sector": _sector.duplicate(),
		"slots": _slot_states.duplicate(true),
	}

## First baseline of the telemetry block: the block hangs off the bottom edge by
## TELEMETRY_BOTTOM, so a hull that reports more lines grows upward and never
## draws its last line under the frame. `count` is passed in when the caller has
## already built the lines, so a frame does not format them twice.
func telemetry_origin(count: int = -1) -> Vector2:
	if count < 0:
		count = flight_lines().size()
	count = maxi(count, 1)
	return Vector2(TELEMETRY_X, size.y - TELEMETRY_BOTTOM - TELEMETRY_STEP * float(count - 1))


## How much more canvas the current window shows than the 960x540 the glass was
## authored in: zero in a 16:9 window, extra width on an ultrawide screen, extra
## height on a 5:4 one.
func hud_extra() -> Vector2:
	return Vector2(maxf(size.x - DESIGN_SIZE.x, 0.0), maxf(size.y - DESIGN_SIZE.y, 0.0))


## The radar's centre for this window. It sits 92 px below the top edge and 122 px
## in from the right one, so the dish has to ride the right edge when the viewport
## grows wider.
func radar_center_at() -> Vector2:
	return Vector2(
		size.x - (DESIGN_SIZE.x - radar_center.x),
		size.y - (DESIGN_SIZE.y - radar_center.y)
	)


## Corner-hugging geometry, for the display suite: the same numbers the drawing
## uses, without reading pixels back.
func hud_metrics() -> Dictionary:
	var lines := flight_lines()
	var origin := telemetry_origin(lines.size())
	return {
		"viewport": size,
		"extra": hud_extra(),
		"radar_center": radar_center_at(),
		"telemetry_origin": origin,
		"telemetry_bottom": origin.y + TELEMETRY_STEP * maxf(lines.size() - 1, 0),
	}


func _draw_bullets() -> void:
	if not _rows_visible:
		return
	# The first row is the block's own title; only the objectives get a bullet.
	for index in range(1, _rows.size()):
		var top: float = _rows[index]
		var r := Rect2(BULLET_X, top + BULLET_DROP, BULLET_SIZE, BULLET_SIZE)
		draw_rect(r, Color(ACCENT, 0.75))
		draw_rect(r.grow(1.5), Color(ACCENT, 0.12))
func _draw_radar() -> void:
	var c := radar_center_at()
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
	_draw_threats(c, r)

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
				# Keep radar contacts as crisp wireframes at the compact scale.
				pass
			var closed := clean.duplicate()
			closed.append(closed[0])
			draw_polyline(closed, line, 1.0, true)
		if not drawn:
			draw_rect(Rect2(centre - Vector2(1.0, 1.0), Vector2(2.0, 2.0)), line)

## What the dish cannot help seeing: the brood (red, pinned to the rim when
## they are past the dish's range), phantom blips the atmosphere put there, and
## - only with the threat-sense upgrade - the bearing of the thing itself.
func _draw_threats(c: Vector2, r: float) -> void:
	if _ship == null or not is_instance_valid(_ship):
		return
	var k := r / maxf(radar_range, 1.0)
	var frame := -_ship.rotation - PI * 0.5
	for node in get_tree().get_nodes_in_group(BroodHunter.GROUP):
		var hunter := node as Node2D
		if hunter == null:
			continue
		var local := (hunter.global_position - _ship.global_position).rotated(frame) * k
		var pinned := local.length() > r - 4.0
		if pinned:
			local = local.normalized() * (r - 4.0)
		var blink := 0.6 + 0.4 * sin(_time * 8.0)
		draw_circle(c + local, 3.0 if not pinned else 2.2, Color(1.0, 0.25, 0.2, blink))
	for ph in _phantoms:
		var local: Vector2 = (ph["at"] - _ship.global_position).rotated(frame) * k
		if local.length() > r:
			local = local.normalized() * (r - 4.0)
		var a := clampf(float(ph["left"]) / 4.0, 0.0, 1.0)
		draw_arc(c + local, 4.0, 0.0, TAU, 12, Color(1.0, 0.85, 0.6, 0.8 * a), 1.0, true)
	if _threat_sense():
		var lev := get_tree().get_first_node_in_group(Leviathan.GROUP) as Node2D
		if lev != null and lev.has_method("state") and int(lev.call("state")) != 0:
			var dir := (lev.global_position - _ship.global_position).rotated(frame).normalized()
			var p := c + dir * (r + 5.0)
			draw_colored_polygon(PackedVector2Array([p + dir * 7.0, p + dir.orthogonal() * 5.0,
				p - dir.orthogonal() * 5.0]), Color(1.0, 0.2, 0.15, 0.6 + 0.3 * sin(_time * 3.0)))


## The scanner's one-time threat-sense module, bought on the upgrades panel.
func _threat_sense() -> bool:
	if _systems == null or not is_instance_valid(_systems):
		return false
	var scanner := _systems.get_node_or_null("Scanner")
	if scanner == null:
		return false
	var v: Variant = scanner.get("threat_sense")
	return v != null and float(v) >= 0.5


func _draw_own_marker(c: Vector2) -> void:
	var chevron := PackedVector2Array([
		c + Vector2(0.0, -9.0),
		c + Vector2(6.5, 6.0),
		c + Vector2(0.0, 2.5),
		c + Vector2(-6.5, 6.0),
	])
	var halo := 0.10 + 0.04 * sin(_time * 3.0)
	for i in 3:
		var pts := PackedVector2Array()
		for v in chevron:
			pts.append(c + (v - c) * (1.0 + 0.25 * float(i + 1)))
		var tone := Color(0.55, 0.95, 1.0)
		draw_colored_polygon(pts, Color(tone, halo * (1.0 - 0.25 * float(i))))
	draw_colored_polygon(chevron, Color(0.80, 0.98, 1.0, 0.95))
	draw_circle(c + Vector2(0.0, 3.0), 1.2, Color(0.9, 1.0, 1.0, 0.9))


## The readouts the flight glass actually shows: the hull's own numbers. The
## world counters stay in `telemetry_lines()` for the debug overlay (F1) and
## the tests, and join the glass only while that overlay is up.
func flight_lines() -> Array[String]:
	var lines := telemetry_lines()
	if _debug_overlay_on():
		return lines
	var out: Array[String] = []
	for line in lines:
		if line.begins_with("МИР") or line.begins_with("ОБЪЕКТЫ"):
			continue
		out.append(line)
	return out


func _debug_overlay_on() -> bool:
	if _ship == null or not is_instance_valid(_ship):
		return false
	var dbg := _ship.get_node_or_null("FlightDebug") as CanvasItem
	return dbg != null and dbg.visible


## The colour for a bar's figure: dark ink over the fill, light over the track.
## The figure starts at x 207 on a bar that runs 89..235.
func _on_fill(ratio: float) -> Color:
	return BAR_INK if 89.0 + 146.0 * ratio > 214.0 else TEXT_DIM
