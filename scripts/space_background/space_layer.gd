extends Node2D
class_name EchoSpaceLayer
## One parallax band of the infinite background.
##
## The band is a grid of logical cells. A cell only exists while it overlaps the
## visible rectangle, so the node count is bounded by the screen size and never
## by how far the ship has flown. What a cell contains comes from hashing its
## integer cell coordinate together with the seed, which makes the world
## reproducible and independent of frame rate or the order cells are visited in.
##
## Node coordinates stay small on purpose: a chunk node sits at
## `cell * cell_size - scroll`, and `cell` is always a cell of the current
## window, so the value cannot drift with distance travelled.

const HASH := preload("res://scripts/space_background/space_hash.gd")

static var _mat_mix: CanvasItemMaterial
static var _mat_add: CanvasItemMaterial

var textures: Array[Texture2D] = []
var label := "layer"

var scroll_factor := 0.1        ## how much of the ship's travel this band shows
var cell_size := Vector2(512, 512)
var density := 0.6              ## chance a cell holds anything
var max_per_cell := 1
var cluster_chance := 0.0       ## chance a cell becomes a small cluster
var cluster_extra := 3
var jitter := 1.0               ## 0 = object sits dead centre of its cell
var size_range := Vector2(1.0, 1.0)
var rotation_range := Vector2(0.0, TAU)
var alpha_range := Vector2(1.0, 1.0)
var spin_range := Vector2(0.0, 0.0)      ## radians per second
var twinkle := 0.0                        ## 0 steady, 1 full blink
var drift_amp := 0.0                      ## px of scroll-driven wobble
var patch_block := 0                      ## 0 disables density modulation
var patch_min := 0.15

var add_blend := false
var tiled := false
var max_nodes := 160
var margin := Vector2(320, 320)

var _seed := 0
var _salt := 0
var _chunks: Dictionary = {}
var _chunk_pool: Array[Node2D] = []
var _sprite_pool: Array[Sprite2D] = []
var _scroll := Vector2.ZERO
var _ring := Rect2i()
var _has_ring := false
var _live_nodes := 0
var _time := 0.0


static func material_for(add: bool) -> CanvasItemMaterial:
	if add:
		if _mat_add == null:
			_mat_add = CanvasItemMaterial.new()
			_mat_add.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		return _mat_add
	if _mat_mix == null:
		_mat_mix = CanvasItemMaterial.new()
		_mat_mix.blend_mode = CanvasItemMaterial.BLEND_MODE_MIX
	return _mat_mix


func setup(cfg: Dictionary) -> void:
	textures.clear()
	for t in cfg.get("textures", []):
		if t is Texture2D:
			textures.append(t)
	label = cfg.get("label", label)
	scroll_factor = cfg.get("scroll_factor", scroll_factor)
	cell_size = cfg.get("cell_size", cell_size)
	density = cfg.get("density", density)
	max_per_cell = cfg.get("max_per_cell", max_per_cell)
	cluster_chance = cfg.get("cluster_chance", cluster_chance)
	cluster_extra = cfg.get("cluster_extra", cluster_extra)
	jitter = cfg.get("jitter", jitter)
	size_range = cfg.get("size_range", size_range)
	rotation_range = cfg.get("rotation_range", rotation_range)
	alpha_range = cfg.get("alpha_range", alpha_range)
	spin_range = cfg.get("spin_range", spin_range)
	twinkle = cfg.get("twinkle", twinkle)
	drift_amp = cfg.get("drift_amp", drift_amp)
	patch_block = cfg.get("patch_block", patch_block)
	patch_min = cfg.get("patch_min", patch_min)
	add_blend = cfg.get("add_blend", add_blend)
	tiled = cfg.get("tiled", tiled)
	max_nodes = cfg.get("max_nodes", max_nodes)
	margin = cfg.get("margin", margin)
	_seed = cfg.get("seed", _seed)
	_salt = cfg.get("salt", _salt)
	if tiled:
		density = 1.0
		max_per_cell = 1
		jitter = 0.0
		size_range = Vector2.ONE
		rotation_range = Vector2.ZERO
		alpha_range = Vector2.ONE
		spin_range = Vector2.ZERO
		twinkle = 0.0
		drift_amp = 0.0
		cluster_chance = 0.0
		if not textures.is_empty():
			cell_size = Vector2(textures[0].get_size())
	set_seed(_seed)
	_clear_cells()


func set_seed(value: int) -> void:
	_seed = value
	_clear_cells()


func live_nodes() -> int:
	return _live_nodes


func cell_count() -> int:
	return _chunks.size()


## Debug fingerprint: what this band holds right now, independent of when it got
## there. Two bands with the same seed and the same view point must match.
func signature() -> String:
	var cells := _chunks.keys()
	cells.sort()
	var parts: Array[String] = []
	for cell in cells:
		var chunk: Node2D = _chunks[cell]
		var items: Array[String] = []
		for sp in chunk.get_children():
			var sprite := sp as Sprite2D
			if sprite == null:
				continue
			var tid := sprite.texture.resource_path
			if tid == "":
				tid = "gen%dx%d" % [int(sprite.texture.get_width()), int(sprite.texture.get_height())]
			items.append("%s@%.2f,%.2f s%.3f r%.3f" % [
				tid.get_file(), sprite.position.x, sprite.position.y,
				sprite.scale.x, sprite.rotation])
		items.sort()
		parts.append("%d,%d:%s" % [cell.x, cell.y, "|".join(items)])
	return ";".join(parts)


## Called by the root node every frame it has to move.
func advance(view_center: Vector2, visible: Rect2, delta: float) -> void:
	if textures.is_empty():
		return
	var new_scroll := view_center * scroll_factor
	var scroll_changed := new_scroll != _scroll
	_scroll = new_scroll
	var core := _window_for(visible, Vector2.ZERO)
	var full := _window_for(visible, margin)
	# reconcile on the padded window: gating on the core window alone would let
	# ring cells linger or go missing depending on the path taken to get here,
	# and the content must be a function of the view point only
	if not _has_ring or full != _ring:
		_ring = full
		_has_ring = true
		_reconcile(full, core)
	# every chunk has to follow the scroll, not only the ones that just appeared
	# only write position when it actually changed (saves physics broadphase updates for frozen bodies)
	if scroll_changed:
		for cell in _chunks:
			_chunks[cell].position = Vector2(cell) * cell_size - _scroll
	_animate(delta)


func _window_for(visible: Rect2, pad: Vector2) -> Rect2i:
	var a := ((visible.position + _scroll - pad) / cell_size).floor()
	var b := ((visible.end + _scroll + pad) / cell_size).ceil()
	return Rect2i(Vector2i(a.x, a.y), Vector2i(b.x - a.x, b.y - a.y))


func _reconcile(full: Rect2i, core: Rect2i) -> void:
	for key in _chunks.keys():
		if not full.has_point(key):
			_release(_chunks[key])
			_chunks.erase(key)
	# the visible core first, so a node cap can only ever thin the off-screen ring
	_fill(core, false)
	_fill(full, true)


func _fill(area: Rect2i, ring: bool) -> void:
	for cy in range(area.position.y, area.end.y):
		for cx in range(area.position.x, area.end.x):
			var cell := Vector2i(cx, cy)
			if _chunks.has(cell):
				continue
			if ring and _live_nodes >= max_nodes:
				continue
			var chunk := _build(cell)
			if chunk != null:
				_chunks[cell] = chunk


func _build(cell: Vector2i) -> Node2D:
	var items := _plan(cell)
	if items.is_empty():
		return null
	var chunk: Node2D = _chunk_pool.pop_back() if not _chunk_pool.is_empty() else Node2D.new()
	if chunk.get_parent() == null:
		add_child(chunk)
	chunk.visible = true
	chunk.position = Vector2(cell) * cell_size - _scroll
	chunk.set_meta("cell", cell)
	for d in items:
		var sp: Sprite2D = _sprite_pool.pop_back() if not _sprite_pool.is_empty() else Sprite2D.new()
		sp.texture = d["tex"]
		sp.centered = true
		sp.position = d["pos"]
		sp.rotation = d["rot"]
		sp.scale = d["scale"]
		sp.modulate = d["color"]
		sp.material = material_for(add_blend)
		sp.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		sp.set_meta("spin", d["spin"])
		sp.set_meta("base", d["pos"])
		sp.set_meta("base_alpha", d["color"].a)
		sp.set_meta("phase", d["phase"])
		sp.set_meta("drift_amp", d["drift"])
		sp.set_meta("base_rot", d["rot"])
		chunk.add_child(sp)
		_live_nodes += 1
	return chunk


## Deterministic description of what one cell holds.
func _plan(cell: Vector2i) -> Array:
	var out: Array = []
	var h := HASH.hashf(cell.x, cell.y, _salt, _seed)
	var count := 1
	if not tiled:
		var gate := density
		if patch_block > 0:
			var f := HASH.field(cell.x, cell.y, patch_block, _salt + 911, _seed)
			gate *= lerpf(patch_min, 1.0, f * f)
		if h > gate:
			return out
		if cluster_chance > 0.0 and HASH.hashf(cell.x, cell.y, _salt + 17, _seed) < cluster_chance:
			count = mini(2 + int(HASH.hashf(cell.x, cell.y, _salt + 18, _seed) * cluster_extra),
						 max_per_cell + cluster_extra)
		else:
			count = 1 + int(h * max_per_cell)
			count = mini(count, max_per_cell)
	for i in count:
		var s := _salt + i * 7
		var tex: Texture2D = textures[HASH.hashi(cell.x, cell.y, s + 1, _seed, textures.size())]
		var jx := (HASH.hashf(cell.x, cell.y, s + 2, _seed) - 0.5) * cell_size.x * jitter
		var jy := (HASH.hashf(cell.x, cell.y, s + 3, _seed) - 0.5) * cell_size.y * jitter
		if tiled:
			jx = cell_size.x * 0.5
			jy = cell_size.y * 0.5
		var sc := lerpf(size_range.x, size_range.y, HASH.hashf(cell.x, cell.y, s + 4, _seed))
		var flip := -1.0 if HASH.hashf(cell.x, cell.y, s + 11, _seed) > 0.5 else 1.0
		out.append({
			"tex": tex,
			"pos": Vector2(jx, jy),
			"rot": lerpf(rotation_range.x, rotation_range.y, HASH.hashf(cell.x, cell.y, s + 5, _seed)),
			"scale": Vector2(sc, sc * flip),
			"color": Color(1, 1, 1, lerpf(alpha_range.x, alpha_range.y,
										  HASH.hashf(cell.x, cell.y, s + 6, _seed))),
			"spin": lerpf(spin_range.x, spin_range.y, HASH.hashf(cell.x, cell.y, s + 8, _seed)),
			"phase": HASH.hashf(cell.x, cell.y, s + 9, _seed) * TAU,
			"drift": drift_amp * lerpf(0.4, 1.0, HASH.hashf(cell.x, cell.y, s + 10, _seed)),
		})
	return out


func _animate(delta: float) -> void:
	var spins := spin_range != Vector2.ZERO
	var blinks := twinkle > 0.0
	var wobbles := drift_amp > 0.0
	if not (spins or blinks or wobbles):
		return
	_time += delta
	for cell in _chunks:
		var chunk: Node2D = _chunks[cell]
		for child in chunk.get_children():
			var sprite := child as Sprite2D
			if sprite == null:
				continue
			var amp: float = sprite.get_meta("drift_amp")
			if wobbles and amp > 0.0:
				var ph: float = sprite.get_meta("phase")
				sprite.position = sprite.get_meta("base") + Vector2(
					sin(_scroll.x * 0.0016 + ph), cos(_scroll.y * 0.0013 + ph * 1.7)) * amp
			var spin: float = sprite.get_meta("spin")
			if spins and spin != 0.0:
				# rotation is a function of the view point, not of elapsed time,
				# so the same place always looks the same at any frame rate
				sprite.rotation = fposmod(sprite.get_meta("base_rot")
					+ spin * (_scroll.x + _scroll.y) * 0.0025, TAU)
			if blinks:
				var ph2: float = sprite.get_meta("phase")
				var wave := 1.0 - twinkle * 0.55 * (1.0 + sin(_time * 2.1 + ph2))
				sprite.modulate.a = clampf(sprite.get_meta("base_alpha") * wave, 0.0, 1.0)


func _release(chunk: Node2D) -> void:
	for sp in chunk.get_children():
		chunk.remove_child(sp)
		_sprite_pool.append(sp)
		_live_nodes = maxi(_live_nodes - 1, 0)
	remove_child(chunk)
	_chunk_pool.append(chunk)


## Pooled chunks and sprites are detached from the tree on purpose, which also means the
## tree cannot free them: without this they outlive the layer and Godot reports them as
## leaked at exit. The pool exists to save allocation during a flight, not to survive it.
func _exit_tree() -> void:
	for chunk in _chunk_pool:
		if is_instance_valid(chunk):
			chunk.free()
	for sprite in _sprite_pool:
		if is_instance_valid(sprite):
			sprite.free()
	_chunk_pool.clear()
	_sprite_pool.clear()


func _clear_cells() -> void:
	for cell in _chunks.keys():
		_release(_chunks[cell])
	_chunks.clear()
	_ring = Rect2i()
	_has_ring = false
	_time = 0.0
