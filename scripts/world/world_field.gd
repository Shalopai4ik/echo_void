extends Node2D
class_name EchoWorldField
## Endless space around the ship: chunks of asteroids and atmosphere, generated
## from world coordinates rather than from a level file.
##
## There is no map. What is on screen is a window: chunks are wanted because they
## overlap the screen plus a runway ahead of the bow, and they are dropped when
## they fall behind another, wider window. Each chunk is rebuilt from a hash of
## its integer cell coordinates and `world_seed`, never from a rolling random
## stream, which buys four things at once - a region flown out of comes back
## identical, arriving from the north shows the same space as arriving from the
## south, 30 fps generates exactly what 144 fps generates, and nothing has to be
## remembered about where the ship has been.
##
## Two kinds of content, decided by one flag on the population:
##
## - `physics` populations become bodies from the kind's scene, at true world
##   coordinates, and are as solid as anything else in the game.
## - everything else becomes flat sprites on a parallax plane: no body, no shape,
##   no simulation cost. Those are the fragments and silhouettes that make the
##   void read as deep rather than as empty.
##
## Where the later stages plug in without touching this file:
## - new content: another `SpaceObjectKind` in the settings, art dropped in a
##   folder, `physics` set to whichever it needs.
## - destruction: `bodies()` hands out the live stones; one that comes apart simply
##   stops being where it was planned, and its chunk is rebuilt from the seed when
##   the ship returns.
## - encounters: `_claim()` and `_dress()` are the only place that knows what a cell
##   holds, so a derelict with something inside it is one more roll in there.

const HASH := preload("res://scripts/space_background/space_hash.gd")
const SHAPES := preload("res://scripts/asteroid_shapes.gd")
const ROCK_SCENE := "res://scenes/obstacles/Rock.tscn"

@export_group("Source")
## The whole tuning surface. Left empty, the field builds the shipped default belt
## in code, so a project can start flying before anyone has authored a file.
@export var settings: SpaceGenerationSettings

@export_group("Report")
@export var enabled: bool = true
@export var print_report_on_ready: bool = false

## One population's runtime state: scanned art, its lattice, its live chunks and
## its pools. All of it is derived from the resource, so re-authoring the settings
## means calling `rebuild()`.
class Population:
	var res: SpaceObjectKind
	## Usable art, each {"tex": Texture2D, "id": String, "reach": float, "edge": float}.
	var art: Array = []
	## Art split per size class in class order, so a pebble never wears a hill's
	## silhouette. Index 0 is always the smallest class: cluster satellites use it.
	var tiers: Array[Array] = []
	## Cumulative class weights, normalised to 1, so a roll becomes a class.
	var ladder: Array[float] = []
	var step := Vector2(512, 512)         ## lattice cell, in pattern px
	var jitter := 1.0                     ## 0 = object sits dead centre of its cell
	var per := 1                          ## lattice cells along one chunk edge
	var chunk_px := Vector2(1024, 1024)   ## one chunk, in pattern px
	var max_reach := 0.0                  ## biggest silhouette the kind can produce
	var cap := 8                          ## objects per chunk
	var live_cap := 48                    ## objects of this kind alive at once
	var chunks := {}                      ## Vector2i -> chunk Node2D
	## Chunks that were planned and came out empty. Kept so an empty cell is not
	## re-planned every frame; pruned with the chunks, so it stays window-sized.
	var barren := {}
	var live := 0
	var pool_chunks: Array[Node2D] = []
	var pool_sprites: Array[Sprite2D] = []
	var pool_bodies: Array[RigidBody2D] = []
	var build_us := 0                     ## microseconds spent generating
	var worst_chunk_us := 0


var _pops: Array[Population] = []
var _seed := 0
var _view := Vector2.ZERO
var _budget := 0
var _frame_start := 0
var _worst_frame_us := 0
var _was_enabled := true
var _time := 0.0


func _ready() -> void:
	add_to_group("world_field")
	rebuild()
	if print_report_on_ready:
		print("EchoWorldField ", stats())


## Re-read the settings from scratch: art scan, lattices, class tables. Numeric
## knobs are read every frame and need none of this.
func rebuild() -> void:
	clear()
	_pops.clear()
	if settings == null:
		settings = default_settings()
	settings.seeded()
	_seed = settings.world_seed
	if settings.drop_behind_chunks <= settings.look_ahead_chunks:
		# the drop window has to be the wider one or a chunk on the edge is rebuilt
		# every frame
		settings.drop_behind_chunks = settings.look_ahead_chunks + 0.75
	for res in settings.kinds:
		if res == null or not res.enabled:
			continue
		var pop := _open(res)
		if pop != null:
			_pops.append(pop)
	if _pops.is_empty():
		push_warning("EchoWorldField: no population had usable art")


# ------------------------------------------------------------------- default belt

## The belt the game ships with, in code, so the system runs even without
## `assets/world/space_generation.tres`. That file is the authoring surface; this
## is the floor under it.
func default_settings() -> SpaceGenerationSettings:
	var s := SpaceGenerationSettings.new()
	s.kinds = [
		_default_rocks(),
		# Dust that is close enough to read as motion: small, fairly often, on a
		# plane that almost keeps up with the ship.
		_default_decor("fragments", "res://assets/asteroids/", "asteroid_", 0.5,
			Vector2(0.3, 0.55), 0.55, 34, 240.0, 620.0),
		# Manufactured fragments: rarer, and a reminder that somebody was here.
		_default_decor("wrecks", "res://assets/world/", "wreck_", 0.12,
			Vector2(0.7, 1.3), 0.62, 907, 520.0, 900.0),
		# Silhouettes on a far plane, one every few screens, mostly unreadable.
		_default_decor("structures", "res://assets/world/", "structure_", 0.3,
			Vector2(1.0, 1.7), 0.30, 3409, 900.0, 1400.0),
		# The only lights out here.
		_default_decor("beacons", "res://assets/world/", "beacon_", 0.22,
			Vector2(0.8, 1.4), 0.34, 2617, 1200.0, 1800.0),
	]
	return s


func _default_rocks() -> SpaceObjectKind:
	var k := SpaceObjectKind.new()
	k.label = "asteroids"
	k.salt = 3
	k.physics = true
	k.art_dir = "res://assets/asteroids/"
	k.art_prefix = "asteroid_"
	k.body_scene = load(ROCK_SCENE) as PackedScene
	k.min_distance = 80.0
	k.max_distance = 340.0
	# The lattice offers a candidate to this much of itself, and then the patch field
	# takes most of those back: its gate averages under half of this number, so what
	# reaches the screen is a handful of stones with room-sized gaps between them
	# rather than a field. Tuned against the flight test, not by eye: the belt has
	# to leave a corridor a ship can hold a course down, and at 0.42 on a 250 px
	# lattice a cruise run was stopped every 400 px.
	k.chance = 0.30
	k.patch_block = 7
	k.patch_floor = 0.05
	k.cluster_chance = 0.14
	k.cluster_extra = 4
	k.cluster_gap = 60.0
	k.max_per_chunk = 9
	k.max_live = 60
	k.tint_from = Color(0.9, 0.96, 1.06, 1.0)
	k.tint_to = Color(1.3, 1.34, 1.44, 1.0)
	k.classes = [
		_tier("pebble", 0.70, 0.85, 1.35, 0.0, 34.0),
		_tier("chunk", 0.22, 1.4, 2.4, 30.0, 68.0),
		_tier("hill", 0.08, 2.6, 4.2, 48.0, 4096.0),
	]
	return k


func _tier(name: String, w: float, lo: float, hi: float, amin: float, amax: float) -> SpaceSizeClass:
	var c := SpaceSizeClass.new()
	c.label = name
	c.weight = w
	c.size_min = lo
	c.size_max = hi
	c.art_min_px = amin
	c.art_max_px = amax
	return c


func _default_decor(name: String, dir: String, prefix: String, chance: float,
				   size: Vector2, parallax: float, salt: int,
				   min_d: float, max_d: float) -> SpaceObjectKind:
	var k := SpaceObjectKind.new()
	k.label = name
	k.salt = salt
	k.physics = false
	k.art_dir = dir
	k.art_prefix = prefix
	k.min_distance = min_d
	k.max_distance = max_d
	k.chance = chance
	k.patch_block = 5
	k.patch_floor = 0.1
	k.size_min = size.x
	k.size_max = size.y
	k.alpha_min = 0.5
	k.alpha_max = 1.0
	k.parallax = parallax
	k.spin_max = 0.05
	k.max_per_chunk = 4
	k.max_live = 40
	# light adds to what is behind it instead of covering it, which is the only way
	# a glow reads as a glow over a nebula
	k.add_blend = name == "beacons"
	return k


# ---------------------------------------------------------------------- lifecycle

func _physics_process(_delta: float) -> void:
	if not enabled:
		# once, on the way out: switching the field off must not keep wiping itself
		if _was_enabled:
			clear()
		_was_enabled = false
		return
	_was_enabled = true
	_view = _view_point()
	_budget = maxi(settings.build_per_frame, 1)
	_frame_start = Time.get_ticks_usec()
	var worst := 0
	for pop in _pops:
		var before := Time.get_ticks_usec()
		_advance(pop)
		worst = maxi(worst, Time.get_ticks_usec() - before)
	_worst_frame_us = maxi(_worst_frame_us, worst)


func set_seed(value: int) -> void:
	if value == _seed:
		return
	_seed = value
	settings.world_seed = value
	clear()


func get_seed() -> int:
	return _seed


func clear() -> void:
	for pop in _pops:
		for key in pop.chunks.keys():
			_release(pop, key)
		pop.chunks.clear()
		pop.barren.clear()


## Every body alive right now, for a caller that wants to damage or study one.
func bodies() -> Array[RigidBody2D]:
	var out: Array[RigidBody2D] = []
	for pop in _pops:
		if not pop.res.physics:
			continue
		_collect(pop, out)
	return out


## Bodies of one named population, e.g. "asteroids".
func bodies_of(kind_label: String) -> Array[RigidBody2D]:
	var out: Array[RigidBody2D] = []
	for pop in _pops:
		if pop.res.label == kind_label:
			_collect(pop, out)
	return out


func _collect(pop: Population, out: Array[RigidBody2D]) -> void:
	for key in pop.chunks.keys():
		var chunk: Node2D = pop.chunks[key]
		for child in chunk.get_children():
			var body := child as RigidBody2D
			if body != null:
				out.append(body)


func live_count() -> int:
	var n := 0
	for pop in _pops:
		n += pop.live
	return n


func chunk_count() -> int:
	var n := 0
	for pop in _pops:
		n += pop.chunks.size()
	return n


## What the generator is doing right now, and what it cost. The frame figure is a
## running maximum since the last `reset_report()`, which is what an endurance run
## needs to catch: a build hitch only happens once, on the chunk that comes first.
func stats() -> Dictionary:
	var kinds := {}
	var rejects := 0
	for pop in _pops:
		kinds[pop.res.label] = {
			"live": pop.live, "chunks": pop.chunks.size(),
			"solid": pop.res.physics,
			"pooled": pop.pool_bodies.size() + pop.pool_sprites.size(),
			"us": pop.build_us,
		}
	return {
		"seed": _seed, "live": live_count(), "chunks": chunk_count(),
		"kinds": kinds,
		"worst_frame_us": _worst_frame_us, "pooled_nodes": pooled_nodes(),
	}


func pooled_nodes() -> int:
	var n := 0
	for pop in _pops:
		n += pop.pool_chunks.size() + pop.pool_bodies.size() + pop.pool_sprites.size()
	return n


func reset_report() -> void:
	_worst_frame_us = 0
	for pop in _pops:
		pop.build_us = 0


## Microseconds the generator itself spent since the last `reset_report()`. What
## the bodies then cost the physics server is not in here, and is the other half of
## the question "is this cheap enough".
func build_total() -> int:
	var n := 0
	for pop in _pops:
		n += pop.build_us
	return n


## Debug fingerprint: which cells hold what. By default only the chunks the camera
## can actually see are included, because that is the part that has to be identical
## - the far ring is thinned by the population ceilings and so does depend on the
## route taken to get here. Two fields that have shown the pilot the same region
## must agree, however differently they got there.
func signature(only_visible: bool = true) -> String:
	var parts: Array[String] = []
	var rect := _visible_world_rect()
	for pop in _pops:
		var shift := (1.0 - pop.res.parallax) * _view
		for key in pop.chunks.keys():
			var box := Rect2(Vector2(key) * pop.chunk_px + shift, pop.chunk_px)
			if only_visible and not box.intersects(rect):
				continue
			var chunk: Node2D = pop.chunks[key]
			var items: Array[String] = []
			for child in chunk.get_children():
				var sprite := child as Sprite2D
				var u: Vector2 = child.get_meta("u")
				var scale := 1.0
				var file := ""
				if sprite != null:
					scale = sprite.scale.x
					file = sprite.texture.resource_path.get_file()
				else:
					scale = child.get_meta("scale")
					file = child.get_meta("art")
				items.append("%s@%d,%d s%.2f" % [file, roundi(u.x), roundi(u.y), scale])
			items.sort()
			parts.append("%s[%d,%d]:%s" % [pop.res.label, key.x, key.y, "|".join(items)])
	parts.sort()
	return ";".join(parts)


func _notification(what: int) -> void:
	# pooled nodes live outside the tree, so nothing else would free them when the
	# field goes away mid-game
	if what == NOTIFICATION_PREDELETE:
		for pop in _pops:
			for b in pop.pool_bodies:
				if b != null:
					b.free()
			for sp in pop.pool_sprites:
				if sp != null:
					sp.free()
			for c in pop.pool_chunks:
				if c != null:
					c.free()
		_pops.clear()


# ------------------------------------------------------------------- one population

## The frame's work for one population: drop what fell behind, build what is
## wanted nearest the ship first, and move every chunk along the parallax shift.
func _advance(pop: Population) -> void:
	var shift := (1.0 - pop.res.parallax) * _view
	var keep := _window(pop, shift, settings.drop_behind_chunks)
	for key in pop.chunks.keys():
		if not keep.has_point(key):
			_release(pop, key)
	for key in pop.barren.keys():
		if not keep.has_point(key):
			pop.barren.erase(key)

	var build := _window(pop, shift, settings.look_ahead_chunks)
	var core := _window(pop, shift, 0.0)
	var want: Array[Vector2i] = []
	var on_screen := {}
	for cy in range(core.position.y, core.end.y):
		for cx in range(core.position.x, core.end.x):
			var key := Vector2i(cx, cy)
			if pop.chunks.has(key) or pop.barren.has(key):
				continue
			want.append(key)
			on_screen[key] = true
	for cy in range(build.position.y, build.end.y):
		for cx in range(build.position.x, build.end.x):
			var key := Vector2i(cx, cy)
			if pop.chunks.has(key) or pop.barren.has(key) or on_screen.has(key):
				continue
			want.append(key)
	# nearest first: a build cap may only ever thin the far edge of the window,
	# never the space off the bow
	var origin := -shift / pop.chunk_px
	want.sort_custom(func(a, b):
		return a.distance_squared_to(origin) < b.distance_squared_to(origin))
	for key in want:
		if _budget <= 0:
			break
		# A chunk is atomic, so this can only promise "no new chunk this frame", not
		# a hard ceiling - the worst frame costs one chunk plus whatever started
		# before the clock ran out.
		if Time.get_ticks_usec() - _frame_start > int(settings.build_microseconds):
			break
		# the screen itself is built even when the population sits at its ceiling:
		# a hole the pilot can see is worse than one he cannot
		if pop.live >= pop.live_cap and not on_screen.has(key):
			continue
		var plans := _plan_chunk(pop, key)
		if plans.is_empty():
			pop.barren[key] = true
			continue
		var need := _needs(plans)
		if _budget < need and need <= settings.build_per_frame:
			# A chunk is committed whole or left for the next frame. Three of a
			# cluster's five stones would read as a different object than five, and a
			# chunk marked empty because the frame ran out of budget would make the
			# window depend on how the ship arrived here - which is the one thing this
			# whole file exists to avoid.
			break
		_commit(pop, key, shift, plans)
		_budget -= need

	# every chunk rides the shift, not only the ones that just appeared
	for key in pop.chunks.keys():
		var chunk: Node2D = pop.chunks[key]
		chunk.position = Vector2(key) * pop.chunk_px + shift
	_animate(pop)


## The pure half of a chunk: what its cells hold, with nothing created. Split from
## the commit so the frame can decide whether it can afford the whole chunk before
## any of it exists.
func _plan_chunk(pop: Population, key: Vector2i) -> Array:
	var before := Time.get_ticks_usec()
	var base := Vector2i(key) * pop.per
	var planned: Array = []
	var count := 0
	# one memo per chunk: the claim scans of neighbouring cells overlap heavily, and
	# the values in it are pure functions of a cell, so sharing them within a chunk
	# is free and dropping the whole thing afterwards keeps the memory window-sized
	var memo := {}
	for j in range(pop.per):
		for i in range(pop.per):
			if count >= pop.cap:
				break
			var cell := base + Vector2i(i, j)
			var c := _claimed(pop, cell, memo)
			if c.z <= 0.0:
				continue
			var plan := _dress(pop, cell, c)
			if not _accepts(pop, cell, plan, memo):
				continue
			var n: int = plan["items"].size()
			if count + n > pop.cap:
				continue
			count += n
			planned.append(plan)
	pop.worst_chunk_us = maxi(pop.worst_chunk_us, Time.get_ticks_usec() - before)
	return planned


func _needs(plans: Array) -> int:
	var n := 0
	for plan in plans:
		n += plan["items"].size()
	return n


func _commit(pop: Population, key: Vector2i, shift: Vector2, plans: Array) -> void:
	var before := Time.get_ticks_usec()
	var origin := Vector2(key) * pop.chunk_px
	var chunk: Node2D = pop.pool_chunks.pop_back() \
		if not pop.pool_chunks.is_empty() else Node2D.new()
	chunk.name = "Chunk"
	if chunk.get_parent() == null:
		add_child(chunk)
	chunk.visible = true
	chunk.position = origin + shift
	chunk.set_meta("key", key)
	pop.chunks[key] = chunk
	for plan in plans:
		for item in plan["items"]:
			var local: Vector2 = item["u"] - origin
			if pop.res.physics:
				_place_body(pop, chunk, item, local)
			else:
				_place_sprite(pop, chunk, item, local)
			pop.live += 1
	pop.build_us += Time.get_ticks_usec() - before


## Chunks overlapping the screen, expressed in this population's own pattern
## space: the world rect minus whatever the plane has already drifted by.
func _window(pop: Population, shift: Vector2, margin_chunks: float) -> Rect2i:
	var rect := _visible_world_rect()
	var pad := pop.chunk_px * margin_chunks
	var a := ((rect.position - shift - pad) / pop.chunk_px).floor()
	var b := ((rect.end - shift + pad) / pop.chunk_px).ceil()
	return Rect2i(Vector2i(int(a.x), int(a.y)), Vector2i(int(b.x - a.x), int(b.y - a.y)))


func _release(pop: Population, key: Vector2i) -> void:
	var chunk: Node2D = pop.chunks[key]
	pop.chunks.erase(key)
	for child in chunk.get_children():
		chunk.remove_child(child)
		pop.live = maxi(pop.live - 1, 0)
		var body := child as RigidBody2D
		if body != null:
			pop.pool_bodies.append(body)
		else:
			pop.pool_sprites.append(child as Sprite2D)
	remove_child(chunk)
	pop.pool_chunks.append(chunk)


func _place_body(pop: Population, chunk: Node2D, item: Dictionary, local: Vector2) -> void:
	var body: RigidBody2D = pop.pool_bodies.pop_back() \
		if not pop.pool_bodies.is_empty() else pop.res.body_scene.instantiate() as RigidBody2D
	if body == null:
		push_warning("field: %s has no body to instantiate" % pop.res.label)
		return
	body.visible = true
	body.set_meta("u", item["u"])
	body.set_meta("scale", item["scale"])
	body.set_meta("art", item["file"])
	# placed before it enters the tree, so the physics server never sees the body at
	# the scene's default origin for a step on its way in
	body.position = local
	body.rotation = item["rot"]
	chunk.add_child(body)
	if body.has_method("set_form"):
		body.set_form(item["id"], item["scale"], item["tint"])


func _place_sprite(pop: Population, chunk: Node2D, item: Dictionary, local: Vector2) -> void:
	var sp: Sprite2D = pop.pool_sprites.pop_back() \
		if not pop.pool_sprites.is_empty() else Sprite2D.new()
	sp.visible = true
	sp.centered = true
	sp.texture = item["tex"]
	sp.position = local
	sp.rotation = item["rot"]
	var s: float = item["scale"]
	var flip: float = -1.0 if item["flip"] else 1.0
	sp.scale = Vector2(s, s * flip)
	sp.modulate = item["tint"]
	sp.material = EchoSpaceLayer.material_for(pop.res.add_blend)
	# the belt art was cut from a photographic plate, so it is resampled, not
	# stepped, even though the project draws everything else Nearest
	sp.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	sp.set_meta("u", item["u"])
	sp.set_meta("base_rot", item["rot"])
	sp.set_meta("spin", item["spin"])
	sp.set_meta("base_alpha", item["tint"].a)
	chunk.add_child(sp)


## Rotation and twinkle are functions of the view point rather than of elapsed
## time, so a place looks the same however you reach it and whatever the frame
## rate - the same rule the sky behind this field follows.
func _animate(pop: Population) -> void:
	if pop.res.physics or pop.res.spin_max <= 0.0:
		return
	var scroll := _view * pop.res.parallax
	for key in pop.chunks.keys():
		var chunk: Node2D = pop.chunks[key]
		for child in chunk.get_children():
			var sp := child as Sprite2D
			if sp == null:
				continue
			var spin: float = sp.get_meta("spin")
			if spin != 0.0:
				sp.rotation = fposmod(sp.get_meta("base_rot")
					+ spin * (scroll.x + scroll.y) * 0.0025, TAU)


# ----------------------------------------------------------------------- the plan

## Bounding circle and rank of whatever a lattice cell would offer, without
## dressing it. The claim test below asks for this for every neighbour of every
## candidate in a chunk, so it deliberately allocates nothing: a Vector4 of
## (u.x, u.y, radius, priority), with a radius of 0 meaning the cell holds nothing.
##
## Everything here is a pure function of the cell and the seed. Nothing looks at
## what is already alive, which is the whole reason a visited region can be thrown
## away and rebuilt and come back identical.
func _claim(pop: Population, cell: Vector2i) -> Vector4:
	var res := pop.res
	var gate := _gate(pop, cell)
	if gate <= 0.0 or HASH.hashf(cell.x, cell.y, res.salt, _seed) > gate:
		return Vector4.ZERO
	var point := (Vector2(cell)
		+ Vector2(0.5 + _jit(pop, cell, 2), 0.5 + _jit(pop, cell, 3))) * pop.step
	# The open-water zone around the start belongs to the plan rather than to the
	# build: it depends on coordinates only, so a returning ship finds the same
	# emptiness it left.
	if res.physics and point.length() < settings.spawn_clear_radius:
		return Vector4.ZERO
	var tier := _tier_of(pop, cell)
	var radius := _reach_of(pop, tier, cell)
	# satellites only ever gather around something with a real silhouette, so a
	# cluster reads as a knot in the dark rather than as a smudge of dust
	var clustered := radius > 26.0 and _is_cluster(pop, cell)
	if clustered:
		radius = _ring_of(pop, cell, radius) + _sat_reach_of(pop, cell)
	var tie := HASH.hashf(cell.x, cell.y, res.salt + 11, _seed)
	return Vector4(point.x, point.y, radius,
		# A bigger silhouette wins the ground around it, a cluster outranks a lone
		# stone of its class, and one roll breaks ties inside a class. A total order
		# from coordinates alone, so two ships - or one ship twice - agree.
		float(tier) + (0.5 if clustered else 0.0) + tie * 0.49)


func _claimed(pop: Population, cell: Vector2i, memo: Dictionary) -> Vector4:
	if memo.has(cell):
		return memo[cell]
	var c := _claim(pop, cell)
	memo[cell] = c
	return c


## The dressed version of a cell the claim rule let through: the art, tint and turn
## that make the plan into objects. Only ever called for what actually gets built.
func _dress(pop: Population, cell: Vector2i, c: Vector4) -> Dictionary:
	var res := pop.res
	var point := Vector2(c.x, c.y)
	var tier := _tier_of(pop, cell)
	var rec := _art_of(pop, tier, cell)
	var scale := _scale_of(pop, tier, cell)
	var tint := _tint_of(pop, tier, cell)
	var alpha := lerpf(res.alpha_min, res.alpha_max, HASH.hashf(cell.x, cell.y, res.salt + 7, _seed))
	var rot := lerpf(res.rotation_from, res.rotation_to,
					 HASH.hashf(cell.x, cell.y, res.salt + 8, _seed))
	var items: Array = [_item(pop, rec, scale, tint, alpha, rot, point, cell, res.salt)]
	var center_reach := _reach_of(pop, tier, cell)
	if center_reach > 26.0 and _is_cluster(pop, cell):
		var sat := _sat_art_of(pop, cell)
		var sat_scale := _sat_scale_of(pop, cell)
		var ring := _ring_of(pop, cell, center_reach)
		var n := 2 + int(HASH.hashf(cell.x, cell.y, res.salt + 13, _seed) * res.cluster_extra)
		var phase := HASH.hashf(cell.x, cell.y, res.salt + 14, _seed) * TAU
		for i in n:
			var a := phase + TAU * (float(i) + 0.5) / float(n) \
				+ (HASH.hashf(cell.x, cell.y, res.salt + 20 + i, _seed) - 0.5) * 0.7
			var at := point + Vector2.RIGHT.rotated(a) * (ring
				* lerpf(0.86, 1.12, HASH.hashf(cell.x, cell.y, res.salt + 30 + i, _seed)))
			var sat_rot := lerpf(res.rotation_from, res.rotation_to,
								 HASH.hashf(cell.x, cell.y, res.salt + 40 + i, _seed))
			items.append(_item(pop, sat, sat_scale, tint, alpha, sat_rot, at, cell,
				res.salt + 60 + i))
	return {"point": point, "radius": c.z, "priority": c.w, "items": items}


# The rolls, factored out so the claim and the dressing of one cell cannot drift
# apart: both read the same hash of the same cell for the same number.

func _art_of(pop: Population, tier: int, cell: Vector2i) -> Dictionary:
	var pool: Array = pop.tiers[tier]
	return pool[HASH.hashi(cell.x, cell.y, pop.res.salt + 5, _seed, pool.size())]


func _reach_of(pop: Population, tier: int, cell: Vector2i) -> float:
	return _art_of(pop, tier, cell)["reach"] * _scale_of(pop, tier, cell)


func _is_cluster(pop: Population, cell: Vector2i) -> bool:
	return pop.res.cluster_chance > 0.0 \
		and HASH.hashf(cell.x, cell.y, pop.res.salt + 6, _seed) < pop.res.cluster_chance


func _sat_art_of(pop: Population, cell: Vector2i) -> Dictionary:
	var pool: Array = pop.tiers[0]
	return pool[HASH.hashi(cell.x, cell.y, pop.res.salt + 12, _seed, pool.size())]


func _sat_scale_of(pop: Population, cell: Vector2i) -> float:
	var small: SpaceSizeClass = pop.res.classes[0]
	return lerpf(small.size_min, small.size_max,
		pow(HASH.hashf(cell.x, cell.y, pop.res.salt + 16, _seed), small.size_bias))


func _sat_reach_of(pop: Population, cell: Vector2i) -> float:
	return _sat_art_of(pop, cell)["reach"] * _sat_scale_of(pop, cell)


## Distance of the satellites from the centre stone: air between the two silhouettes
## plus both of their own reaches, so a cluster never fuses into one blob.
func _ring_of(pop: Population, cell: Vector2i, center_reach: float) -> float:
	return center_reach + _sat_reach_of(pop, cell) + pop.res.cluster_gap


## Would this cell be swallowed by a bigger neighbour? Checked against the raw
## claims of the surrounding cells rather than against the live objects, so the
## answer never depends on which chunk was built first.
func _accepts(pop: Population, cell: Vector2i, me: Dictionary, memo: Dictionary) -> bool:
	var scan := int(ceil((me["radius"] + pop.max_reach)
		/ maxf(minf(pop.step.x, pop.step.y), 1.0)))
	scan = mini(scan, 6)
	for dy in range(-scan, scan + 1):
		for dx in range(-scan, scan + 1):
			if dx == 0 and dy == 0:
				continue
			var other := _claimed(pop, cell + Vector2i(dx, dy), memo)
			if other.z <= 0.0:
				continue
			if me["point"].distance_to(Vector2(other.x, other.y)) < me["radius"] + other.z \
					and other.w > me["priority"]:
				return false
	return true


## One object of a plan: where it sits in pattern space and how it is dressed.
## `salt` is per-object so a cluster's satellites do not all inherit the centre
## stone's mirror and spin.
func _item(pop: Population, rec: Dictionary, scale: float, tint: Color, alpha: float,
		   rot: float, at: Vector2, cell: Vector2i, salt: int) -> Dictionary:
	var res := pop.res
	return {
		"u": at,
		"tex": rec["tex"],
		"file": rec["file"],
		"id": rec["id"],
		"scale": scale,
		"tint": Color(tint.r, tint.g, tint.b, tint.a * alpha),
		"rot": rot,
		# a mirrored silhouette is free variety for a sprite, but not for a body:
		# its collision outline comes from the same table as its picture, so solid
		# stones keep the shape they were cut with
		"flip": not res.physics and HASH.hashf(cell.x, cell.y, salt + 51, _seed) > 0.5,
		"spin": lerpf(-res.spin_max, res.spin_max, HASH.hashf(cell.x, cell.y, salt + 9, _seed)),
	}


## Probability this cell offers anything at all: the kind's own chance, thinned by
## the master density and by a smooth field over blocks of cells. The field is
## what leaves whole sectors empty instead of an even sprinkle.
func _gate(pop: Population, cell: Vector2i) -> float:
	var res := pop.res
	var master := settings.rock_density_scale if res.physics else settings.decor_density_scale
	var g := res.chance * master
	if g <= 0.0:
		return 0.0
	if res.patch_block > 0:
		var f := HASH.field(cell.x, cell.y, res.patch_block, res.salt + 911, _seed)
		g *= lerpf(res.patch_floor, 1.0, f * f)
	return g


func _tier_of(pop: Population, cell: Vector2i) -> int:
	var r := HASH.hashf(cell.x, cell.y, pop.res.salt + 1, _seed)
	for i in pop.ladder.size():
		if r <= pop.ladder[i]:
			return i
	return pop.ladder.size() - 1


func _scale_of(pop: Population, tier: int, cell: Vector2i) -> float:
	var c: SpaceSizeClass = pop.res.classes[tier]
	# biased toward the small end: one roll decides the size, and the same shape of
	# distribution is why a belt is mostly gravel with a few things you steer around
	var t := pow(HASH.hashf(cell.x, cell.y, pop.res.salt + 2, _seed), c.size_bias)
	return lerpf(c.size_min, c.size_max, t)


## The class tint rides on top of the population's, multiplied, so a class that
## declares nothing stays neutral and inherits what its kind was given.
func _tint_of(pop: Population, tier: int, cell: Vector2i) -> Color:
	var r := HASH.hashf(cell.x, cell.y, pop.res.salt + 4, _seed)
	var res := pop.res
	var c: SpaceSizeClass = res.classes[tier]
	return c.tint_from.lerp(c.tint_to, r) * res.tint_from.lerp(res.tint_to, r)


func _jit(pop: Population, cell: Vector2i, salt: int) -> float:
	return (HASH.hashf(cell.x, cell.y, pop.res.salt + salt, _seed) - 0.5) * pop.jitter


# ------------------------------------------------------------------- populations

func _open(res: SpaceObjectKind) -> Population:
	var pop := Population.new()
	pop.res = res
	if res.physics and res.parallax != 1.0:
		# a body that is not at world coordinates is a body the hull cannot hit
		push_warning("field: %s is solid, parallax forced to 1.0" % res.label)
		res.parallax = 1.0
	res.art = _scan_art(res)
	if res.art.is_empty():
		push_warning("field: nothing usable in %s%s*" % [res.art_dir, res.art_prefix])
		return null
	if res.classes.is_empty():
		res.classes = [_implicit_class(res)]
	pop.art = res.art
	_organise(pop)
	if pop.tiers.is_empty():
		push_warning("field: %s has no class with art it can wear" % res.label)
		return null
	_lattice(pop)
	return pop


## Art filtered into the classes that can wear it, smallest class first.
func _organise(pop: Population) -> void:
	var res := pop.res
	var ordered: Array[SpaceSizeClass] = []
	ordered.append_array(res.classes)
	ordered.sort_custom(func(a, b): return a.size_min < b.size_min)
	res.classes = ordered
	var total := 0.0
	for c in ordered:
		total += maxf(c.weight, 0.0)
	var acc := 0.0
	pop.ladder.clear()
	pop.tiers.clear()
	for c in ordered:
		var pool: Array = []
		for rec in pop.art:
			if rec["edge"] >= c.art_min_px and rec["edge"] <= c.art_max_px:
				pool.append(rec)
		if pool.is_empty():
			pool = pop.art
			push_warning("field: class %s takes any art, none fits %d-%d px"
				% [c.label, int(c.art_min_px), int(c.art_max_px)])
		pop.tiers.append(pool)
		acc += (maxf(c.weight, 0.0) / total if total > 0.0 else 1.0 / ordered.size())
		pop.ladder.append(acc)
	pop.ladder[pop.ladder.size() - 1] = 1.0
	pop.max_reach = _max_reach(pop)


func _implicit_class(res: SpaceObjectKind) -> SpaceSizeClass:
	var c := SpaceSizeClass.new()
	c.label = res.label
	c.weight = 1.0
	c.size_min = res.size_min
	c.size_max = res.size_max
	c.size_bias = res.size_bias
	return c


## Cell size and chunk size from the distance pair: the step guarantees the
## spread, `min_distance` only pulls a candidate off its cell centre.
func _lattice(pop: Population) -> void:
	var res := pop.res
	var span := maxf(res.max_distance, res.min_distance + 1.0)
	pop.step = Vector2(span, span * 0.78)
	pop.jitter = clampf((span - res.min_distance) / span, 0.0, 1.0)
	pop.per = maxi(1, int(round(settings.chunk_size / span)))
	pop.chunk_px = pop.step * float(pop.per)
	var master := settings.rock_density_scale if res.physics else settings.decor_density_scale
	pop.cap = maxi(1, int(round(res.max_per_chunk * clampf(master, 0.0, 4.0))))
	pop.live_cap = maxi(1, int(round(res.max_live * clampf(master, 0.0, 4.0))))


## The biggest silhouette the kind can put on screen, which bounds both the
## neighbour scan and the spacing the claim rule has to hold.
func _max_reach(pop: Population) -> float:
	var best := 0.0
	for t in pop.tiers.size():
		var c: SpaceSizeClass = pop.res.classes[t]
		var hi := c.size_max
		for rec in pop.tiers[t]:
			best = maxf(best, rec["reach"] * hi)
		if pop.res.cluster_chance > 0.0:
			# a cluster claims its ring as well as its centre stone
			var sat_hi := pop.res.classes[0].size_max
			var sat_reach := 0.0
			for rec in pop.tiers[0]:
				sat_reach = maxf(sat_reach, rec["reach"] * sat_hi)
			best = maxf(best, best + sat_reach + pop.res.cluster_gap + sat_reach)
	return best


## {tex, id, file, reach, edge} per PNG the folder offers. For a solid kind the
## reach comes from the collision table rather than from the picture, because the
## claim rule has to keep bodies apart at the distance the physics actually stops
## something at.
func _scan_art(res: SpaceObjectKind) -> Array:
	var out: Array = []
	var dir := DirAccess.open(res.art_dir)
	if dir == null:
		push_warning("field: cannot open " + res.art_dir)
		return out
	var names: PackedStringArray = dir.get_files()
	names.sort()
	for f in names:
		var lower := f.to_lower()
		if not lower.ends_with(".png") or not lower.begins_with(res.art_prefix.to_lower()):
			continue
		var tex := load(res.art_dir + f) as Texture2D
		if tex == null:
			continue
		var stem := f.get_basename()
		var edge := maxf(tex.get_width(), tex.get_height())
		var reach := edge * 0.5
		if res.physics:
			var pieces: Array = SHAPES.SHAPES.get(stem, [])
			var best := 0.0
			for piece in pieces:
				for v in piece:
					best = maxf(best, v.length())
			if best <= 0.0:
				continue
			reach = best
		out.append({
			"tex": tex,
			"id": stem.trim_prefix(res.art_prefix),
			"file": f,
			"reach": reach,
			"edge": edge,
		})
	return out


# ------------------------------------------------------------------- where the view is

## The point every plane scrolls around: the camera when there is one, because the
## camera is what the screen is measured from. Without one the node's own position
## stands in, which is what a review scene with no camera needs.
func _view_point() -> Vector2:
	var vp := get_viewport()
	if vp != null:
		var cam := vp.get_camera_2d()
		if cam != null:
			return cam.global_position
	return global_position


## The screen rectangle in world pixels, zoom included, so the field thins out
## when the pilot pulls the lens back instead of pretending the view never changes.
func _visible_world_rect() -> Rect2:
	var vp := get_viewport()
	if vp == null:
		return Rect2(Vector2.ZERO, Vector2(960, 540))
	var size := vp.get_visible_rect().size
	if size.x < 1.0 or size.y < 1.0:
		size = Vector2(960, 540)
	var to_world := vp.get_canvas_transform().affine_inverse()
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in [Vector2.ZERO, Vector2(size.x, 0.0), Vector2(0.0, size.y), Vector2(size)]:
		var q: Vector2 = to_world * p
		lo = Vector2(minf(lo.x, q.x), minf(lo.y, q.y))
		hi = Vector2(maxf(hi.x, q.x), maxf(hi.y, q.y))
	return Rect2(lo, hi - lo)
