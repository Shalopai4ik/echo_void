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
##   folder, `physics` set to whichever it needs. Each kind hashes with its own
##   salt, so adding one cannot move the stones of the ones already here.
## - destruction: `remove_object()` takes a stone out of the world and remembers
##   that it is gone, so a chunk rebuilt on the way back does not resurrect it.
## - encounters: `_claim()` and `_dress()` are the only place that knows what a cell
##   holds, so a derelict with something inside it is one more roll in there.
##
## The chunk layer itself, since sub-stage 3.3:
##
## - a chunk has an id (`CHUNK.id_of`), bounds, a generation seed
##   (`CHUNK.seed_of`: hash of world seed, coordinates and the plane's salt), and a
##   state - UNLOADED, GENERATING (wanted, waiting for budget), ACTIVE, UNLOADING
##   (out of the window, waiting for the unload budget). `chunk_info()` reports all
##   of it, `chunk_state_counts()` counts it, `debug_lines()` prints it.
## - every plane streams in its own chunks, sized from its own lattice, and each is
##   marked `barren` once generated empty; the world-chunk grid the HUD reports on
##   is `chunk_size` square and is a reading aid, not a second bookkeeping system.
## - a frame spends its work in a fixed order: mark what fell out of the keep
##   window, release it (largest backlog first, farthest chunk first, no more than
##   `max_chunk_unloads_per_frame`), then build (nearest first, no more than
##   `max_chunk_generations_per_frame` starts, `build_per_frame` objects and
##   `build_microseconds` of clock).
## - what the player changed is kept in `ChunkStateStore`, keyed by chunk id and the
##   object's stable item id (`cell:slot`), and applied at build time. The generated
##   content is never stored: the seed rebuilds it.

const HASH := preload("res://scripts/space_background/space_hash.gd")
const SHAPES := preload("res://scripts/asteroid_shapes.gd")
const DEBRIS_SCENE := "res://scenes/world/Debris.tscn"
## The chunk vocabulary and the memory of what was changed in one. Preloaded
## rather than named: a fresh clone of the project has not imported these yet, and
## a script that only compiles after an editor pass is a script that fails in CI.
const CHUNK := preload("res://scripts/world/world_chunk.gd")
const CHUNK_STATE := preload("res://scripts/world/chunk_state_store.gd")

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
	## Chunks the frame wanted but could not afford yet. Reported as GENERATING and
	## rebuilt from the window on the next frame rather than carried as work: the
	## window is the authority on what should exist, so a queue that outlived it
	## could only ever ask for something the ship has already left.
	var queued := {}
	## Chunks that fell out of the keep window but are still waiting for their turn
	## in the unload budget. Reported as UNLOADING; their contents are still alive,
	## off screen, which is why they are released before anything new is planned.
	var closing := {}
	var live := 0
	var pool_chunks: Array[Node2D] = []
	var pool_sprites: Array[Sprite2D] = []
	var pool_bodies: Array[RigidBody2D] = []
	var build_us := 0                     ## microseconds spent generating
	var worst_chunk_us := 0
	## The scroll every sprite in this plane was last turned for. A decorative
	## plane's rotation is a function of the view point, so a frame that did not
	## move the view cannot change a single sprite's picture - and skipping the
	## pass then is the difference between a loop over every silhouette and
	## nothing. A commit resets it, because new sprites have to be turned once.
	var turn_scroll := Vector2.INF


var _pops: Array[Population] = []
var _seed := 0
var _view := Vector2.ZERO
var _budget := 0
var _frame_start := 0
var _worst_frame_us := 0
var _was_enabled := true
var _time := 0.0

## What the last frame cost in chunks rather than in objects, and what the whole
## session has created. The counters are reset at the top of `_physics_process`,
## because a generation budget that is checked against a total is not a budget.
var _generations := 0
var _generations_last := 0
var _unloads := 0
var _unloads_last := 0
var _created_total := 0
## What one whole pass of this file's `_physics_process` cost, in microseconds.
## Kept apart from `_worst_frame_us`, which only times the per-plane build pass:
## this one is the number a profile of the running game is asking for, and it is
## the only way to see a bookkeeping cost that the build budget by design cannot
## see (marking, releasing, moving chunks, the decorative turn pass).
var _frame_us := 0
var _worst_pass_us := 0

## The deltas a chunk accumulates while it is loaded. Generated content is never
## in here: the seed rebuilds that, this only remembers what somebody changed.
var _store := CHUNK_STATE.new()


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
	# the art tables and the seed are about to be re-read, so state remembered
	# against the old world describes objects that no longer exist
	_store.clear()
	if settings == null:
		settings = default_settings()
	settings.seeded()
	_seed = settings.world_seed
	var ahead := settings.look_ahead_chunks + maxf(settings.preload_chunks, 0.0)
	if settings.drop_behind_chunks <= ahead:
		# the drop window has to be the wider one or a chunk on the edge is rebuilt
		# every frame
		settings.drop_behind_chunks = ahead + 0.75
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
		# Unknown metallic fragments close enough to read as separate pieces of a
		# larger machine. Their own salt keeps this stream independent from both
		# the stones and the distant wreck silhouettes. This rare solid population
		# is planned first so the shared per-frame chunk budget cannot starve it
		# behind a denser belt.
		_default_debris(),
		_default_rocks(),
		# The same stones with the light taken out of them: a shape in the distance
		# that a hull passes through. Planned right after the belt so the eye reads
		# them as one population, not as two.
		_default_shadows(),
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


## The stones the hull can hit, and the only ones drawn bright enough to read as
## solid matter: the art is a dark plate, so the tint lifts it instead of filtering
## it (values above 1 brighten). Same picture, same plane and same bodies the world
## always had; what changed is that the dim ones moved to `shadows`.
func _default_rocks() -> SpaceObjectKind:
	var k := SpaceObjectKind.new()
	k.label = "asteroids"
	k.salt = 3
	k.physics = true
	k.object_kind = "asteroid"
	k.art_dir = "res://assets/asteroids/"
	k.art_prefix = "asteroid_"
	k.body_scene = load("res://scenes/obstacles/Rock.tscn") as PackedScene
	k.min_distance = 80.0
	k.max_distance = 340.0
	# The lattice offers a candidate to this much of itself, and then the patch field
	# takes most of those back: what reaches the screen is a handful of stones with
	# room-sized gaps between them rather than a field. Tuned against the flight test,
	# not by eye: the belt has to leave a corridor a ship can hold a course down.
	k.chance = 0.30
	k.patch_block = 7
	k.patch_floor = 0.05
	k.cluster_chance = 0.14
	k.cluster_extra = 4
	k.cluster_gap = 60.0
	k.max_per_chunk = 9
	k.max_live = 60
	k.tint_from = Color(1.12, 1.16, 1.26, 1.0)
	k.tint_to = Color(1.45, 1.50, 1.62, 1.0)
	k.classes = [
		_tier("pebble", 0.70, 0.85, 1.35, 0.0, 34.0),
		_tier("chunk", 0.22, 1.4, 2.4, 30.0, 68.0),
		_tier("hill", 0.08, 2.6, 4.2, 48.0, 4096.0),
	]
	return k


## The same stones, pushed back and put out: dimmed far enough that they read as a
## shape in the dark rather than as a rock in front of the ship, on a plane that keeps
## only 55% of the ship's motion. They carry no body, so the hull passes through them;
## that is the whole point - a silhouette that cannot say which side the light is on
## should not be a wall.
func _default_shadows() -> SpaceObjectKind:
	var k := SpaceObjectKind.new()
	k.label = "shadows"
	k.salt = 71
	k.physics = false
	k.object_kind = "decorative"
	k.parallax = 0.55
	k.art_dir = "res://assets/asteroids/"
	k.art_prefix = "asteroid_"
	k.size_min = 0.8
	k.size_max = 2.2
	k.min_distance = 260.0
	k.max_distance = 520.0
	k.chance = 0.55
	k.patch_block = 7
	k.patch_floor = 0.06
	k.cluster_chance = 0.14
	k.cluster_extra = 3
	k.cluster_gap = 60.0
	k.max_per_chunk = 7
	k.max_live = 56
	# Below 1 darkens: the same plate the solid belt is cut from, without the light
	# that tells a pilot there is something to steer around.
	k.tint_from = Color(0.50, 0.53, 0.62, 1.0)
	k.tint_to = Color(0.72, 0.75, 0.85, 1.0)
	k.alpha_min = 0.45
	k.alpha_max = 0.80
	k.spin_max = 0.05
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


func _default_debris() -> SpaceObjectKind:
	var k := SpaceObjectKind.new()
	k.label = "debris"
	k.salt = 617
	k.physics = true
	k.object_kind = "debris"
	k.body_scene = load(DEBRIS_SCENE) as PackedScene
	k.art_dir = "res://assets/world/debris/"
	k.art_prefix = "debris_"
	k.min_distance = 360.0
	k.max_distance = 880.0
	k.chance = 0.08
	k.patch_block = 9
	k.patch_floor = 0.02
	k.cluster_chance = 0.22
	k.cluster_extra = 2
	k.cluster_gap = 135.0
	k.size_min = 0.62
	k.size_max = 1.12
	k.alpha_min = 0.78
	k.alpha_max = 1.0
	k.parallax = 1.0
	k.spin_max = 0.0
	k.max_per_chunk = 2
	k.max_live = 16
	k.tint_from = Color(0.92, 1.0, 1.12, 1.0)
	k.tint_to = Color(1.22, 1.18, 1.10, 1.0)
	return k


func _default_decor(name: String, dir: String, prefix: String, chance: float,
				   size: Vector2, parallax: float, salt: int,
				   min_d: float, max_d: float) -> SpaceObjectKind:
	var k := SpaceObjectKind.new()
	k.label = name
	k.salt = salt
	k.physics = false
	k.object_kind = "decorative"
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
		_frame_us = 0
		return
	_was_enabled = true
	var pass_started := Time.get_ticks_usec()
	_view = _view_point()
	_generations = 0
	_unloads = 0
	_budget = maxi(settings.build_per_frame, 1)
	_frame_start = Time.get_ticks_usec()
	var worst := 0
	# 1. what every plane no longer wants. Marking is all that happens here: a
	# chunk that is merely out of the window still holds its objects, and dropping
	# it is the expensive half.
	for pop in _pops:
		var shift := (1.0 - pop.res.parallax) * _view
		_mark_closing(pop, _window(pop, shift, settings.drop_behind_chunks))
	# 2. hand it back, biggest backlog first and within the frame's budget. One
	# shared cap with a fixed order would let the first plane eat it every frame of
	# a long boost run, which is how a distant plane's chunk count grows without
	# anything looking wrong up close.
	_release_pass()
	# 3. build what the frame can afford
	for pop in _pops:
		var before := Time.get_ticks_usec()
		_advance(pop)
		worst = maxi(worst, Time.get_ticks_usec() - before)
	_worst_frame_us = maxi(_worst_frame_us, worst)
	# the report describes the frame that has just finished, not the one before it
	_generations_last = _generations
	_unloads_last = _unloads
	_frame_us = Time.get_ticks_usec() - pass_started
	_worst_pass_us = maxi(_worst_pass_us, _frame_us)


func set_seed(value: int) -> void:
	if value == _seed:
		return
	_seed = value
	settings.world_seed = value
	# a different seed is a different universe: what the old one had changed does
	# not describe anything in this one. Release before clearing, because releasing
	# asks each live object for its state and that would write the old world into
	# the new store.
	clear()
	_store.clear()


func get_seed() -> int:
	return _seed


func clear() -> void:
	for pop in _pops:
		for key in pop.chunks.keys():
			_release(pop, key)
		pop.chunks.clear()
		pop.barren.clear()
		pop.queued.clear()
		pop.closing.clear()
	_generations = 0
	_generations_last = 0
	_unloads = 0
	_unloads_last = 0


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


## Chunks that have been generated and came out empty. They hold no nodes, but
## they are part of the loaded window all the same.
func barren_count() -> int:
	var n := 0
	for pop in _pops:
		n += pop.barren.size()
	return n


## The population with this label, or null. Labels are the identity the rest of
## the game uses (`bodies_of`, the HUD, the debug panel), so it is the right key
## for a lookup from outside.
func _pop_of(label: String) -> Population:
	for pop in _pops:
		if pop.res.label == label:
			return pop
	return null


## Settings may legitimately be missing on a node that has never run `_ready` -
## a test that only instantiates the script, for instance - and a report is not
## worth a crash.
func _chunk_size_px() -> float:
	return maxf(settings.chunk_size, 16.0) if settings != null else 1024.0


## How many chunks one frame may start. Never zero: a field that can build nothing
## is a field that never fills.
func _generation_cap() -> int:
	return maxi(int(settings.max_chunk_generations_per_frame), 1) if settings != null else 4


## What the generator is doing right now, and what it cost. The frame figure is a
## running maximum since the last `reset_report()`, which is what an endurance run
## needs to catch: a build hitch only happens once, on the chunk that comes first.
func stats() -> Dictionary:
	var kinds := {}
	var rejects := 0
	var categories := {"asteroid": 0, "debris": 0, "decorative": 0}
	for pop in _pops:
		kinds[pop.res.label] = {
			"live": pop.live, "chunks": pop.chunks.size(),
			"barren": pop.barren.size(),
			"solid": pop.res.physics,
			"pooled": pop.pool_bodies.size() + pop.pool_sprites.size(),
			"us": pop.build_us,
		}
		var category := pop.res.object_kind
		if not categories.has(category):
			category = "decorative"
		categories[category] += pop.live
	var worst_chunk := 0
	for pop in _pops:
		worst_chunk = maxi(worst_chunk, pop.worst_chunk_us)
	var size := _chunk_size_px()
	return {
		"seed": _seed, "live": live_count(), "chunks": chunk_count(),
		"kinds": kinds, "categories": categories,
		"worst_frame_us": _worst_frame_us, "pooled_nodes": pooled_nodes(),
		# the whole pass, not only the build half of it
		"frame_us": _frame_us, "worst_pass_us": _worst_pass_us,
		# the streaming report: how much of the world exists, how much is waiting,
		# and how wide the window that decides it is
		"states": chunk_state_counts(),
		"generations": _generations_last, "unloads": _unloads_last,
		"objects_created": _created_total,
		"worst_chunk_us": worst_chunk,
		"chunk_size": size,
		"load_px": settings.look_ahead_chunks * size if settings != null else 0.0,
		"preload_px": settings.preload_chunks * size if settings != null else 0.0,
		"unload_px": settings.drop_behind_chunks * size if settings != null else 0.0,
		"state_chunks": _store.chunk_count(),
		"state_objects": _store.object_total(),
	}


func pooled_nodes() -> int:
	var n := 0
	for pop in _pops:
		n += pop.pool_chunks.size() + pop.pool_bodies.size() + pop.pool_sprites.size()
	return n


func reset_report() -> void:
	_worst_frame_us = 0
	_worst_pass_us = 0
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


# ---------------------------------------------------------------- chunk report

## The names the field streams, in settings order. Each one is a plane: its own
## lattice, its own chunk size, its own parallax. The label is also the `category`
## half of every chunk seed, so it has to be stable across builds - renaming a
## population re-rolls the world built from it.
func plane_labels() -> Array[String]:
	var out: Array[String] = []
	for pop in _pops:
		out.append(pop.res.label)
	return out


## The plane solid objects live on: the first population with `physics`. "Which
## chunk is the ship in" means this one, because the other planes are distant
## silhouettes whose chunks are not where the hull is.
func gameplay_plane() -> String:
	# The asteroid plane is the reference gameplay plane even when another solid
	# population is planned first for budget fairness.
	for pop in _pops:
		if pop.res.physics and pop.res.label == "asteroids":
			return pop.res.label
	for pop in _pops:
		if pop.res.physics:
			return pop.res.label
	return _pops[0].res.label if not _pops.is_empty() else ""


## The point every plane scrolls around, as the field last saw it. One frame behind
## a teleport by nature - the window is rebuilt in `_physics_process` - and the
## honest answer to "where does the field think the camera is".
func view_point() -> Vector2:
	return _view


## The chunk size the settings name, in world pixels. This is the reference grid
## `ship_chunk()` reports on; a streamed plane may use a larger chunk of its own,
## because a sparse population needs a chunk that can hold one of its lattice
## cells without changing its spacing.
func chunk_size_px() -> float:
	return _chunk_size_px()


## The chunk the ship is in, on the `chunk_size` world grid. Deliberately computed
## from a position rather than remembered: a teleport, a respawn and a test that
## never flew here must all get the same answer.
func ship_chunk(at: Vector2 = Vector2.INF) -> Vector2i:
	var p := _view
	if at.is_finite():
		p = at
	var size := Vector2(_chunk_size_px(), _chunk_size_px())
	return CHUNK.key_at(p, size)


func chunk_id(key: Vector2i, kind_label: String) -> String:
	return CHUNK.id_of(key, kind_label)


## `ChunkSeed = Hash(world_seed, chunk_x, chunk_y, category)`, for one plane's
## chunk. Computed, never stored: the same coordinate has to answer the same
## number in a fresh process, after a reload, and in a test that only ever loaded
## the script.
func chunk_seed(key: Vector2i, kind_label: String) -> int:
	var pop := _pop_of(kind_label)
	if pop == null:
		return 0
	return CHUNK.seed_of(key, pop.res.salt, _seed)


## The pattern-space rectangle a chunk covers. For a solid plane this is a true
## world rectangle; for a distant one the plane is shifted on screen as the ship
## flies, and `chunk_view_bounds()` is the rectangle's place in the world right now.
func chunk_bounds(key: Vector2i, kind_label: String) -> Rect2:
	var pop := _pop_of(kind_label)
	if pop == null:
		return Rect2()
	return Rect2(Vector2(key) * pop.chunk_px, pop.chunk_px)


func chunk_view_bounds(key: Vector2i, kind_label: String) -> Rect2:
	var pop := _pop_of(kind_label)
	if pop == null:
		return Rect2()
	var shift := (1.0 - pop.res.parallax) * _view
	return Rect2(Vector2(key) * pop.chunk_px + shift, pop.chunk_px)


## What the chunk is doing right now. An empty chunk is ACTIVE: it has been
## generated, there is simply nothing in it, and re-planning it every frame would
## be the same work with the same answer.
func chunk_state(key: Vector2i, kind_label: String) -> int:
	var pop := _pop_of(kind_label)
	if pop == null:
		return CHUNK.State.UNLOADED
	if pop.closing.has(key):
		return CHUNK.State.UNLOADING
	if pop.chunks.has(key) or pop.barren.has(key):
		return CHUNK.State.ACTIVE
	if pop.queued.has(key):
		return CHUNK.State.GENERATING
	return CHUNK.State.UNLOADED


## How many chunks of each plane are in each state. A chunk that is on its way out
## is counted as UNLOADING rather than ACTIVE and never as both; `empty` counts the
## chunks that are loaded with nothing in them - they hold no node, but they are
## just as generated as the ones that do.
##
## There is deliberately no `unloaded` figure here. Every chunk the window wants is
## either ACTIVE, GENERATING or UNLOADING by the end of a frame, so a global
## "unloaded" count could only ever read zero and would be a number that looks like
## information. A specific chunk's UNLOADED state is what `chunk_state()` answers.
func chunk_state_counts() -> Dictionary:
	var counts := {"active": 0, "generating": 0, "unloading": 0, "empty": 0}
	for pop in _pops:
		for key in pop.chunks.keys():
			if pop.closing.has(key):
				counts["unloading"] += 1
			else:
				counts["active"] += 1
		counts["empty"] += pop.barren.size()
		counts["generating"] += pop.queued.size()
	return counts


## The stable item ids of everything alive in one chunk, sorted. This is what a
## test compares between two visits: node ids are meaningless across a rebuild,
## item ids are the same stone.
func chunk_objects(key: Vector2i, kind_label: String) -> Array[String]:
	var out: Array[String] = []
	var pop := _pop_of(kind_label)
	if pop == null or not pop.chunks.has(key):
		return out
	for child in (pop.chunks[key] as Node2D).get_children():
		var item_id := String(child.get_meta("item_id", ""))
		if not item_id.is_empty():
			out.append(item_id)
	out.sort()
	return out


## Everything about one chunk that can be known without touching its nodes.
## `objects` is empty for an unloaded chunk - what it will contain is a function
## of the seed, and nothing has to remember it.
func chunk_info(key: Vector2i, kind_label: String) -> Dictionary:
	var pop := _pop_of(kind_label)
	var state := chunk_state(key, kind_label)
	return {
		"id": chunk_id(key, kind_label),
		"plane": kind_label,
		"key": key,
		"state": state,
		"state_name": CHUNK.state_name(state),
		"seed": chunk_seed(key, kind_label),
		"bounds": chunk_bounds(key, kind_label),
		"view_bounds": chunk_view_bounds(key, kind_label),
		"size": pop.chunk_px if pop != null else Vector2.ZERO,
		"objects": chunk_objects(key, kind_label) if pop != null else [],
	}


## Every chunk that currently has a node, for the debug overlay. A rectangle per
## chunk per plane, with the colour the state asks for chosen by the caller.
func active_chunk_rects() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for pop in _pops:
		var shift := (1.0 - pop.res.parallax) * _view
		for key in pop.chunks.keys():
			out.append({
				"id": CHUNK.id_of(key, pop.res.label),
				"plane": pop.res.label,
				"key": key,
				"state": chunk_state(key, pop.res.label),
				"rect": Rect2(Vector2(key) * pop.chunk_px + shift, pop.chunk_px),
				"seed": CHUNK.seed_of(key, pop.res.salt, _seed),
			})
	return out


# ------------------------------------------------------------- remembered state

## The store itself, for a save system that wants to serialize it. Reading is safe;
## writing through it is not, because the field applies deltas at commit time and
## would never hear about a dictionary edited behind its back.
func chunk_store() -> CHUNK_STATE:
	return _store


## Mark one live object as gone for the rest of this world's life, and take it out
## of the world now. The next build of its chunk skips it, so flying away and back
## does not resurrect it. Returns false for a node this field did not create.
func remove_object(node: Node, remember := true) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	var chunk_id := String(node.get_meta("chunk_id", ""))
	var item_id := String(node.get_meta("item_id", ""))
	if chunk_id.is_empty() or item_id.is_empty():
		return false
	var pop := _pop_of(CHUNK.plane_of(chunk_id))
	if pop == null:
		return false
	var chunk := node.get_parent() as Node2D
	if chunk == null or chunk.get_parent() != self:
		return false
	var key: Vector2i = chunk.get_meta("key", Vector2i.ZERO)
	if pop.chunks.get(key) != chunk:
		return false
	if remember:
		_store.remove_object(chunk_id, item_id)
	_recycle(pop, chunk, node)
	if chunk.get_child_count() == 0:
		# the last thing in the chunk is gone: hand the empty node back and remember
		# the chunk as empty, exactly as one whose stones were all broken at build
		# time. An empty chunk node is a node the pilot can never see and the
		# scene graph still pays for.
		_release(pop, key)
		pop.barren[key] = true
	return true


## What the world remembers about one live object, or `{}` for an untouched one.
func object_state_of(node: Node) -> Dictionary:
	if node == null or not is_instance_valid(node):
		return {}
	return _store.object_state(String(node.get_meta("chunk_id", "")),
		String(node.get_meta("item_id", "")))


## Remember something about one live object. `removed` and `transform` are applied
## by the field itself the next time the chunk is built; anything else is handed to
## the object's own `world_object_restore()` if it has one. The live node is told
## immediately when it can be, and `refresh_chunk()` is what makes a change that
## only exists in the store visible without waiting for the chunk to unload.
func set_object_state_of(node: Node, state: Dictionary) -> void:
	if node == null or not is_instance_valid(node):
		return
	_store.set_object_state(String(node.get_meta("chunk_id", "")),
		String(node.get_meta("item_id", "")), state)
	if node.has_method("world_object_restore"):
		node.world_object_restore(state)


## Chunk-level state, for the mechanics that will want to remember a whole region
## at once rather than one object: what a scan found here, whether the wreck has
## already been boarded.
func chunk_data(id: String) -> Dictionary:
	return _store.chunk_data(id)


func set_chunk_data(id: String, data: Dictionary) -> void:
	_store.set_chunk_data(id, data)


## Rebuild one chunk from its seed with the remembered state applied. A mechanic
## that changes a chunk while the pilot is still in it calls this, because the
## chunk is already built and nothing would otherwise notice it until it unloads.
func refresh_chunk(id: String) -> void:
	var pop := _pop_of(CHUNK.plane_of(id))
	if pop == null:
		return
	var key := CHUNK.key_of(id)
	pop.barren.erase(key)
	if pop.chunks.has(key):
		_release(pop, key)


## Everything the world remembers, ready for a save file. The generated content is
## not in here and never will be: the seed rebuilds it, and storing it would only
## give the save and the generator two chances to disagree.
func save_state() -> Dictionary:
	return {"version": 1, "seed": _seed, "chunks": _store.to_dict()}


## Read back `save_state()`. Refuses a save from a different world, and rebuilds
## the active chunks so the restored deltas are applied now rather than on the next
## visit.
func load_state(data: Dictionary) -> bool:
	if int(data.get("seed", 0)) != _seed:
		return false
	# release first: a release asks each live object for its state, and doing that
	# after loading would write the old world back over the save
	clear()
	return _store.from_dict(data.get("chunks", {}))


# ------------------------------------------------------------------ diagnostics

## The chunk panel, as text. Kept out of the drawing code so a headless run can
## read exactly what the overlay would show, and so the numbers cannot drift
## between the thing that is measured and the thing that is printed.
func debug_lines(ship_at: Vector2 = Vector2.INF) -> Array[String]:
	var at := _view
	if ship_at.is_finite():
		at = ship_at
	var size := _chunk_size_px()
	var key := ship_chunk(at)
	var bounds := CHUNK.bounds_of(key, Vector2(size, size))
	var counts := chunk_state_counts()
	var worst := 0
	for pop in _pops:
		worst = maxi(worst, pop.worst_chunk_us)
	var load := settings.look_ahead_chunks if settings != null else 0.0
	var pre := settings.preload_chunks if settings != null else 0.0
	var drop := settings.drop_behind_chunks if settings != null else 0.0
	var lines: Array[String] = []
	lines.append("SEED      %d" % _seed)
	lines.append("SHIP      %d, %d" % [roundi(at.x), roundi(at.y)])
	lines.append("CHUNK     %d, %d  (%s)" % [key.x, key.y, gameplay_plane()])
	lines.append("REGION    %d..%d  %d..%d" % [
		roundi(bounds.position.x), roundi(bounds.end.x),
		roundi(bounds.position.y), roundi(bounds.end.y)])
	lines.append("ACTIVE    %d   GEN %d   UNLD %d" % [
		counts["active"], counts["generating"], counts["unloading"]])
	lines.append("RADII     load %.1f  preload %.1f  drop %.1f chunks" % [
		load, pre, drop])
	lines.append("          %d / %d / %d px" % [
		roundi(load * size), roundi(pre * size), roundi(drop * size)])
	lines.append("OBJECTS   %d live, %d created" % [live_count(), _created_total])
	var categories: Dictionary = stats().get("categories", {})
	lines.append("CATEGORY  asteroids %d / debris %d / decor %d" % [
		int(categories.get("asteroid", 0)), int(categories.get("debris", 0)),
		int(categories.get("decorative", 0))])
	lines.append("CHUNKS    %d nodes, %d empty" % [chunk_count(), barren_count()])
	lines.append("STATE     %d chunks, %d objects kept" % [
		_store.chunk_count(), _store.object_total()])
	lines.append("COST      pass %d us (worst %d), chunk %d us" % [
		_frame_us, _worst_pass_us, worst])
	lines.append("OPS       %d built, %d unloaded / frame" % [
		_generations_last, _unloads_last])
	return lines


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

## The frame's build work for one population: fill what is missing nearest the ship
## first, and move every chunk along the parallax shift. The unload half of the
## frame has already run, for every plane at once, in `_release_pass()`.
func _advance(pop: Population) -> void:
	var shift := (1.0 - pop.res.parallax) * _view
	_reapply_budgets(pop)
	var keep := _window(pop, shift, settings.drop_behind_chunks)
	# empty chunks hold no nodes, so they are cheap enough to clear without a
	# budget: this is bookkeeping, not a scene subtree
	for key in pop.barren.keys():
		if not keep.has_point(key):
			pop.barren.erase(key)
	pop.queued.clear()

	# Two rings, one budget. The load ring is the space the pilot is about to see
	# and is built first; the preload ring beyond it is filled with whatever the
	# frame has left. On a steady flight that is most of it; on a teleport it is
	# nothing, which is the right order either way - the new position comes first.
	var load := maxf(settings.look_ahead_chunks, 0.0)
	_build(pop, shift, load)
	if _budget > 0 and _generations < _generation_cap():
		_build(pop, shift, load + maxf(settings.preload_chunks, 0.0))

	# every chunk rides the shift, not only the ones that just appeared. Writing a
	# transform that has not changed is not free: a chunk holds frozen bodies, and
	# every write sends each of them back through the physics server's broadphase.
	# A solid plane does not move at all, so most frames this writes nothing.
	for key in pop.chunks.keys():
		var chunk: Node2D = pop.chunks[key]
		var want := Vector2(key) * pop.chunk_px + shift
		if chunk.position != want:
			chunk.position = want
	_animate(pop)


## Mark what fell out of the keep window so the release pass can see it. Nothing is
## dropped here: a chunk that has just left the window still holds its objects, and
## taking them away is the expensive half.
func _mark_closing(pop: Population, keep: Rect2i) -> void:
	for key in pop.chunks.keys():
		if not keep.has_point(key):
			pop.closing[key] = true
	for key in pop.closing.keys():
		# a chunk that came back into the window, or one that is already gone, is
		# no longer waiting for anything
		if keep.has_point(key) or not pop.chunks.has(key):
			pop.closing.erase(key)


## Hand back what fell out of the window, biggest backlog first and no more than
## `max_chunk_unloads_per_frame` of it.
##
## Two orderings matter here. The plane with the most waiting chunks goes first, so
## one busy plane cannot eat the shared budget on every frame of a long boost run -
## which is exactly how a distant plane's chunk count would grow with nothing
## looking wrong up close. Within that plane the farthest chunk goes first: a
## teleport leaves a trail, only the near end of it can ever be seen again, and the
## far end is the part that can wait.
func _release_pass() -> void:
	var cap := maxi(int(settings.max_chunk_unloads_per_frame), 1)
	while _unloads < cap:
		var pick: Population = null
		for pop in _pops:
			if pop.closing.is_empty():
				continue
			if pick == null or pop.closing.size() > pick.closing.size():
				pick = pop
		if pick == null:
			return
		var origin := _view * pick.res.parallax / pick.chunk_px
		var far := -1.0
		var key := Vector2i.ZERO
		for candidate in pick.closing.keys():
			var d: float = Vector2(candidate).distance_squared_to(origin)
			if d > far:
				far = d
				key = candidate
		pick.closing.erase(key)
		_release(pick, key)
		_unloads += 1


## One build pass over one ring: collect what is missing, nearest the ship first,
## and commit as much of it as the frame can afford.
##
## A ring rather than a radius in pixels because a plane's chunks are not square
## and not even all the same size - each population sizes its chunk from its own
## lattice - so "two chunks out" is the only margin that means the same thing for
## every plane.
func _build(pop: Population, shift: Vector2, margin: float) -> void:
	if _budget <= 0 or _generations >= _generation_cap():
		return
	var core := _window(pop, shift, 0.0)
	var build := _window(pop, shift, margin)
	var origin := (_view - shift) / pop.chunk_px
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
	want.sort_custom(func(a, b):
		return a.distance_squared_to(origin) < b.distance_squared_to(origin))
	var next := 0
	for i in want.size():
		var key: Vector2i = want[i]
		if _budget <= 0 or _generations >= _generation_cap():
			next = i
			break
		# A chunk is atomic, so this can only promise "no new chunk this frame", not
		# a hard ceiling - the worst frame costs one chunk plus whatever started
		# before the clock ran out.
		if Time.get_ticks_usec() - _frame_start > int(settings.build_microseconds):
			next = i
			break
		# the screen itself is built even when the population sits at its ceiling:
		# a hole the pilot can see is worse than one he cannot
		if pop.live >= pop.live_cap and not on_screen.has(key):
			next = i + 1
			continue
		var plans := _plan_chunk(pop, key)
		if plans.is_empty():
			pop.barren[key] = true
			next = i + 1
			continue
		var need := _needs(plans)
		if _budget < need and need <= settings.build_per_frame:
			# A chunk is committed whole or left for the next frame. Three of a
			# cluster's five stones would read as a different object than five, and a
			# chunk marked empty because the frame ran out of budget would make the
			# window depend on how the ship arrived here - which is the one thing this
			# whole file exists to avoid.
			next = i
			break
		var made := _commit(pop, key, shift, plans)
		_budget -= made
		_generations += 1
		_created_total += made
		next = i + 1
		if made == 0:
			# every object this chunk held has been remembered as gone
			pop.barren[key] = true
	# What the frame could not reach is GENERATING until it is built or the window
	# moves on. Rebuilt from the window next frame rather than carried as a queue,
	# so an entry can never outlive the reason it was made.
	for i in range(next, want.size()):
		pop.queued[want[i]] = true


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


## Turn a plan into nodes. Returns how many objects actually appeared: an object
## the state store has remembered as gone is skipped, so a chunk whose stones have
## all been broken commits nothing and is marked empty rather than kept as an
## invisible node.
func _commit(pop: Population, key: Vector2i, shift: Vector2, plans: Array) -> int:
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
	var chunk_id := CHUNK.id_of(key, pop.res.label)
	chunk.set_meta("chunk_id", chunk_id)
	var made := 0
	for plan in plans:
		for item in plan["items"]:
			var item_id := String(item["key"])
			var state := _store.object_state(chunk_id, item_id)
			if bool(state.get(CHUNK_STATE.KEY_REMOVED, false)):
				continue
			var at: Vector2 = item["u"]
			var rot: float = item["rot"]
			var moved: Variant = state.get(CHUNK_STATE.KEY_TRANSFORM, null)
			if moved is Dictionary:
				at = moved.get("u", at)
				rot = float(moved.get("rot", rot))
			var node: Node2D = _place_body(pop, chunk, item, at - origin, rot, at) \
				if pop.res.physics else _place_sprite(pop, chunk, item, at - origin, rot, at)
			if node == null:
				continue
			node.set_meta("item_id", item_id)
			node.set_meta("chunk_id", chunk_id)
			if not state.is_empty() and node.has_method("world_object_restore"):
				node.world_object_restore(state)
			made += 1
			pop.live += 1
	if made == 0:
		# nothing to show: the chunk node itself must not be kept, or an empty
		# region would hold a node for every one of its broken stones
		if chunk.get_parent() != null:
			remove_child(chunk)
		pop.pool_chunks.append(chunk)
	else:
		pop.chunks[key] = chunk
	# the sprites that just arrived have not been turned for this view yet
	pop.turn_scroll = Vector2.INF
	pop.build_us += Time.get_ticks_usec() - before
	return made


## Chunks overlapping the screen, expressed in this population's own pattern
## space: the world rect minus whatever the plane has already drifted by.
func _window(pop: Population, shift: Vector2, margin_chunks: float) -> Rect2i:
	var rect := _visible_world_rect()
	var pad := pop.chunk_px * margin_chunks
	var a := ((rect.position - shift - pad) / pop.chunk_px).floor()
	var b := ((rect.end - shift + pad) / pop.chunk_px).ceil()
	return Rect2i(Vector2i(int(a.x), int(a.y)), Vector2i(int(b.x - a.x), int(b.y - a.y)))


func _release(pop: Population, key: Vector2i) -> void:
	if not pop.chunks.has(key):
		return
	var chunk: Node2D = pop.chunks[key]
	pop.chunks.erase(key)
	pop.queued.erase(key)
	pop.closing.erase(key)
	var chunk_id := CHUNK.id_of(key, pop.res.label)
	for child in chunk.get_children():
		_remember(chunk_id, child)
		_recycle(pop, chunk, child)
	remove_child(chunk)
	pop.pool_chunks.append(chunk)


## Take one object's own account of itself before it leaves the world. This is the
## only place a node is asked, and it is asked the same way `WorldObjects` asks what
## a thing is: a method the object may have, not a class the field has heard of. An
## object with nothing to say costs one `has_method` call and leaves no record, so
## an untouched chunk never appears in the store at all.
func _remember(chunk_id: String, child: Node) -> void:
	if not settings.keep_chunk_state:
		return
	if not child.has_method("world_object_state"):
		return
	var item_id := String(child.get_meta("item_id", ""))
	if item_id.is_empty():
		return
	var state: Variant = child.world_object_state()
	if state is Dictionary and not (state as Dictionary).is_empty():
		_store.set_object_state(chunk_id, item_id, state)


## Detach one object and hand it back to its population's pool. Shared by the
## chunk release and by `remove_object`, so an object that is destroyed and one
## that is merely out of view cost the same and cannot leak.
func _recycle(pop: Population, chunk: Node2D, child: Node) -> void:
	chunk.remove_child(child)
	pop.live = maxi(pop.live - 1, 0)
	var body := child as RigidBody2D
	if body != null:
		pop.pool_bodies.append(body)
		return
	var sprite := child as Sprite2D
	if sprite != null:
		pop.pool_sprites.append(sprite)
		return
	# not a thing this field can reuse: nothing to pool, but it must not survive
	# the chunk it was in
	child.queue_free()


func _place_body(pop: Population, chunk: Node2D, item: Dictionary, local: Vector2,
		rot: float, at: Vector2) -> Node2D:
	var body: RigidBody2D = pop.pool_bodies.pop_back() \
		if not pop.pool_bodies.is_empty() else pop.res.body_scene.instantiate() as RigidBody2D
	if body == null:
		push_warning("field: %s has no body to instantiate" % pop.res.label)
		return null
	body.visible = true
	body.set_meta("u", at)
	body.set_meta("scale", item["scale"])
	body.set_meta("art", item["file"])
	body.set_meta("object_kind", pop.res.object_kind)
	# placed before it enters the tree, so the physics server never sees the body at
	# the scene's default origin for a step on its way in
	body.position = local
	body.rotation = rot
	chunk.add_child(body)
	if body.has_method("set_form"):
		body.set_form(item["id"], item["scale"], item["tint"])
	return body


func _place_sprite(pop: Population, chunk: Node2D, item: Dictionary, local: Vector2,
		rot: float, at: Vector2) -> Node2D:
	var sp: Sprite2D = pop.pool_sprites.pop_back() \
		if not pop.pool_sprites.is_empty() else Sprite2D.new()
	sp.visible = true
	sp.centered = true
	sp.texture = item["tex"]
	sp.position = local
	sp.rotation = rot
	var s: float = item["scale"]
	var flip: float = -1.0 if item["flip"] else 1.0
	sp.scale = Vector2(s, s * flip)
	sp.modulate = item["tint"]
	sp.material = EchoSpaceLayer.material_for(pop.res.add_blend)
	# the belt art was cut from a photographic plate, so it is resampled, not
	# stepped, even though the project draws everything else Nearest
	sp.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	sp.set_meta("u", at)
	sp.set_meta("base_rot", rot)
	sp.set_meta("spin", item["spin"])
	sp.set_meta("base_alpha", item["tint"].a)
	sp.set_meta("object_kind", pop.res.object_kind)
	if not pop.res.object_kind.is_empty():
		sp.add_to_group(pop.res.object_kind)
	chunk.add_child(sp)
	return sp


## Rotation and twinkle are functions of the view point rather than of elapsed
## time, so a place looks the same however you reach it and whatever the frame
## rate - the same rule the sky behind this field follows.
func _animate(pop: Population) -> void:
	if pop.res.physics or pop.res.spin_max <= 0.0:
		return
	var scroll := _view * pop.res.parallax
	if scroll == pop.turn_scroll:
		# nothing on this plane can have turned since the last pass
		return
	pop.turn_scroll = scroll
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
	var items: Array = [_item(pop, rec, scale, tint, alpha, rot, point, cell, res.salt, 0)]
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
				res.salt + 60 + i, i + 1))
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
		   rot: float, at: Vector2, cell: Vector2i, salt: int, slot: int) -> Dictionary:
	var res := pop.res
	return {
		# the stable name of this object, independent of the node that ends up
		# wearing it: its lattice cell and its place in that cell's knot. Every
		# mechanic that has to remember something about one stone - broken, scanned,
		# moved - writes it down under this name, and a rebuild months later finds
		# the same stone again. A pooled node's instance id could never do that.
		"key": "%d,%d:%d" % [cell.x, cell.y, slot],
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


## The population's two ceilings, recomputed from the settings instead of frozen at
## `rebuild()`.
##
## `rock_density_scale` already multiplies every gate on every frame, so a field
## that only moved the ceilings on a rebuild would answer a difficulty pass with
## half a change. Reading them here keeps the knob honest and costs two integer
## multiplies per population per frame.
##
## Either ceiling is soft on purpose: a chunk the pilot can see is built even at the
## limit, so the count may sit a little above it and never leaves a hole.
func _reapply_budgets(pop: Population) -> void:
	var master := settings.rock_density_scale if pop.res.physics else settings.decor_density_scale
	master = clampf(master, 0.0, 4.0)
	pop.cap = maxi(1, int(round(pop.res.max_per_chunk * master)))
	pop.live_cap = maxi(1, int(round(pop.res.max_live * master)))


## Cell size and chunk size from the distance pair: the step guarantees the
## spread, `min_distance` only pulls a candidate off its cell centre.
func _lattice(pop: Population) -> void:
	var res := pop.res
	var span := maxf(res.max_distance, res.min_distance + 1.0)
	pop.step = Vector2(span, span * 0.78)
	pop.jitter = clampf((span - res.min_distance) / span, 0.0, 1.0)
	pop.per = maxi(1, int(round(settings.chunk_size / span)))
	pop.chunk_px = pop.step * float(pop.per)
	_reapply_budgets(pop)


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
			# Asteroid art has a generated convex-piece table. A manufactured body
			# may carry its own simple hull, so its picture edge is the conservative
			# fallback instead of making the whole population invisible.
			if best > 0.0:
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
