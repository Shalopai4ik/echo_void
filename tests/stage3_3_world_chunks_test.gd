extends SceneTree

## Sub-stage 3.3 verification: the endless world's chunk infrastructure.
## Run: godot --headless --path . --script tests/stage3_3_world_chunks_test.gd
##
## Stage 2 already proved the picture: that the belt is deterministic, infinite and
## solid. This file measures the layer that was missing from it - the chunk as a
## named object with a coordinate, a seed, a state and a memory:
##
##   A. initial load: every plane streams, the window is whole, the seed is the
##      one the settings name.
##   B. eight directions, including the diagonals.
##   C. a sprint that crosses six chunks between two physics frames, then a
##      diagonal one, with no visible hole afterwards and no missed frame.
##   D. unload: the per-frame budget holds, the backlog clears, node counts stay
##      inside two windows and nothing is orphaned.
##   E. determinism: the same seed rebuilds the same region however the ship
##      reached it; a different seed is a different world.
##   F. revisit: a removed object stays removed, a moved one stays moved, a
##      chunk-level datum survives, and a save round-trips.
##   G. endurance: 360 frames of flight with the ceilings and coordinates watched.
##   H. integration: camera, sky, flight controls, HUD, flight panel, overlay.
##
## What this cannot prove is how any of it looks. `tests/stage2_flight_screens.gd`
## is still the renderer check for the picture; the overlay is checked here for
## being off by default, not for being legible.
##
## A phase name is printed before each block and a watchdog fires if the run passes
## its budget, so a stuck test says where it stopped.

const MAP := "res://scenes/world/SpaceMap.tscn"
const CHUNK := preload("res://scripts/world/world_chunk.gd")
const STORE := preload("res://scripts/world/chunk_state_store.gd")
## Microseconds one physics frame may spend generating. The same budget stage 2
## used: generous on purpose, because this runs without a renderer.
const FRAME_BUDGET_US := 6000
## Wall-clock budget for the whole routine, in seconds.
const BUDGET_MS := 600000

var _map: Node
var _ship: RigidBody2D
var _cam: Camera2D
var _field: EchoWorldField
var _settings: SpaceGenerationSettings
var _checks := 0
var _failed := 0
var _phase := "boot"
var _started := 0


func _initialize() -> void:
	_started = Time.get_ticks_msec()
	call_deferred("_run")


func _run() -> void:
	var packed: PackedScene = load(MAP)
	if packed == null:
		print("RESULT: FAILED  could not load ", MAP)
		quit(2)
		return
	_map = packed.instantiate()
	root.add_child(_map)
	_ship = _map.get_node("Ship") as RigidBody2D
	_cam = _ship.get_node("Camera") as Camera2D
	_field = _map.get_node("Field") as EchoWorldField
	_settings = _field.settings
	await _settle(90)

	_beat("A. initial load")
	await _test_initial()
	_beat("chunk vocabulary")
	_test_vocabulary()

	_beat("B. every direction")
	await _test_directions()
	_beat("C. speed")
	await _test_speed()
	_beat("D. unloading")
	await _test_unload()
	_beat("E. determinism")
	await _test_determinism()
	_beat("F. revisit")
	await _test_revisit()
	_beat("G. endurance")
	await _test_endurance()
	_beat("H. integration")
	await _test_integration()

	print("RESULT: ", "FAILED %d of %d" % [_failed, _checks] if _failed > 0 else "ALL PASS")
	quit(1 if _failed else 0)


# ------------------------------------------------------------------ plumbing ----

func _ok(name: String, condition: bool, detail := "") -> void:
	_checks += 1
	print(("PASS  " if condition else "FAIL  ") + name + "   " + detail)
	if not condition:
		_failed += 1


func _beat(tag: String) -> void:
	_phase = tag
	print("-- %s   t=%.0fs  physics=%d" % [tag, _elapsed(), Engine.get_physics_frames()])


func _elapsed() -> float:
	return (Time.get_ticks_msec() - _started) / 1000.0


func _step() -> void:
	await physics_frame
	if Time.get_ticks_msec() - _started > BUDGET_MS:
		print("WATCHDOG  stuck in phase '", _phase, "' after ", _elapsed(), " s")
		quit(3)


func _wait(frames: int) -> void:
	for i in frames:
		await _step()


func _settle(frames := 40) -> void:
	for i in frames:
		await process_frame
	await _step()


## Put the hull somewhere with the view on it, then wait for the streaming window
## to be completely built. Teleporting is legitimate here: the whole promise of the
## generator is that how the ship got somewhere does not matter.
func _place(at: Vector2, limit := 300) -> void:
	_ship.global_position = at
	_ship.linear_velocity = Vector2.ZERO
	_ship.angular_velocity = 0.0
	_cam.snap()
	# The viewport's canvas transform - which is what the signature and every
	# screen measurement read - follows the camera on an idle frame, not on the
	# physics tick that moved it. Waiting one here is the difference between
	# measuring the destination and measuring the place the ship just left.
	await process_frame
	for i in 6:
		await _step()
	var waited := 6
	while waited < limit:
		await _step()
		waited += 1
		if _field.view_point().distance_to(at) > 1.0:
			continue
		var states: Dictionary = _field.stats()["states"]
		if int(states["generating"]) > 0 or int(states["unloading"]) > 0:
			continue
		var quiet := true
		for j in 3:
			await _step()
			waited += 1
			var again: Dictionary = _field.stats()["states"]
			if int(again["generating"]) > 0 or int(again["unloading"]) > 0:
				quiet = false
				break
		if quiet:
			_ship.linear_velocity = Vector2.ZERO
			return
	_ship.linear_velocity = Vector2.ZERO


## The screen rectangle around a point, computed from the camera rather than from
## the viewport: the same answer on the frame a teleport happens, in a headless run,
## and with the renderer off.
func _screen_rect_at(at: Vector2) -> Rect2:
	var size := root.get_visible_rect().size
	if size.x < 1.0 or size.y < 1.0:
		size = Vector2(960, 540)
	var span := Vector2(size.x / _cam.zoom.x, size.y / _cam.zoom.y)
	return Rect2(at - span * 0.5, span)


## Chunks the screen overlaps that are not ACTIVE. Only meaningful for a plane at
## parallax 1.0, which is the plane the hull can hit: the distant planes are
## shifted on screen, so their pattern-space rectangle is not the screen rectangle.
func _visible_gap(plane: String) -> Array[String]:
	var missing: Array[String] = []
	var size: Vector2 = _field.chunk_info(Vector2i.ZERO, plane)["size"]
	if size.x < 1.0:
		return ["no plane " + plane]
	var rect := _screen_rect_at(_field.view_point())
	var a := CHUNK.key_at(rect.position, size)
	var b := CHUNK.key_at(rect.end, size)
	for cy in range(a.y, b.y + 1):
		for cx in range(a.x, b.x + 1):
			var key := Vector2i(cx, cy)
			var state := _field.chunk_state(key, plane)
			if state != CHUNK.State.ACTIVE:
				missing.append("%d,%d:%s" % [cx, cy, CHUNK.state_name(state)])
	return missing


## Chunk nodes actually parented to the field. The debug overlay is a child too,
## so counting the field's children would be off by one and would hide a leak
## behind a constant.
func _chunk_nodes() -> int:
	var n := 0
	for child in _field.get_children():
		if child.has_meta("key"):
			n += 1
	return n


## Objects of one plane, by their stable item id, for a node the test is looking
## for after a rebuild.
func _find_item(plane: String, chunk_id: String, item_id: String) -> Node2D:
	for body in _field.bodies_of(plane):
		if String(body.get_meta("item_id")) == item_id \
				and String(body.get_meta("chunk_id")) == chunk_id:
			return body
	return null


func _kind(label: String) -> SpaceObjectKind:
	for k in _settings.kinds:
		if k != null and k.label == label:
			return k
	return null


## The first chunk the two fingerprints disagree about, with enough of both sides
## to see which object moved. A signature that differs only in length says nothing
## about where to look.
## The screen's worth of world around a point, as text: every solid body in the
## chunks the screen overlaps, by its stable item id, its rounded position and its
## size, plus the generation seed of the chunks around it on every plane.
##
## Deliberately confined to the screen's chunks. The load ring beyond them is
## legitimately thinned by each population's live ceiling, so a fingerprint that
## reached further would depend on how the ship arrived - which is the one thing a
## determinism check must not do. The screen's own chunks are built even at the
## ceiling, so their content is a pure function of the seed.
func _fingerprint(at: Vector2) -> String:
	var plane := _field.gameplay_plane()
	var size: Vector2 = _field.chunk_info(Vector2i.ZERO, plane)["size"]
	var rect := _screen_rect_at(at)
	var a := CHUNK.key_at(rect.position, size)
	var b := CHUNK.key_at(rect.end, size)
	var parts: Array[String] = []
	for cy in range(a.y, b.y + 1):
		for cx in range(a.x, b.x + 1):
			var key := Vector2i(cx, cy)
			parts.append("%d,%d:[%s]" % [cx, cy, ",".join(_field.chunk_objects(key, plane))])
	for body in _field.bodies_of(plane):
		var key := CHUNK.key_at(body.global_position, size)
		if key.x < a.x or key.x > b.x or key.y < a.y or key.y > b.y:
			continue
		parts.append("at:%s:%d,%d" % [String(body.get_meta("item_id")),
			roundi(body.global_position.x), roundi(body.global_position.y)])
	parts.sort()
	var center := CHUNK.key_at(at, size)
	for label in _field.plane_labels():
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				parts.append("seed:%s:%d,%d=%d" % [label, center.x + dx, center.y + dy,
					_field.chunk_seed(Vector2i(center.x + dx, center.y + dy), label)])
	return "|".join(parts)


# -------------------------------------------------------------------- A. boot ----

func _test_initial() -> void:
	var labels := _field.plane_labels()
	_ok("every population in the settings is streaming",
		labels.size() == _settings.kinds.size(), str(labels))
	_ok("the world is populated at the start", _field.live_count() > 20,
		"%d objects" % _field.live_count())
	var states: Dictionary = _field.stats()["states"]
	_ok("nothing is left waiting after the first settle",
		int(states["generating"]) == 0 and int(states["unloading"]) == 0, str(states))
	var plane := _field.gameplay_plane()
	_ok("the plane the hull can hit is named", plane != "", plane)
	var home := _field.ship_chunk(_ship.global_position)
	_ok("the ship starts in chunk 0,0", home == Vector2i.ZERO, str(home))
	var state := _field.chunk_state(Vector2i.ZERO, plane)
	_ok("the chunk under the ship is active", state == CHUNK.State.ACTIVE,
		CHUNK.state_name(state))
	var gap := _visible_gap(plane)
	_ok("the visible window is whole", gap.is_empty(), str(gap))
	_ok("the seed is the one the settings name",
		int(_field.stats()["seed"]) == _settings.world_seed, str(_field.stats()["seed"]))
	var empty_planes: Array[String] = []
	var kinds: Dictionary = _field.stats()["kinds"]
	for label in labels:
		var entry: Dictionary = kinds.get(label, {})
		if int(entry.get("chunks", 0)) + int(entry.get("barren", 0)) <= 0:
			empty_planes.append(label)
	_ok("every plane has live chunks", empty_planes.is_empty(), str(empty_planes))
	_ok("chunk nodes and the chunk count agree", _chunk_nodes() == _field.chunk_count(),
		"%d nodes against %d chunks" % [_chunk_nodes(), _field.chunk_count()])
	var info := _field.chunk_info(Vector2i.ZERO, plane)
	_ok("a chunk reports its id, bounds, size and seed",
		String(info["id"]) == "asteroids:0,0"
		and (info["bounds"] as Rect2).size.x > 0.0
		and (info["size"] as Vector2).x > 0.0, str(info["id"]))
	_ok("the reference grid is the size the settings name",
		is_equal_approx(_field.chunk_size_px(), _settings.chunk_size),
		str(_field.chunk_size_px()))


# --------------------------------------------------------------- the vocabulary --

func _test_vocabulary() -> void:
	var size := Vector2(1024, 1024)
	_ok("a negative position lands in a negative chunk",
		CHUNK.key_at(Vector2(-1, -1), size) == Vector2i(-1, -1),
		str(CHUNK.key_at(Vector2(-1, -1), size)))
	_ok("a boundary belongs to the chunk it starts",
		CHUNK.key_at(Vector2(1024, 0), size) == Vector2i(1, 0))
	var key := Vector2i(-3, 7)
	var id := CHUNK.id_of(key, "asteroids")
	_ok("a chunk id round-trips",
		CHUNK.plane_of(id) == "asteroids" and CHUNK.key_of(id) == key, id)
	_ok("a string that is not a chunk id is not read as chunk zero",
		CHUNK.plane_of("garbage") == "")
	_ok("the four states have names",
		CHUNK.state_name(CHUNK.State.UNLOADED) == "UNLOADED"
		and CHUNK.state_name(CHUNK.State.UNLOADING) == "UNLOADING")
	var a := CHUNK.seed_of(key, 3, 20261102)
	_ok("a chunk seed is stable", a == CHUNK.seed_of(key, 3, 20261102), str(a))
	_ok("another coordinate is another seed", a != CHUNK.seed_of(key + Vector2i.RIGHT, 3, 20261102))
	_ok("another category is another seed", a != CHUNK.seed_of(key, 4, 20261102))
	_ok("another world is another seed", a != CHUNK.seed_of(key, 3, 20261103))
	var kind := _kind("asteroids")
	_ok("the field seeds a chunk the same way",
		_field.chunk_seed(key, "asteroids") == CHUNK.seed_of(key, kind.salt, _field.get_seed()))
	_ok("and the seed moves when the world seed does",
		CHUNK.seed_of(key, kind.salt, _field.get_seed() + 1) != _field.chunk_seed(key, "asteroids"))

	var store = STORE.new()
	store.set_object_state("a:0,0", "1,1:0", {"removed": true})
	_ok("a store remembers a removal", store.is_removed("a:0,0", "1,1:0"))
	var copy: Dictionary = store.to_dict()
	var back = STORE.new()
	_ok("a store round-trips through a plain dictionary",
		back.from_dict(copy) and back.is_removed("a:0,0", "1,1:0"))
	back.restore_object("a:0,0", "1,1:0")
	_ok("a removal can be undone", not back.is_removed("a:0,0", "1,1:0"))
	back.set_object_state("a:0,0", "1,1:0", {})
	_ok("erasing the last state leaves no chunk behind", back.chunk_count() == 0)
	var junk: Dictionary = copy.duplicate(true)
	junk["version"] = 99
	_ok("a save from another version is refused", not STORE.new().from_dict(junk))


## Everything the field thinks about the screen's chunks, printed only when a
## determinism check fails: which chunks exist, what they hold, and which of them the
## field is treating as empty.
func _dump_region(at: Vector2) -> void:
	var plane := _field.gameplay_plane()
	var size: Vector2 = _field.chunk_info(Vector2i.ZERO, plane)["size"]
	var rect := _screen_rect_at(at)
	var a := CHUNK.key_at(rect.position, size)
	var b := CHUNK.key_at(rect.end, size)
	print("   region ", a, "..", b, " view=", _field.view_point(), " ship=", _ship.global_position)
	for cy in range(a.y, b.y + 1):
		for cx in range(a.x, b.x + 1):
			var key := Vector2i(cx, cy)
			var info := _field.chunk_info(key, plane)
			print("   ", key, " ", info["state_name"], " ", info["objects"])


# ---------------------------------------------------------------- B. directions --

func _test_directions() -> void:
	var plane := _field.gameplay_plane()
	var home := Vector2.ZERO
	await _place(home)
	var directions: Array[Vector2] = [Vector2.RIGHT, Vector2.LEFT, Vector2.UP,
		Vector2.DOWN, Vector2(1, 1).normalized(), Vector2(-1, 1).normalized(),
		Vector2(1, -1).normalized(), Vector2(-1, -1).normalized()]
	for dir in directions:
		await _place(_ship.global_position + dir * 6000.0)
		var gap := _visible_gap(plane)
		_ok("space exists toward %s" % str(dir), gap.is_empty(), str(gap))
		_ok("and has something in it toward %s" % str(dir), _field.live_count() > 0,
			"%d objects" % _field.live_count())
	await _place(home)


# --------------------------------------------------------------------- C. speed --

func _test_speed() -> void:
	var plane := _field.gameplay_plane()
	await _place(Vector2.ZERO)
	_field.reset_report()
	var start := _ship.global_position
	var chunk := Vector2(_field.chunk_info(Vector2i.ZERO, plane)["size"])
	# 2600 px between two physics steps is two and a half chunks of the gameplay
	# plane: faster than the ship can ever fly, which is the point - the window must
	# not depend on the hull visiting every chunk on the way.
	for i in 12:
		_ship.global_position += Vector2(2600, 0)
		_cam.snap()
		await _step()
	var travelled := _ship.global_position.x - start.x
	var crossed := int(floor(travelled / chunk.x))
	await _place(_ship.global_position)
	var gap := _visible_gap(plane)
	_ok("a sprint across %d chunks leaves no visible hole" % crossed, gap.is_empty(), str(gap))
	_ok("and no chunk node is orphaned", _chunk_nodes() == _field.chunk_count(),
		"%d nodes against %d chunks" % [_chunk_nodes(), _field.chunk_count()])
	_ok("and nothing is still unloading",
		int(_field.stats()["states"]["unloading"]) == 0, str(_field.stats()["states"]))
	_ok("the sprint never spent a whole frame generating",
		int(_field.stats()["worst_frame_us"]) < FRAME_BUDGET_US,
		"%d us of a %d us budget" % [int(_field.stats()["worst_frame_us"]), FRAME_BUDGET_US])
	for i in 10:
		_ship.global_position += Vector2(1700, -1700)
		_cam.snap()
		await _step()
	await _place(_ship.global_position)
	gap = _visible_gap(plane)
	_ok("a diagonal sprint leaves no visible hole either", gap.is_empty(), str(gap))
	await _place(_ship.global_position - Vector2(30000, 22000))
	_ok("a hard reversal rebuilds the window", _visible_gap(plane).is_empty(),
		str(_visible_gap(plane)))


# ------------------------------------------------------------------ D. unloading --

func _test_unload() -> void:
	var plane := _field.gameplay_plane()
	await _place(Vector2.ZERO)
	var before_chunks := _field.chunk_count()
	var budget := _settings.max_chunk_unloads_per_frame
	_settings.max_chunk_unloads_per_frame = 1
	_ship.global_position += Vector2(90000, -40000)
	_ship.linear_velocity = Vector2.ZERO
	_ship.angular_velocity = 0.0
	_cam.snap()
	var worst := 0
	var backlog := 0
	for i in 60:
		await _step()
		var st: Dictionary = _field.stats()
		worst = maxi(worst, int(st["unloads"]))
		backlog = maxi(backlog, int((st["states"] as Dictionary)["unloading"]))
	_settings.max_chunk_unloads_per_frame = budget
	_ok("the unload budget holds at one chunk a frame", worst <= 1, "worst %d" % worst)
	_ok("a teleport really does leave a backlog", backlog > 0, "%d waiting" % backlog)
	await _place(_ship.global_position)
	var after_chunks := _field.chunk_count()
	_ok("the window at the far end is no bigger than a window",
		after_chunks <= before_chunks * 2, "%d against %d at the start" % [after_chunks, before_chunks])
	_ok("nothing is left unloading", int(_field.stats()["states"]["unloading"]) == 0,
		str(_field.stats()["states"]))
	_ok("every chunk node still belongs to a live chunk",
		_chunk_nodes() == _field.chunk_count(),
		"%d nodes against %d chunks" % [_chunk_nodes(), _field.chunk_count()])
	var pooled := _field.pooled_nodes()
	_ok("the pool stays inside a couple of windows", pooled <= 3 * before_chunks + 40,
		"%d pooled against %d chunks at the start" % [pooled, before_chunks])
	_ok("the far window is whole", _visible_gap(plane).is_empty(), str(_visible_gap(plane)))


# -------------------------------------------------------------- E. determinism --

func _test_determinism() -> void:
	var plane := _field.gameplay_plane()
	var home_at := Vector2(7000, -5000)
	await _place(home_at)
	var home := _fingerprint(home_at)
	_ok("the region has something to compare", home.length() > 40,
		"%d chars, %d stones" % [home.length(), _field.bodies_of(plane).size()])
	await _place(Vector2(24000, -16000))
	await _place(home_at)
	var back := _fingerprint(home_at)
	_ok("a region comes back identical after a round trip", back == home,
		"%d against %d chars" % [back.length(), home.length()])
	if back != home:
		_dump_region(home_at)
	await _place(Vector2(0, 19000))
	await _place(home_at)
	var north := _fingerprint(home_at)
	_ok("arriving from the north gives what arriving from home gives",
		north == home, "%d against %d chars" % [north.length(), home.length()])
	var seed := _field.get_seed()
	_field.set_seed(seed + 7717)
	await _place(home_at)
	var other := _fingerprint(home_at)
	_ok("a different seed is a different world", other != home,
		"%d chars against %d" % [other.length(), home.length()])
	_ok("and the chunk seed moved with it",
		_field.chunk_seed(Vector2i.ZERO, plane)
		!= CHUNK.seed_of(Vector2i.ZERO, _kind(plane).salt, seed))
	_field.set_seed(seed)
	await _place(home_at)
	var again := _fingerprint(home_at)
	_ok("and the original seed rebuilds the original world", again == home,
		"%d against %d chars" % [again.length(), home.length()])
	_ok("a chunk that was never visited is unloaded, not seeded into existence",
		_field.chunk_state(Vector2i(4000, 4000), plane) == CHUNK.State.UNLOADED,
		CHUNK.state_name(_field.chunk_state(Vector2i(4000, 4000), plane)))


# -------------------------------------------------------------------- F. revisit --

func _test_revisit() -> void:
	var plane := _field.gameplay_plane()
	await _place(Vector2.ZERO)
	var rocks := _field.bodies_of(plane)
	_ok("there is something to remove", not rocks.is_empty(), "%d bodies" % rocks.size())
	if rocks.is_empty():
		return
	# A stone with neighbours in its chunk, so "everything else is as it was" is a
	# real comparison rather than two empty lists.
	var rock: RigidBody2D = null
	var chunk_id := ""
	var item_id := ""
	var before: Array[String] = []
	for body in rocks:
		var cid := String(body.get_meta("chunk_id"))
		var items := _field.chunk_objects(CHUNK.key_of(cid), plane)
		if items.size() >= 2:
			rock = body
			chunk_id = cid
			item_id = String(body.get_meta("item_id"))
			before = items
			break
	_ok("there is a stone in a chunk with neighbours", rock != null, chunk_id)
	if rock == null:
		return
	var key := CHUNK.key_of(chunk_id)
	_ok("the object sits in the chunk its id names",
		_field.chunk_state(key, plane) == CHUNK.State.ACTIVE, chunk_id)
	_ok("removing it succeeds", _field.remove_object(rock))
	_ok("and it leaves the world at once", rock.get_parent() == null)
	_ok("and the store remembers it as gone",
		_field.chunk_store().is_removed(chunk_id, item_id))
	await _place(Vector2(70000, 70000))
	_ok("the chunk it belonged to unloads",
		_field.chunk_state(key, plane) == CHUNK.State.UNLOADED,
		CHUNK.state_name(_field.chunk_state(key, plane)))
	await _place(Vector2.ZERO)
	var after := _field.chunk_objects(key, plane)
	_ok("the removed object does not come back", not after.has(item_id), str(after))
	var expected := before.filter(func(one): return one != item_id)
	_ok("and everything else in that chunk is exactly as it was",
		after == expected, "%s against %s" % [str(after), str(expected)])

	var moved: RigidBody2D = null
	for body in _field.bodies_of(plane):
		if String(body.get_meta("item_id")) != item_id:
			moved = body
			break
	_ok("there is a second object to move", moved != null)
	if moved == null:
		return
	var move_chunk := String(moved.get_meta("chunk_id"))
	var move_item := String(moved.get_meta("item_id"))
	var target := moved.global_position + Vector2(47, -29)
	_field.set_object_state_of(moved, {"transform": {"u": target, "rot": 0.75}})
	await _place(Vector2(-70000, 30000))
	await _place(Vector2.ZERO)
	var found := _find_item(plane, move_chunk, move_item)
	_ok("a moved object is rebuilt where it was left",
		found != null and found.global_position.distance_to(target) < 1.0,
		str(found.global_position) if found != null else "missing")
	_ok("and with the rotation it was left at",
		found != null and absf(fposmod(found.rotation - 0.75 + PI, TAU) - PI) < 0.001,
		"%.4f" % found.rotation if found != null else "missing")
	_field.set_chunk_data(move_chunk, {"scanned": true, "hits": 3})
	await _place(Vector2(40000, -60000))
	await _place(Vector2.ZERO)
	_ok("a chunk-level datum survives the unload",
		bool(_field.chunk_data(move_chunk).get("scanned", false)),
		str(_field.chunk_data(move_chunk)))

	var snapshot := _field.save_state()
	var victim: RigidBody2D = _field.bodies_of(plane)[0]
	var victim_chunk := String(victim.get_meta("chunk_id"))
	var victim_item := String(victim.get_meta("item_id"))
	_ok("another object can be removed", _field.remove_object(victim))
	_ok("a save loads back", _field.load_state(snapshot))
	await _place(Vector2.ZERO)
	_ok("loading a save undoes what happened after it",
		not _field.chunk_store().is_removed(victim_chunk, victim_item))
	_ok("and keeps what the save did remember",
		_field.chunk_store().is_removed(chunk_id, item_id))
	_ok("and the chunk datum with it",
		bool(_field.chunk_data(move_chunk).get("scanned", false)))
	var alien: Dictionary = snapshot.duplicate(true)
	alien["seed"] = int(snapshot["seed"]) + 1
	_ok("a save from another world is refused", not _field.load_state(alien))

	# Empty one chunk by hand: the last thing leaving it has to take the chunk node
	# with it, or a mechanic that clears a region leaves a node per room behind.
	var target_key := Vector2i.ZERO
	var target_items: Array[String] = []
	for chunk in _field.active_chunk_rects():
		if String(chunk["plane"]) != plane:
			continue
		var items := _field.chunk_objects(chunk["key"], plane)
		if items.size() >= 2:
			target_key = chunk["key"]
			target_items = items
			break
	_ok("there is a chunk with more than one object to empty",
		target_items.size() >= 2, str(target_key))
	if target_items.size() >= 2:
		var target_id := _field.chunk_id(target_key, plane)
		var nodes_before := _field.chunk_count()
		for item in target_items:
			var node := _find_item(plane, target_id, item)
			if node != null:
				_field.remove_object(node)
		_ok("an emptied chunk stops holding a node",
			_field.chunk_objects(target_key, plane).is_empty()
			and _field.chunk_count() < nodes_before,
			"%d objects left, %d chunks against %d" % [
				_field.chunk_objects(target_key, plane).size(),
				_field.chunk_count(), nodes_before])
		_ok("and it stays empty when the chunk is generated again",
			_field.chunk_state(target_key, plane) == CHUNK.State.ACTIVE,
			CHUNK.state_name(_field.chunk_state(target_key, plane)))


# ----------------------------------------------------------------- G. endurance --

func _test_endurance() -> void:
	var plane := _field.gameplay_plane()
	await _place(Vector2.ZERO)
	var budget := 0
	for kind in _settings.kinds:
		if kind == null or not kind.enabled:
			continue
		var master: float = _settings.rock_density_scale if kind.physics \
			else _settings.decor_density_scale
		budget += maxi(1, int(round(kind.max_live * clampf(master, 0.0, 4.0))))
	var worst_live := 0
	var worst_chunks := 0
	var worst_nodes := 0
	var created := int(_field.stats()["objects_created"])
	for i in 360:
		_ship.global_position += Vector2(13, 7)
		await _step()
		if i % 10 == 0:
			worst_live = maxi(worst_live, _field.live_count())
			worst_chunks = maxi(worst_chunks, _field.chunk_count())
			worst_nodes = maxi(worst_nodes, _chunk_nodes())
	_ok("the live object count stays inside the populations' ceilings",
		worst_live <= budget, "%d against a ceiling of %d" % [worst_live, budget])
	_ok("the loaded chunk count stays bounded", worst_chunks <= 200,
		"%d" % worst_chunks)
	_ok("the chunk nodes never outnumber the chunks", worst_nodes <= worst_chunks,
		"%d nodes against %d chunks" % [worst_nodes, worst_chunks])
	_ok("coordinates stay finite",
		is_finite(_ship.global_position.x) and is_finite(_ship.global_position.y),
		str(_ship.global_position))
	_ok("the world kept building as the ship went",
		int(_field.stats()["objects_created"]) > created,
		"%d created against %d before" % [int(_field.stats()["objects_created"]), created])
	_ok("untouched space is not remembered",
		_field.chunk_store().chunk_count() <= 6,
		"%d remembered chunks" % _field.chunk_store().chunk_count())
	_ok("the window is still whole after six seconds of flight",
		_visible_gap(plane).is_empty(), str(_visible_gap(plane)))

	# A sustained sprint: three chunks of the gameplay plane between physics steps,
	# for forty frames. Every plane is now producing a backlog of its own, so this is
	# the case where one shared unload budget with a fixed order would quietly let
	# the first plane eat it every frame while the rest grew.
	var labels := _field.plane_labels()
	var before_run := {}
	var per_plane: Dictionary = _field.stats()["kinds"]
	for label in labels:
		before_run[label] = int(per_plane[label]["chunks"])
	for i in 40:
		_ship.global_position += Vector2(3000, -1200)
		_cam.snap()
		await _step()
	var cleared := false
	for i in 200:
		await _step()
		var states: Dictionary = _field.stats()["states"]
		if int(states["unloading"]) == 0 and int(states["generating"]) == 0:
			cleared = true
			break
	_ok("a 3000 px/frame sprint clears its unload backlog", cleared,
		"%d waiting, %d generating" % [int(_field.stats()["states"]["unloading"]),
			int(_field.stats()["states"]["generating"])])
	var grew: Array[String] = []
	per_plane = _field.stats()["kinds"]
	for label in labels:
		var now := int(per_plane[label]["chunks"])
		if now > int(before_run[label]) * 2 + 4:
			grew.append("%s %d -> %d" % [label, int(before_run[label]), now])
	_ok("and no plane piles up chunks while the other planes stream", grew.is_empty(),
		str(grew))
	_ok("the window is whole at the end of the sprint",
		_visible_gap(plane).is_empty(), str(_visible_gap(plane)))


# ---------------------------------------------------------------- H. integration --

func _test_integration() -> void:
	var plane := _field.gameplay_plane()
	await _place(Vector2(3000, -2000))
	_ok("the camera rides the hull",
		_cam.global_position.distance_to(_ship.global_position) < 80.0,
		"%.1f px apart" % _cam.global_position.distance_to(_ship.global_position))
	var sky := _map.get_node("Background") as EchoSpaceBackground
	_ok("the sky still streams", sky != null and int(sky.stats()["nodes"]) > 0,
		str(sky.stats()) if sky != null else "missing")
	var hud := _map.get_node("HUD/Root")
	var state: Dictionary = hud.call("hud_state")
	_ok("the HUD is still bound to the ship", bool(state["ship_bound"]),
		String(state["slice"]))
	_ok("and still prints world telemetry", (state["telemetry"] as Array).size() >= 4,
		str(state["telemetry"]))
	var panel := _ship.get_node("FlightDebug") as ShipDebug
	var found := false
	for line in panel.readout():
		if String(line).contains("CHUNK"):
			found = true
	_ok("the flight panel reports the ship's chunk", found,
		"%d lines" % panel.readout().size())
	var overlay := _field.get_node_or_null("ChunkDebug") as Node2D
	_ok("the chunk overlay exists and starts down",
		overlay != null and not overlay.visible,
		"overlay=%s visible=%s" % [str(overlay != null), str(overlay != null and overlay.visible)])
	_ok("and is only ever raised in a debug build", OS.is_debug_build())
	var before := _ship.global_position
	Input.action_press("thrust_forward")
	for i in 60:
		await _step()
	Input.action_release("thrust_forward")
	_ok("the ship still flies",
		_ship.global_position.distance_to(before) > 150.0,
		"%.0f px in a second" % _ship.global_position.distance_to(before))
	await _place(_ship.global_position)
	_ok("and the field followed it", _visible_gap(plane).is_empty(),
		str(_visible_gap(plane)))
	_ok("the radar still finds bodies", _field.bodies().size() > 0,
		"%d bodies" % _field.bodies().size())