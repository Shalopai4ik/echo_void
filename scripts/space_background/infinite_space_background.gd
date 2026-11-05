extends Node2D
class_name EchoSpaceBackground
## Infinite procedural space background.
##
## Drop the scene into any 2D game, point `asset_dir` at a folder of PNGs and it
## builds itself. There is no level: every band is an endless grid of logical
## cells that exist only while they cover the screen.
##
## Integration with a player controller is one optional line:
##     background.set_player_velocity(velocity)
## If nobody calls it the node looks for a Camera2D, then for a node in the
## "player" group with a `velocity` property, and otherwise drifts on
## `idle_drift`, so the sky is never frozen.

const LAYER_SCRIPT := preload("res://scripts/space_background/space_layer.gd")
const SPAWNER_SCRIPT := preload("res://scripts/space_background/space_spawner.gd")

enum DriveMode { AUTO, VELOCITY_ONLY, CAMERA_ONLY }

@export_group("Assets")
## res:// / user:// folder or any absolute path containing the PNGs.
@export var asset_dir: String = "res://assets/space_bg/"
@export var rescan_on_ready: bool = true

@export_group("Motion")
@export var drive_mode: DriveMode = DriveMode.AUTO
## Master multiplier for every band's parallax factor.
@export_range(0.0, 3.0, 0.01) var parallax_strength: float = 1.0
## Used when there is no camera and nobody calls set_player_velocity().
@export var idle_drift: Vector2 = Vector2(26, 0)
## 0 = instant. Higher is softer; the bands never separate because they all read
## the same smoothed point.
@export_range(0.0, 1.0, 0.01) var follow_smoothing: float = 0.0
@export var base_background_factor: float = 0.02
@export var far_nebula_factor: float = 0.055
@export var distant_stars_factor: float = 0.11
@export var stars_near_factor: float = 0.24

@export_group("Layers")
@export var show_base: bool = true
@export var show_nebula: bool = true
@export var show_distant_stars: bool = true
@export var show_midground: bool = true
@export var show_near_objects: bool = true
@export var show_anomalies: bool = true

@export_group("Look")
@export_range(0.0, 2.0, 0.01) var exposure: float = 1.0
## Dims the far bands so near rocks read against them.
@export_range(0.0, 1.0, 0.01) var depth_fade: float = 0.35
## Slow global breathing of the nebula light. 0 disables it.
@export_range(0.0, 1.0, 0.01) var nebula_breathing: float = 0.18

@export_group("Debug")
@export var print_report_on_ready: bool = false

signal assets_scanned(kind_counts: Dictionary)

var _spawner: EchoSpaceSpawner
var _bands: Array[EchoSpaceLayer] = []
var _band_names: Array[String] = []
var _band_by_name: Dictionary = {}
var _band_base_alpha: Dictionary = {}
var _travel := Vector2.ZERO
var _view_center := Vector2.ZERO
var _driven_externally := false
var _explicit_view := false
var _anchored := false
var _player: Node2D
var _time := 0.0
var _visible_cache := {}


func _ready() -> void:
	var authored := get_node_or_null("ProceduralSpawner")
	if authored is EchoSpaceSpawner:
		_spawner = authored
	else:
		_spawner = SPAWNER_SCRIPT.new()
		_spawner.name = "ProceduralSpawner"
		add_child(_spawner)
	if rescan_on_ready:
		rebuild()


# ------------------------------------------------------------------- public API

## The ship controller may call this every frame. Optional.
func set_player_velocity(velocity: Vector2) -> void:
	_driven_externally = true
	_explicit_view = false
	_travel += velocity * get_process_delta_time()


## Move the rig by an explicit view point, e.g. a virtual camera that is not a
## Camera2D node.
func set_view_center(position: Vector2) -> void:
	_driven_externally = true
	_explicit_view = true
	_travel = position


func set_seed(value: int) -> void:
	_spawner.set_seed(value)
	for band in _bands:
		band.set_seed(value)


func get_seed() -> int:
	return _spawner.world_seed


func spawner() -> EchoSpaceSpawner:
	return _spawner


func stats() -> Dictionary:
	var nodes := 0
	var chunks := 0
	for band in _bands:
		nodes += band.live_nodes()
		chunks += band.cell_count()
	return {"bands": _bands.size(), "nodes": nodes, "chunks": chunks, "seed": get_seed()}


## Extension point: give a band more textures (signal lights, beacons, wrecks)
## without touching this script. `band` is base / nebula / stars_far / stars /
## midground / near / anomaly.
func register_kind(band_name: String, textures: Array) -> void:
	if not _band_by_name.has(band_name):
		push_warning("unknown background band: " + band_name)
		return
	var band: EchoSpaceLayer = _band_by_name[band_name]
	for t in textures:
		if t != null and not band.textures.has(t):
			band.textures.append(t)
	band.set_seed(get_seed())


func rebuild() -> void:
	for band in _bands:
		band.queue_free()
	_bands.clear()
	_band_names.clear()
	_band_by_name.clear()
	_band_base_alpha.clear()
	_visible_cache.clear()
	var assets := _scan_assets()
	_build_bands(assets)
	var counts := {}
	for k in assets:
		if not assets[k].is_empty():
			counts[k] = assets[k].size()
	assets_scanned.emit(counts)
	if print_report_on_ready:
		print("InfiniteSpaceBackground bands=", _bands.size(), " assets=", counts, " stats=", stats())
		if not _cut.is_empty():
			print("  skipped ", _cut.size(), " canvas-cut sprites: ", ", ".join(_cut))


func _process(delta: float) -> void:
	_time += delta
	_sync_visibility()
	_sync_look()
	var raw := _resolve_view(delta)
	if follow_smoothing > 0.0:
		var k := clampf((1.0 - follow_smoothing) * 12.0 * delta, 0.0, 1.0)
		_view_center = _view_center.lerp(raw, k)
	else:
		_view_center = raw
	# Riding the view point is what turns a band's scroll_factor into the fraction
	# of the ship's motion it shows on screen. The canvas transform subtracts the
	# camera from every world position on its own, while the chunk offset below
	# only subtracts scroll_factor of it, so a root parked at the world origin
	# leaves (1 + scroll_factor) of the travel on every band: the sky sliding past
	# faster than a stone at rest, which is parallax running backwards.
	global_position = _view_center if _anchored else Vector2.ZERO
	var view := get_global_transform().affine_inverse().basis_xform(_view_center)
	var visible := _visible_rect_local()
	for band in _bands:
		if not band.visible:
			continue
		band.advance(view * parallax_strength, visible, delta)
	if nebula_breathing > 0.0:
		var wave := 1.0 - nebula_breathing * 0.5 * (1.0 + sin(_time * 0.19))
		for i in _band_names.size():
			if _band_names[i] == "nebula":
				_bands[i].modulate.a = clampf(_band_base_alpha[_band_names[i]] * wave, 0.0, 1.0)


# ------------------------------------------------------------------- view drive

## The point every band scrolls around, in world coordinates. It also decides
## whether the rig has to ride that point: a Camera2D takes the view point off
## the screen with its own transform, so the rig has to put it back, while a
## travel accumulator stands in for a game with no camera at all, where world and
## screen are the same thing and the offset must not be paid twice.
func _resolve_view(delta: float) -> Vector2:
	var cam: Camera2D = null
	if drive_mode == DriveMode.AUTO or drive_mode == DriveMode.CAMERA_ONLY:
		if not _driven_externally and is_inside_tree() and get_viewport() != null:
			cam = get_viewport().get_camera_2d()
	if cam != null:
		_anchored = true
		return cam.global_position
	if drive_mode == DriveMode.CAMERA_ONLY:
		_anchored = true
		return _view_center
	if not _driven_externally:
		_travel += _poll_velocity() * delta
	_anchored = _explicit_view
	return _travel


func _poll_velocity() -> Vector2:
	if _player == null or not is_instance_valid(_player):
		_player = null
		if is_inside_tree():
			var found := get_tree().get_first_node_in_group("player")
			if found is Node2D:
				_player = found
	if _player == null:
		return idle_drift
	var v = _player.get("velocity")
	if v is Vector2:
		return v
	return idle_drift


## The screen rectangle expressed in this node's own coordinates, so window
## resizing, camera zoom and a scaled background node are all handled.
func _visible_rect_local() -> Rect2:
	var vp := get_viewport()
	if vp == null:
		return Rect2(Vector2.ZERO, Vector2(960, 540))
	var size := vp.get_visible_rect().size
	var to_local := get_global_transform().affine_inverse() \
		* vp.get_canvas_transform().affine_inverse()
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in [Vector2.ZERO, Vector2(size.x, 0.0), Vector2(0.0, size.y), Vector2(size)]:
		var q: Vector2 = to_local * p
		lo = Vector2(minf(lo.x, q.x), minf(lo.y, q.y))
		hi = Vector2(maxf(hi.x, q.x), maxf(hi.y, q.y))
	return Rect2(lo, hi - lo)


var _look_cache := Vector3(-1, -1, -1)


## Cool colour grade of each band. Kept in one place so the inspector can retune
## the whole sky at runtime without rebuilding it.
func _tint_for(name: String) -> Color:
	var far := lerpf(1.0, 1.0 - depth_fade, 0.6)
	match name:
		"base":
			return Color(exposure * 0.62, exposure * 0.76, exposure * 0.88, 1.0)
		"base2":
			return Color(exposure * 0.24, exposure * 0.36, exposure * 0.44, 1.0)
		"nebula", "nebula_t":
			return Color(exposure * far, exposure * far, exposure * far, 1.0)
		"stars_far_t", "stars_near_t", "stars":
			return Color(exposure * 0.92, exposure * 0.96, exposure, 1.0)
		# Background objects, not light: they stay opaque and are pushed back by
		# their colour alone, so a stone never turns into a transparent pane.
		"midground":
			return Color(exposure * 0.30, exposure * 0.34, exposure * 0.43, 1.0)
		"near":
			return Color(exposure * 0.44, exposure * 0.48, exposure * 0.58, 1.0)
		"anomaly":
			return Color(exposure * 0.58, exposure * 0.62, exposure * 0.72, 1.0)
	return Color(exposure, exposure, exposure, 1.0)


## Re-applies exposure and depth fade when they are changed in the inspector.
func _sync_look() -> void:
	var now := Vector3(exposure, depth_fade, 0.0)
	if now == _look_cache:
		return
	_look_cache = now
	for i in _band_names.size():
		_bands[i].modulate = _tint_for(_band_names[i])


func _sync_visibility() -> void:
	var want := {
		"base": show_base, "base2": show_base,
		"nebula": show_nebula, "nebula_t": show_nebula,
		"stars_far_t": show_distant_stars, "stars_near_t": show_distant_stars,
		"stars": show_distant_stars,
		"midground": show_midground, "near": show_near_objects, "anomaly": show_anomalies,
	}
	for i in _band_names.size():
		var name: String = _band_names[i]
		if want.has(name) and _visible_cache.get(name) != want[name]:
			_visible_cache[name] = want[name]
			_bands[i].visible = want[name]


# ------------------------------------------------------------------ asset scan

func _scan_assets() -> Dictionary:
	var keys := ["tile_base", "tile_nebula", "tile_stars_far", "tile_stars_near",
				 "base", "background", "nebula", "puff", "stars_far", "stars_near",
				 "star", "asteroid", "debris", "planet", "atmosphere", "flare"]
	var found := {}
	for k in keys:
		found[k] = []
	var dir := asset_dir.replace("\\", "/")
	if not dir.ends_with("/"):
		dir += "/"
	_cut.clear()
	for rel in _list_images(dir):
		var tex := _load_texture(dir + rel)
		if tex == null:
			continue
		var key := _classify(rel.get_file().to_lower())
		if not found.has(key):
			continue
		# A sprite whose art runs to the edge of its crop was cut by the border of
		# the source frame. Scattered as a free object it paints a hard rectangle,
		# so it is not usable here. Tiles are the opposite case: they are meant to
		# run edge to edge, so they are never tested.
		if not key.begins_with("tile_") and _touches_border(tex):
			_cut.append(rel.get_file())
			continue
		found[key].append(tex)
	return found


var _cut: Array[String] = []


func _touches_border(tex: Texture2D) -> bool:
	var img := tex.get_image()
	if img == null:
		return false
	var w := img.get_width()
	var h := img.get_height()
	var hit := 0
	var total := 0
	for x in w:
		for y in [0, h - 1]:
			total += 1
			if img.get_pixel(x, y).a > 0.05:
				hit += 1
	for y in h:
		for x in [0, w - 1]:
			total += 1
			if img.get_pixel(x, y).a > 0.05:
				hit += 1
	return float(hit) / float(maxi(total, 1)) > 0.05


func _list_images(dir: String) -> Array:
	var out: Array = []
	var d := DirAccess.open(dir)
	if d == null:
		push_warning("background: cannot open " + dir)
		return out
	for f in d.get_files():
		if _is_image(f):
			out.append(f)
	for sub in ["sprites", "objects"]:
		var sd := DirAccess.open(dir + sub + "/")
		if sd == null:
			continue
		for f in sd.get_files():
			if _is_image(f):
				out.append(sub + "/" + f)
	out.sort()
	return out


func _is_image(f: String) -> bool:
	var lower := f.to_lower()
	return lower.ends_with(".png") or lower.ends_with(".svg") or lower.ends_with(".webp")


func _load_texture(path: String) -> Texture2D:
	if path.begins_with("res://") or path.begins_with("user://"):
		var tex := load(path) as Texture2D
		if tex != null:
			return tex
		# not imported yet (fresh drop into the folder): read the file directly
	var img := Image.load_from_file(path)
	if img == null or img.is_empty():
		return null
	return ImageTexture.create_from_image(img)


## Filename to role. "*_tile*" means "safe to repeat edge to edge", everything
## else is treated as a single decor object and gets scattered instead.
func _classify(name: String) -> String:
	var tile := name.contains("tile") and not name.contains("chunk")
	if tile:
		if name.contains("stars_far"):
			return "tile_stars_far"
		if name.contains("stars_near"):
			return "tile_stars_near"
		if name.contains("nebula"):
			return "tile_nebula"
		return "tile_base"
	if name.contains("atmosphere") or name.contains("glow"):
		return "atmosphere"
	if name.contains("planet"):
		return "planet"
	if name.contains("puff") or name.contains("cloud"):
		return "puff"
	if name.contains("nebula"):
		return "nebula"
	if name.contains("stars_far"):
		return "stars_far"
	if name.contains("stars_near"):
		return "stars_near"
	if name.contains("background"):
		return "background"
	if name.contains("base"):
		return "base"
	if name.contains("flare") or name.contains("streak"):
		return "flare"
	if name.contains("debris") or name.contains("wreck"):
		return "debris"
	if name.begins_with("star_"):
		return "star"
	if name.begins_with("asteroid") or name.begins_with("rock") or name.begins_with("ast_"):
		return "asteroid"
	return ""


# ---------------------------------------------------------------- band layout

func _build_bands(a: Dictionary) -> void:
	# ---- seamless tiled bands: these alone already cover the whole screen, so
	# an empty strip or a black edge is impossible even if every other band is off
	_band("base", "BaseBackground", _t(a, "tile_base", "base"), {
		"tiled": true, "scroll_factor": base_background_factor, "salt": 11,
		"max_nodes": 24, "margin": Vector2(200, 200),
	})
	_band("base2", "BaseBackgroundEcho", _t(a, "tile_base", "base"), {
		"tiled": true, "scroll_factor": base_background_factor * 1.9, "add_blend": true,
		"salt": 12, "max_nodes": 24, "margin": Vector2(200, 200),
	})
	_band("nebula_t", "NebulaField", _t(a, "tile_nebula", "nebula"), {
		"tiled": true, "scroll_factor": far_nebula_factor * 1.35, "add_blend": true,
		"salt": 13, "max_nodes": 24, "margin": Vector2(200, 200),
	})
	_band("stars_far_t", "DeepStars", _t(a, "tile_stars_far", "stars"), {
		"tiled": true, "scroll_factor": distant_stars_factor, "add_blend": true,
		"salt": 14, "max_nodes": 24, "margin": Vector2(200, 200),
	})
	_band("stars_near_t", "NearStars", _t(a, "tile_stars_near", "stars"), {
		"tiled": true, "scroll_factor": stars_near_factor, "add_blend": true,
		"salt": 15, "max_nodes": 24, "margin": Vector2(200, 200),
	})

	# ---- scattered authored chunks: same art, but placed and rotated at random,
	# which is what keeps the tiled bands above from reading as a repeating pattern
	_band("nebula", "FarNebulaLayer", _merge([a["nebula"], a["puff"], a["background"]], "nebula"), {
		"add_blend": true, "scroll_factor": far_nebula_factor, "salt": 21,
		"rotation_range": Vector2(-0.22, 0.22), "alpha_range": Vector2(0.55, 1.0),
		"size_range": Vector2(0.8, 1.5), "patch_block": 7, "patch_min": 0.10,
		"max_per_cell": 1,
	}, "nebula")

	_band("stars", "DistantStarsLayer", _merge([a["star"]], "star"), {
		"add_blend": true, "scroll_factor": stars_near_factor * 1.1, "salt": 37,
		"rotation_range": Vector2(0, TAU), "alpha_range": Vector2(0.35, 0.9),
		"patch_block": 6,
	}, "stars")

	_band("midground", "MidgroundLayer", _merge([_small(a["asteroid"], 96), a["debris"]], "rock"), {
		"scroll_factor": 0.42, "salt": 51, "max_per_cell": 2,
		"rotation_range": Vector2(0, TAU), "alpha_range": Vector2(1.0, 1.0),
		"patch_block": 5, "patch_min": 0.08,
	}, "midground")

	_band("near", "NearObjectsLayer", _big(a["asteroid"], 96), {
		"scroll_factor": 0.88, "salt": 67, "max_per_cell": 1,
		"rotation_range": Vector2(0, TAU), "alpha_range": Vector2(1.0, 1.0),
		"patch_block": 4, "patch_min": 0.05,
	}, "near")

	var anom := _merge([a["planet"], a["atmosphere"], a["flare"]], "")
	if not anom.is_empty():
		_band("anomaly", "AnomalyLayer", anom, {
			"scroll_factor": 0.30, "salt": 83, "max_per_cell": 1,
			"rotation_range": Vector2(-0.35, 0.35), "alpha_range": Vector2(1.0, 1.0),
			"drift_amp": 6.0, "size_range": Vector2(0.75, 1.5),
		}, "anomaly")

	_apply_budget()


## Tiled textures, with the scattered art of the same kind as a stand-in.
func _t(a: Dictionary, tile_key: String, fallback_kind: String) -> Array:
	if not a[tile_key].is_empty():
		return a[tile_key]
	var alt := "tile_" + tile_key
	for k in [tile_key, alt]:
		if a.has(k) and not a[k].is_empty():
			return a[k]
	return _fallback(fallback_kind)


func _band(name: String, node_name: String, textures: Array, base: Dictionary,
		  gen_key: String = "") -> void:
	_add_band(name, node_name, textures, base, gen_key)


func _add_band(name: String, node_name: String, textures: Array, base: Dictionary,
			   gen_key: String = "") -> void:
	var cfg := {}
	if gen_key != "":
		cfg = _spawner.params_for(gen_key)
	cfg.merge(base, true)
	cfg["textures"] = textures
	cfg["label"] = node_name
	if not cfg.has("seed"):
		cfg["seed"] = _spawner.world_seed
	var cell: Vector2 = cfg.get("cell_size", Vector2(512, 512))
	var scale: float = cfg.get("margin_scale", 1.5)
	if not base.has("margin"):
		cfg["margin"] = cell * scale
	cfg.erase("margin_scale")

	var node: EchoSpaceLayer = get_node_or_null(node_name) as EchoSpaceLayer
	if node == null:
		node = LAYER_SCRIPT.new()
		add_child(node)
	node.name = node_name
	node.setup(cfg)
	_bands.append(node)
	_band_names.append(name)
	_band_by_name[name] = node
	_band_base_alpha[name] = 1.0
	node.modulate = _tint_for(name)
	if textures.is_empty():
		node.visible = false


## Shared ceiling: scale the per-band caps down when the total exceeds it.
func _apply_budget() -> void:
	var total := 0
	for band in _bands:
		total += band.max_nodes
	var budget := _spawner.budget()
	if total <= budget or total == 0:
		return
	var k := float(budget) / float(total)
	for band in _bands:
		if not band.tiled:
			band.max_nodes = maxi(int(band.max_nodes * k), 4)


func _merge(lists: Array, fallback_kind: String) -> Array:
	var out: Array = []
	for l in lists:
		for x in l:
			out.append(x)
	if out.is_empty() and fallback_kind != "":
		return _fallback(fallback_kind)
	return out


func _small(list: Array, limit: float) -> Array:
	var out: Array = []
	for t in list:
		if maxf(t.get_width(), t.get_height()) <= limit:
			out.append(t)
	return out


func _big(list: Array, from: float) -> Array:
	var out: Array = []
	for t in list:
		if maxf(t.get_width(), t.get_height()) > from:
			out.append(t)
	return out


## Minimal stand-ins so the system still runs when art is missing. They stay dim
## and small on purpose: a placeholder must not become the look of the game.
func _fallback(kind: String) -> Array:
	match kind:
		"base":
			return [_make_solid(Color(0.012, 0.028, 0.045, 1.0), 512)]
		"nebula":
			return [_make_soft(Color(0.10, 0.34, 0.46, 0.55), 512)]
		"stars", "star":
			return [_make_dot(9), _make_dot(5)]
		"rock":
			return [_make_rock(32), _make_rock(20)]
	return []


func _make_solid(c: Color, s: int) -> Texture2D:
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	img.fill(c)
	return ImageTexture.create_from_image(img)


func _make_soft(c: Color, s: int) -> Texture2D:
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	var mid := Vector2(s, s) * 0.5
	for y in s:
		for x in s:
			var d := Vector2(x, y).distance_to(mid) / (s * 0.5)
			var a := clampf(1.0 - d, 0.0, 1.0)
			img.set_pixel(x, y, Color(c.r, c.g, c.b, c.a * a * a))
	return ImageTexture.create_from_image(img)


func _make_dot(s: int) -> Texture2D:
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var mid := Vector2(s, s) * 0.5 - Vector2(0.5, 0.5)
	for y in s:
		for x in s:
			var d := Vector2(x, y).distance_to(mid)
			img.set_pixel(x, y, Color(0.82, 0.92, 1.0, clampf(1.0 - d / (s * 0.5), 0.0, 1.0)))
	return ImageTexture.create_from_image(img)


func _make_rock(s: int) -> Texture2D:
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	var mid := Vector2(s, s) * 0.5
	for y in s:
		for x in s:
			var d := Vector2(x, y).distance_to(mid) / (s * 0.5)
			var lit := clampf(1.0 - absf(d - 0.78) * 5.0, 0.0, 1.0) if d > 0.55 else 0.0
			var a := 1.0 if d < 0.72 else clampf(1.0 - (d - 0.72) * 8.0, 0.0, 1.0)
			img.set_pixel(x, y, Color(0.035 + lit * 0.28, 0.06 + lit * 0.5, 0.085 + lit * 0.6, a))
	return ImageTexture.create_from_image(img)
