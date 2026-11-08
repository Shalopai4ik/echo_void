extends Node2D
class_name ResearchPOI

## One object worth studying: a wreck, a crystal, a sphere, a beacon.
##
## It speaks to the existing survey chain without a new interface:
##
##   * it joins `scan_target` and `poi_<kind>`, so the survey scanner finds it
##     and the scanner profile names it (signature `poi_<kind>`);
##   * its `chunk_id`/`item_id` metas give it a stable contact id
##     (`poi:<poi_id>`), so the research desk remembers it across streaming;
##   * `world_object_info()` carries its title, description and kind.
##
## What studying it gives back is read by `ResearchRewards` from the catalogue,
## not from here. The node only shows its state: unknown, found, being
## studied, studied.

const GROUP := "poi"
const SCAN_GROUP := "scan_target"
## How close the hull must be for the object to show its name.
const LABEL_RANGE := 1500.0

var poi_id: String = ""
var poi_kind: String = "wreck_fragment"
var title: String = ""
var description: String = ""
var texture_name: String = ""
var sprite_scale: float = 1.0
var glow: Color = Color(0.4, 0.8, 1.0)
## Story objects are placed by the mission and never streamed out.
var is_story: bool = false

var _sprite: Sprite2D
var _discovered: bool = false
var _time: float = 0.0
var _spin: float = 0.0
var _desk: Node = null
var _done_cache: bool = false
var _progress: float = -1.0
var _check_in: float = 0.0
var _ship_near: bool = false


func setup(id: String, kind_id: String, variant: int, story: bool = false) -> void:
	poi_id = id
	poi_kind = kind_id
	is_story = story
	var kind := POICatalog.kind(kind_id)
	title = str(kind.get("title", "ОБЪЕКТ"))
	var descriptions: Array = kind.get("descriptions", [""])
	description = str(descriptions[variant % descriptions.size()]) if not descriptions.is_empty() else ""
	var textures: Array = kind.get("textures", [])
	if not textures.is_empty():
		texture_name = str(textures[variant % textures.size()])
	sprite_scale = float(kind.get("scale", 1.0))
	glow = kind.get("glow", glow)
	_spin = (float(variant % 7) - 3.0) * 0.012


func _ready() -> void:
	add_to_group(GROUP)
	add_to_group(SCAN_GROUP)
	add_to_group("poi_%s" % poi_kind)
	set_meta("chunk_id", "poi")
	set_meta("item_id", poi_id)
	z_index = -2
	_sprite = Sprite2D.new()
	var tex := load(POICatalog.texture_path(texture_name)) as Texture2D
	_sprite.texture = tex
	_sprite.scale = Vector2.ONE * sprite_scale
	_sprite.rotation = float(hash(poi_id) % 628) / 100.0
	_sprite.modulate = Color(0.78, 0.82, 0.88)
	add_child(_sprite)


## The contact id the scanner and the desk know this object by.
func subject_id() -> String:
	return "poi:%s" % poi_id


func world_object_info() -> Dictionary:
	return {
		"title": title,
		"description": description,
		"poi_kind": poi_kind,
		"poi_id": poi_id,
	}


func mark_discovered() -> void:
	_discovered = true


func is_discovered() -> bool:
	return _discovered


func is_studied() -> bool:
	return _done_cache


func _process(delta: float) -> void:
	_time += delta
	_sprite.rotation += _spin * delta
	_check_in -= delta
	if _check_in <= 0.0:
		_check_in = 0.25
		_refresh_state()
	# an object nobody has found yet draws nothing but its sprite
	if _discovered or is_story:
		queue_redraw()


func _refresh_state() -> void:
	var ship := GameNodes.ship(get_tree())
	_ship_near = ship != null and ship.global_position.distance_to(global_position) < LABEL_RANGE
	if _desk == null or not is_instance_valid(_desk):
		_desk = GameNodes.device(get_tree(), "Research")
	if _desk == null:
		return
	_done_cache = bool(_desk.call("is_completed", subject_id()))
	_progress = -1.0
	if _desk.has_method("current_subject") and str(_desk.call("current_subject")) == subject_id():
		_progress = float(_desk.call("progress"))
		_discovered = true
	if _done_cache:
		_discovered = true
		_sprite.modulate = Color(0.5, 0.55, 0.62)


func _draw() -> void:
	var tex_size := _sprite.texture.get_size() * sprite_scale if _sprite.texture != null else Vector2(200, 200)
	var r := maxf(tex_size.x, tex_size.y) * 0.5 + 30.0
	var pulse := 0.5 + 0.5 * sin(_time * 2.2)
	if is_story and not _done_cache:
		draw_circle(Vector2.ZERO, r * (0.9 + 0.1 * pulse), Color(glow.r, glow.g, glow.b, 0.05))
		draw_arc(Vector2.ZERO, r + 20.0 + pulse * 25.0, 0.0, TAU, 64, Color(glow.r, glow.g, glow.b, 0.35), 3.0)
	if not _discovered:
		return
	var col := Color(glow.r, glow.g, glow.b, 0.75) if not _done_cache else Color(0.5, 0.6, 0.65, 0.5)
	# corner brackets
	var b := r
	var l := r * 0.28
	for s in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
		var c := Vector2(b * s.x, b * s.y)
		draw_line(c, c - Vector2(l * s.x, 0), col, 3.0)
		draw_line(c, c - Vector2(0, l * s.y), col, 3.0)
	if _progress >= 0.0:
		draw_arc(Vector2.ZERO, r + 14.0, -PI * 0.5, -PI * 0.5 + TAU * _progress, 64,
			Color(0.5, 1.0, 0.8, 0.9), 6.0)
	if _ship_near or is_story:
		var font := ThemeDB.fallback_font
		var label := title if not _done_cache else "%s · ИЗУЧЕНО" % title
		draw_string(font, Vector2(-r, -r - 16.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 30, col)
