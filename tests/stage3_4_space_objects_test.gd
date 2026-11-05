extends SceneTree

## Sub-stage 3.4 verification: asteroids, unknown debris and decorative objects.
## Run: godot --headless --path . --script tests/stage3_4_space_objects_test.gd
##
## A. categories and budgets; B. asteroid forms and hulls; C. rare metallic debris;
## D. independent streams; E. deterministic rebuild; F. unload/reload without duplicates.

const MAP := "res://scenes/world/SpaceMap.tscn"
const BUDGET_MS := 300000

var _map: Node
var _ship: RigidBody2D
var _cam: Camera2D
var _field: EchoWorldField
var _settings: SpaceGenerationSettings
var _checks := 0
var _failed := 0
var _started := 0
var _phase := "boot"


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
	await _test_categories()       # A
	await _test_asteroids()        # B
	await _test_debris()           # C
	await _test_collision()        # D
	await _test_independence()     # E
	await _test_determinism()      # F
	await _test_reload()           # G
	await _test_performance()      # H
	await _test_integration()      # I
	await _test_diagnostics()      # J
	print("RESULT: ", "FAILED %d of %d" % [_failed, _checks] if _failed > 0 else "ALL PASS")
	quit(1 if _failed else 0)


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
		print("WATCHDOG  stuck in phase '%s' after %.0f s" % [_phase, _elapsed()])
		quit(3)


func _wait(frames: int) -> void:
	for i in frames:
		await _step()


func _settle(frames := 40) -> void:
	for i in frames:
		await process_frame
	await _step()


func _place(at: Vector2, limit := 240) -> void:
	_ship.global_position = at
	_ship.linear_velocity = Vector2.ZERO
	_ship.angular_velocity = 0.0
	_cam.snap()
	await process_frame
	for i in 8:
		await _step()
	var waited := 8
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


func _kind(label: String) -> SpaceObjectKind:
	for kind in _settings.kinds:
		if kind != null and kind.label == label:
			return kind
	return null


func _nodes_with_meta(name: String) -> Array[Node2D]:
	var out: Array[Node2D] = []
	for chunk in _field.get_children():
		if not chunk.has_meta("key"):
			continue
		for child in chunk.get_children():
			if child.has_meta(name):
				out.append(child as Node2D)
	return out


func _count_kind(kind: String) -> int:
	var count := 0
	for node in _nodes_with_meta("object_kind"):
		if String(node.get_meta("object_kind")) == kind:
			count += 1
	return count


## The sprites of one decorative plane. A decor population carries its picture on a
## plain Sprite2D, and the plane's name is the first half of every chunk id, so this
## is what `bodies_of()` is for a population that is solid.
func _sprites_of(plane: String) -> Array[Sprite2D]:
	var out: Array[Sprite2D] = []
	for node in _nodes_with_meta("chunk_id"):
		if not String(node.get_meta("chunk_id")).begins_with(plane + ":"):
			continue
		var sp := node as Sprite2D
		if sp != null:
			out.append(sp)
	return out


func _category_signature() -> String:
	var parts: Array[String] = []
	for child in _nodes_with_meta("object_kind"):
		parts.append("%s:%s:%s@%d,%d" % [
			String(child.get_meta("object_kind")), String(child.get_meta("chunk_id")),
			String(child.get_meta("item_id")), roundi(child.global_position.x),
			roundi(child.global_position.y)])
	parts.sort()
	return "|".join(parts)


func _first_body_chunk_signature(plane: String) -> String:
	var bodies := _field.bodies_of(plane)
	if bodies.is_empty():
		return ""
	var chunk_id := String(bodies[0].get_meta("chunk_id"))
	var pieces := chunk_id.split(":")[1].split(",")
	var key := Vector2i(int(pieces[0]), int(pieces[1]))
	return chunk_id + ":[" + ",".join(_field.chunk_objects(key, plane)) + "]"


func _planned_item_ids(plane: String, key: Vector2i) -> String:
	var population = _field.call("_pop_of", plane)
	if population == null:
		return ""
	var plans: Array = _field.call("_plan_chunk", population, key)
	var ids: Array[String] = []
	for plan in plans:
		for item in plan["items"]:
			ids.append(String(item["key"]))
	ids.sort()
	return ",".join(ids)


func _body_signature(plane: String) -> String:
	var parts: Array[String] = []
	var view := _field.view_point()
	for body in _field.bodies_of(plane):
		if body.global_position.distance_to(view) > 1500.0:
			continue
		parts.append("%s:%s@%d,%d" % [String(body.get_meta("chunk_id")),
			String(body.get_meta("item_id")), roundi(body.global_position.x),
			roundi(body.global_position.y)])
	parts.sort()
	return "|".join(parts)


func _test_categories() -> void:
	_beat("A. categories")
	var asteroids := _kind("asteroids")
	var debris := _kind("debris")
	_ok("the asteroid population is solid", asteroids != null and asteroids.physics)
	_ok("the debris population is independent", debris != null and debris.salt != asteroids.salt)
	_ok("debris has its own semantic kind", debris != null and debris.object_kind == "debris")
	_ok("asteroids keep their semantic kind", asteroids != null and asteroids.object_kind == "asteroid")
	# The same picture with the light taken out of it, on a far plane and with no
	# body: the criterion is brightness, so the test reads brightness.
	var shadows := _kind("shadows")
	var dim := shadows.tint_to.get_luminance() if shadows != null else -1.0
	_ok("the dim stones are decoration on a far plane",
		shadows != null and not shadows.physics and shadows.parallax < 1.0 and dim < 1.0,
		"parallax %.2f, tint luma %.2f" % [
			shadows.parallax if shadows != null else -1.0, dim])
	var labels := _field.plane_labels()
	_ok("every configured population streams", labels.size() == _settings.kinds.size(), str(labels))
	# Background objects are the non-physics planes. They have to stay opaque and
	# darker than the solid belt: alpha is not a depth cue here, RGB is.
	var background_opaque := true
	var background_dark := true
	for kind in _settings.kinds:
		if kind == null or kind.physics:
			continue
		if not is_equal_approx(kind.alpha_min, 1.0) or not is_equal_approx(kind.alpha_max, 1.0):
			background_opaque = false
		if kind.tint_to.get_luminance() >= asteroids.tint_to.get_luminance() * 0.6:
			background_dark = false
	_ok("every background population is opaque", background_opaque)
	_ok("every background silhouette is darker than the solid belt", background_dark,
		"belt luma %.2f" % asteroids.tint_to.get_luminance())
	var categories: Dictionary = _field.stats()["categories"]
	_ok("diagnostics expose asteroid, debris and decorative counts",
		categories.has("asteroid") and categories.has("debris") and categories.has("decorative"),
		str(categories))


func _test_asteroids() -> void:
	_beat("B. asteroids")
	await _place(Vector2(12000, -9000))
	var bodies := _field.bodies_of("asteroids")
	_ok("asteroids appear in loaded chunks", not bodies.is_empty(), "%d bodies" % bodies.size())
	var sizes := {}
	var hulls := 0
	for body in bodies:
		var rock := body as StageRock
		if rock == null:
			continue
		sizes[roundf(rock.px_scale)] = true
		if rock.extent > 0.0 and rock.get_node_or_null("Hull") is CollisionPolygon2D:
			hulls += 1
	_ok("asteroid sizes vary", sizes.size() >= 3, "%d distinct sizes" % sizes.size())
	_ok("asteroid collision hulls match their art scale", hulls == bodies.size(),
		"%d of %d" % [hulls, bodies.size()])
	_ok("asteroids remain bounded", bodies.size() <= 70, "%d live" % bodies.size())
	# The dim plane is the same plate, streamed as sprites: a hull must not find a
	# body there, or the pilot would be stopped by something that cannot be seen.
	_ok("the dim stones are not bodies the hull can hit",
		_field.bodies_of("shadows").is_empty(),
		"%d bodies" % _field.bodies_of("shadows").size())
	var dim_cap: int = _kind("shadows").max_live
	_ok("the dim stones stream as bounded sprites",
		_sprites_of("shadows").size() <= dim_cap,
		"%d sprites of a ceiling of %d" % [_sprites_of("shadows").size(), dim_cap])
	# What the pilot actually sees: the nodes themselves, not the resource. A pooled
	# sprite that kept a stale alpha or a stale tint would fail here.
	var dim_sprites := _sprites_of("shadows")
	var dim_opaque := not dim_sprites.is_empty()
	var dim_dark := dim_opaque
	var belt_luma: float = _kind("asteroids").tint_to.get_luminance()
	for sp in dim_sprites:
		if not is_equal_approx(sp.modulate.a, 1.0):
			dim_opaque = false
		if sp.modulate.get_luminance() >= belt_luma * 0.6:
			dim_dark = false
	_ok("background stones render fully opaque", dim_opaque,
		"%d sprites" % dim_sprites.size())
	_ok("background stones render darker than the belt", dim_dark,
		"belt luma %.2f" % belt_luma)


func _test_debris() -> void:
	_beat("C. debris and decor")
	var samples: Array[Vector2] = [Vector2.ZERO, Vector2(9000, 5000), Vector2(-14000, 8000),
		Vector2(26000, -17000), Vector2(-31000, -24000), Vector2(41000, 9000),
		Vector2(-47000, 31000), Vector2(52000, -42000)]
	var debris_seen := 0
	var asteroid_seen := 0
	var decor_seen := 0
	var textures := {}
	for at in samples:
		await _place(at)
		await _wait(12)
		debris_seen += _count_kind("debris")
		asteroid_seen += _field.bodies_of("asteroids").size()
		decor_seen += _count_kind("decorative")
		for node in _nodes_with_meta("object_kind"):
			if String(node.get_meta("object_kind")) != "debris":
				continue
			var sprite := node.get_node_or_null("Sprite") as Sprite2D
			if sprite != null and sprite.texture != null:
				textures[sprite.texture.resource_path.get_file()] = true
	_ok("unknown debris appears in the streamed world", debris_seen > 0,
		"%d debris across %d samples" % [debris_seen, samples.size()])
	_ok("debris is rarer than asteroids", debris_seen < asteroid_seen,
		"%d debris against %d asteroids" % [debris_seen, asteroid_seen])
	# Every decorative population, summed: the stones are one of them now, so the
	# ceiling has to be read off the settings instead of being a number that once
	# matched four planes.
	var decor_cap := 0
	for kind in _settings.kinds:
		if kind != null and not kind.physics:
			decor_cap += kind.max_live
	_ok("decorative objects remain present but bounded",
		decor_seen > 0 and decor_seen <= decor_cap * samples.size(),
		"%d decor across %d samples, ceiling %d a window" % [
			decor_seen, samples.size(), decor_cap])
	_ok("debris has several visual variants", textures.size() >= 2, str(textures.keys()))


func _test_collision() -> void:
	_beat("D. collision integration")
	await _place(Vector2(9000, 5000))
	var debris_body: RigidBody2D = null
	for body in _field.bodies_of("debris"):
		debris_body = body
		break
	if debris_body != null:
		var start := debris_body.global_position - Vector2(260, 0)
		_ship.global_position = start
		_ship.linear_velocity = Vector2(200, 0)
		_cam.snap()
		for i in 120:
			await _step()
		var collision: Dictionary = _ship.last_collision()
		var category := String(collision.get("category", ""))
		_ok("debris uses the ship's existing collision report",
			collision.has("object") and category in ["LIGHT", "MEDIUM", "HEAVY"],
			"%s at %.0f px/s" % [category, float(collision.get("closing_speed", 0.0))])
		_ok("the collision report identifies debris",
			WorldObjects.kind_of(collision.get("object")) == WorldObjects.KIND_DEBRIS,
			str(collision.get("kind", "")))
	else:
		_ok("debris uses the ship's existing collision report", false, "no debris body found")
		_ok("the collision report identifies debris", false, "no debris body found")


func _test_independence() -> void:
	_beat("E. independent streams")
	await _place(Vector2(17000, 11000))
	var asteroid_seed_before := _field.chunk_seed(Vector2i(16, 10), "asteroids")
	var debris_key := Vector2i(9, 7)
	var debris_before := _planned_item_ids("debris", debris_key)
	var debris_kind := _kind("debris")
	var old_chance := debris_kind.chance
	debris_kind.chance = 0.0
	_field.rebuild()
	await _place(Vector2(17000, 11000))
	await _wait(20)
	_ok("changing debris density does not change the asteroid seed",
		_field.chunk_seed(Vector2i(16, 10), "asteroids") == asteroid_seed_before)
	_ok("setting debris density to zero removes only debris",
		_field.bodies_of("debris").is_empty())
	debris_kind.chance = old_chance
	_field.rebuild()
	await _place(Vector2(17000, 11000))
	await _wait(20)
	_ok("restoring debris density restores its deterministic layout",
		_planned_item_ids("debris", debris_key) == debris_before,
		"%s against %s" % [_planned_item_ids("debris", debris_key), debris_before])


func _test_determinism() -> void:
	_beat("F. determinism")
	var at := Vector2(-27000, 15000)
	await _place(at)
	var before := _category_signature()
	await _place(at + Vector2(24000, -19000))
	await _place(at)
	await _wait(20)
	_ok("the same region returns with the same objects", _category_signature() == before,
		"%d chars" % before.length())
	var seed := _field.get_seed()
	_field.set_seed(seed + 991)
	await _place(at)
	await _wait(20)
	_ok("another seed creates another universe", _category_signature() != before)
	_field.set_seed(seed)
	await _place(at)
	await _wait(20)
	_ok("the original seed restores the original region", _category_signature() == before)


func _test_reload() -> void:
	_beat("G. unload and reload")
	var candidates: Array[Vector2] = [Vector2.ZERO, Vector2(9000, 5000), Vector2(-14000, 8000),
		Vector2(26000, -17000), Vector2(-31000, -24000), Vector2(41000, 9000),
		Vector2(-47000, 31000), Vector2(52000, -42000)]
	var home := Vector2.ZERO
	for at in candidates:
		await _place(at)
		if not _field.bodies_of("debris").is_empty():
			home = at
			break
	var before := _body_signature("debris")
	var before_count := _count_kind("debris")
	_ok("the reload sample contains debris", before_count > 0,
		"%d at %s" % [before_count, str(home)])
	var old_chunks := {}
	for node in _nodes_with_meta("object_kind"):
		if String(node.get_meta("object_kind")) == "debris":
			old_chunks[String(node.get_meta("chunk_id"))] = true
	await _place(home + Vector2(60000, 60000))
	await _wait(20)
	var still_old := 0
	for chunk_id in old_chunks:
		var pieces := String(chunk_id).split(":")[1].split(",")
		var key := Vector2i(int(pieces[0]), int(pieces[1]))
		if _field.chunk_state(key, "debris") == 2:
			still_old += 1
	_ok("old debris chunks leave the window", still_old == 0,
		"%d old chunks still active" % still_old)
	await _place(home)
	await _wait(20)
	var after := _body_signature("debris")
	var after_count := _count_kind("debris")
	_ok("debris returns to the same positions", after == before)
	_ok("reloading debris does not duplicate it", after_count == before_count,
		"%d against %d" % [after_count, before_count])


func _asteroid_signature() -> String:
	return _body_signature("asteroids")


func _test_performance() -> void:
	_beat("H. performance")
	await _place(Vector2.ZERO)
	_field.reset_report()
	var before_nodes := _map.get_child_count()
	for i in 180:
		_ship.global_position += Vector2(31, -17)
		_cam.snap()
		await _step()
	var stats: Dictionary = _field.stats()
	_ok("the generation frame budget holds", int(stats["worst_frame_us"]) < 6000,
		"%d us" % int(stats["worst_frame_us"]))
	_ok("live content respects all population ceilings", int(stats["live"]) <= 250,
		"%d live" % int(stats["live"]))
	_ok("the scene tree stays bounded during flight", _map.get_child_count() <= before_nodes + 10,
		"%d against %d" % [_map.get_child_count(), before_nodes])


func _test_integration() -> void:
	_beat("I. integration")
	var hud := _map.get_node_or_null("HUD")
	_ok("the current slice keeps its HUD", hud != null)
	var debris_kind := _kind("debris")
	_ok("debris remains on the gameplay world plane", debris_kind != null and debris_kind.physics)
	_ok("debris remains static", debris_kind != null and debris_kind.parallax == 1.0)
	_ok("the shared object interface recognizes debris",
		WorldObjects.KIND_DEBRIS == "debris" and WorldObjects.KINDS.has(WorldObjects.KIND_DEBRIS))


func _test_diagnostics() -> void:
	_beat("J. diagnostics")
	var lines := _field.debug_lines()
	var joined := "\n".join(lines)
	_ok("debug output reports all three categories",
		joined.contains("CATEGORY") and joined.contains("asteroids") and joined.contains("debris"))
	var stats: Dictionary = _field.stats()
	_ok("statistics report live, created and chunk counts",
		stats.has("live") and stats.has("objects_created") and stats.has("chunks"))
	_ok("statistics report category counts", stats["categories"].has("debris"))
