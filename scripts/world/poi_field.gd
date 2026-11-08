extends Node2D
class_name POIField

## The research objects of the endless space: rolled on a coarse lattice from
## the world's hash, built near the ship and freed far from it - the same
## streaming idea as the stone field, at a much coarser grain because there
## are far fewer of these.
##
## The roll depends only on the cell and the seed, so a wreck is in the same
## place every time the pilot comes back, and its research progress (kept by
## the desk under the stable id `poi:<cell>`) is still there.
##
## Story objects are placed by the mission through `add_story_poi()` and are
## never streamed out.

const GROUP := "poi_field"
const HASH := preload("res://scripts/space_background/space_hash.gd")

@export_range(1000.0, 20000.0, 100.0, "suffix:px") var cell_px: float = 3000.0
@export_range(0.0, 1.0, 0.01) var chance: float = 0.5
@export_range(1, 6) var build_radius_cells: int = 2
@export var seed_value: int = 20261108
## Cells around the start that stay empty, so the first view is not cluttered.
@export_range(0, 3) var quiet_start_cells: int = 0

signal poi_discovered(poi: ResearchPOI)

var _live: Dictionary = {}
var _story: Dictionary = {}
var _ship: Node2D = null
var _last_cell: Vector2i = Vector2i(999999, 999999)


func _ready() -> void:
	add_to_group(GROUP)
	call_deferred("_connect_scanner")
	_warm_textures()


## Ask for every research-object texture on a loader thread now, so the first
## wreck that streams in mid-flight does not stall a frame reading its PNG.
func _warm_textures() -> void:
	for kind_id in POICatalog.KINDS:
		for name in POICatalog.kind(kind_id).get("textures", []):
			var path := POICatalog.texture_path(str(name))
			if ResourceLoader.exists(path):
				ResourceLoader.load_threaded_request(path)


func _connect_scanner() -> void:
	var scanner := get_tree().get_first_node_in_group("scanner")
	if scanner == null:
		var ship := _find_ship()
		if ship != null:
			scanner = ship.get_node_or_null("Systems/Scanner")
	if scanner != null and scanner.has_signal("contact_found"):
		scanner.connect("contact_found", _on_contact_found)


func _physics_process(_delta: float) -> void:
	var ship := _find_ship()
	if ship == null:
		return
	var cell := Vector2i(floori(ship.global_position.x / cell_px), floori(ship.global_position.y / cell_px))
	if cell == _last_cell:
		return
	_last_cell = cell
	_stream(cell)


func _stream(center: Vector2i) -> void:
	var r := build_radius_cells
	for y in range(center.y - r, center.y + r + 1):
		for x in range(center.x - r, center.x + r + 1):
			var key := Vector2i(x, y)
			if _live.has(key):
				continue
			var poi := _roll(key)
			if poi != null:
				add_child(poi)
			_live[key] = poi
	for key in _live.keys():
		var k: Vector2i = key
		if absi(k.x - center.x) > r + 1 or absi(k.y - center.y) > r + 1:
			var node: Node = _live[key]
			if node != null and is_instance_valid(node):
				node.queue_free()
			_live.erase(key)


## The object a cell holds, or null. Pure function of the cell and the seed.
func _roll(key: Vector2i) -> ResearchPOI:
	if absi(key.x) <= quiet_start_cells and absi(key.y) <= quiet_start_cells:
		return null
	if HASH.hashf(key.x, key.y, 7101, seed_value) >= chance:
		return null
	var at := Vector2((float(key.x) + 0.2 + 0.6 * HASH.hashf(key.x, key.y, 7102, seed_value)) * cell_px,
		(float(key.y) + 0.2 + 0.6 * HASH.hashf(key.x, key.y, 7103, seed_value)) * cell_px)
	var depth := clampf(at.dot(ThreatAttention.DEPTH_AXIS) / 16000.0, 0.0, 1.0)
	var kind := _pick_kind(HASH.hashf(key.x, key.y, 7104, seed_value), depth)
	var variant := int(HASH.hashf(key.x, key.y, 7105, seed_value) * 97.0)
	var poi := ResearchPOI.new()
	poi.setup("%d,%d" % [key.x, key.y], kind, variant)
	poi.position = at
	return poi


func _pick_kind(roll: float, depth: float) -> String:
	var total := 0.0
	var weights: Array[float] = []
	for k in POICatalog.FIELD_KINDS:
		var w := float(POICatalog.kind(k).get("weight", 1.0))
		if POICatalog.DEEP_KINDS.has(k):
			w *= 1.0 + depth * 3.0
		weights.append(w)
		total += w
	var pick := roll * total
	for i in weights.size():
		pick -= weights[i]
		if pick <= 0.0:
			return POICatalog.FIELD_KINDS[i]
	return POICatalog.FIELD_KINDS[0]


## Place a story object. Returns the node; calling twice with the same id
## returns the one already placed.
func add_story_poi(id: String, kind: String, at: Vector2) -> ResearchPOI:
	if _story.has(id) and is_instance_valid(_story[id]):
		return _story[id]
	var poi := ResearchPOI.new()
	poi.setup(id, kind, 0, true)
	poi.position = at
	add_child(poi)
	_story[id] = poi
	return poi


func story_poi(id: String) -> ResearchPOI:
	var node: Variant = _story.get(id)
	return node if node != null and is_instance_valid(node) else null


## Every object currently built (field and story).
func live_pois() -> Array:
	var out: Array = []
	for child in get_children():
		if child is ResearchPOI:
			out.append(child)
	return out


## The object with this subject id ("poi:<id>"), or null.
func poi_for_subject(subject_id: String) -> ResearchPOI:
	for child in get_children():
		if child is ResearchPOI and (child as ResearchPOI).subject_id() == subject_id:
			return child
	return null


func _on_contact_found(contact: Dictionary) -> void:
	var id := str(contact.get("id", ""))
	if not id.begins_with("poi:"):
		return
	var poi := poi_for_subject(id)
	if poi == null or poi.is_discovered():
		return
	poi.mark_discovered()
	poi_discovered.emit(poi)


func _find_ship() -> Node2D:
	if _ship == null or not is_instance_valid(_ship):
		_ship = GameNodes.ship(get_tree())
	return _ship
