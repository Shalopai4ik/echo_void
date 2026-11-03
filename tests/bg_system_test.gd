extends SceneTree

## Automated checks for the infinite background system.
## Run:  godot --headless --path . --script tests/bg_system_test.gd

const VIEW := Rect2(Vector2.ZERO, Vector2(960, 540))
const LAYER_SCRIPT := preload("res://scripts/space_background/space_layer.gd")
const HASH := preload("res://scripts/space_background/space_hash.gd")

var _failed := 0
var _tex_a: Texture2D
var _tex_b: Texture2D


func _initialize() -> void:
	call_deferred("_run")


func _check(name: String, ok: bool, detail := "") -> void:
	print(("PASS  " if ok else "FAIL  ") + name + "   " + detail)
	if not ok:
		_failed += 1


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _run() -> void:
	_tex_a = load("res://assets/space_bg/sprites/asteroid_003.png")
	_tex_b = load("res://assets/space_bg/sprites/asteroid_011.png")
	if _tex_a == null or _tex_b == null:
		print("FAIL  assets missing - run the editor import first")
		quit(1)
		return

	await _test_scene()
	await _test_continuity()
	await _test_no_canvas_cut()
	await _test_determinism()
	await _test_frame_rate_independence()
	await _test_bounded_coordinates()
	await _test_recycling()
	await _test_coverage()
	await _test_hash()

	print("RESULT: ", "FAILED (%d)" % _failed if _failed > 0 else "ALL PASS")
	quit(1 if _failed > 0 else 0)


func _mk_layer(tex_list: Array, cfg: Dictionary) -> EchoSpaceLayer:
	var l: EchoSpaceLayer = LAYER_SCRIPT.new()
	root.add_child(l)
	cfg["textures"] = tex_list
	l.setup(cfg)
	return l


func _test_scene() -> void:
	var bg: EchoSpaceBackground = load("res://scenes/InfiniteSpaceBackground.tscn").instantiate()
	root.add_child(bg)
	await _frames(3)
	var st: Dictionary = bg.stats()
	_check("scene builds bands", st.bands >= 6, "bands=%d" % st.bands)
	_check("assets auto-mapped", st.nodes > 0, str(st))
	_check("has real nodes", st.nodes >= 12, "nodes=%d" % st.nodes)

	# fly a long way out and check nothing is empty
	bg.set_view_center(Vector2(180000, -96000))
	await _frames(4)
	var far: Dictionary = bg.stats()
	_check("generates far from origin", far.nodes > 0 and far.chunks > 0, str(far))
	_check("node count stays bounded", far.nodes <= 260, "nodes=%d" % far.nodes)

	# changing the seed must change the world
	var sig_before := _all_signatures(bg)
	bg.set_seed(424242)
	await _frames(4)
	var sig_after := _all_signatures(bg)
	_check("seed changes the world", sig_before != sig_after,
		   "len %d vs %d" % [sig_before.length(), sig_after.length()])
	bg.set_seed(20261029)
	await _frames(4)
	_check("seed restores the world", _all_signatures(bg) == sig_before)

	# extension point
	var before: int = bg.stats().nodes
	bg.register_kind("near", [_tex_a])
	await _frames(4)
	_check("register_kind accepted", bg.stats().nodes > 0 and before >= 0, "ok")
	bg.queue_free()
	await _frames(2)


func _all_signatures(bg: EchoSpaceBackground) -> String:
	var out := ""
	for child in bg.get_children():
		var l := child as EchoSpaceLayer
		if l != null and l.visible and not l.textures.is_empty():
			out += l.name + "=" + l.signature() + "\n"
	return out


func _test_determinism() -> void:
	var cfg := {
		"scroll_factor": 0.4, "cell_size": Vector2(320, 320), "density": 0.6,
		"max_per_cell": 2, "jitter": 0.9, "size_range": Vector2(0.5, 1.2),
		"rotation_range": Vector2(0, TAU), "alpha_range": Vector2(0.5, 1.0),
		"spin_range": Vector2(-0.05, 0.05), "salt": 5, "seed": 777,
		"margin": Vector2(400, 400), "max_nodes": 200,
	}
	var a := _mk_layer([_tex_a, _tex_b], cfg.duplicate(true))
	var b := _mk_layer([_tex_a, _tex_b], cfg.duplicate(true))
	# approach the same view point from opposite directions
	a.advance(Vector2(90000, -40000), VIEW, 0.016)
	b.advance(Vector2(-70000, 55000), VIEW, 0.016)
	b.advance(Vector2(90000, -40000), VIEW, 0.016)
	_check("same seed + same view = same content", a.signature() == b.signature(),
		   "%d cells" % a.cell_count())
	b.set_seed(778)
	b.advance(Vector2(90000, -40000), VIEW, 0.016)
	_check("different seed = different content", a.signature() != b.signature())
	a.queue_free()
	b.queue_free()
	await _frames(1)


func _test_frame_rate_independence() -> void:
	var cfg := {
		"scroll_factor": 0.5, "cell_size": Vector2(300, 300), "density": 0.55,
		"max_per_cell": 2, "jitter": 1.0, "size_range": Vector2(0.6, 1.3),
		"rotation_range": Vector2(0, TAU), "alpha_range": Vector2(0.4, 1.0),
		"spin_range": Vector2(-0.1, 0.1), "drift_amp": 12.0, "patch_block": 5,
		"salt": 9, "seed": 1234, "margin": Vector2(400, 400), "max_nodes": 200,
	}
	var slow := _mk_layer([_tex_a, _tex_b], cfg.duplicate(true))
	var fast := _mk_layer([_tex_a, _tex_b], cfg.duplicate(true))
	# walk the same path with a coarse and a fine step; the last sample of both
	# loops is the identical view point
	var slow_pts: Array[Vector2] = []
	for i in range(0, 2501, 100):
		slow_pts.append(Vector2(i, i * 0.4))
	var fast_pts: Array[Vector2] = []
	for i in range(0, 2501, 1):
		fast_pts.append(Vector2(i, i * 0.4))
	for pt in slow_pts:
		slow.advance(pt * 100.0, VIEW, 0.1)
	for pt in fast_pts:
		fast.advance(pt * 100.0, VIEW, 0.01)
	_check("10 fps and 240 fps agree", slow.signature() == fast.signature(),
		   "slow cells=%d fast cells=%d" % [slow.cell_count(), fast.cell_count()])
	slow.queue_free()
	fast.queue_free()
	await _frames(1)


func _test_bounded_coordinates() -> void:
	var l := _mk_layer([_tex_a, _tex_b], {
		"scroll_factor": 1.0, "cell_size": Vector2(400, 400), "density": 0.8,
		"jitter": 1.0, "salt": 3, "seed": 55, "margin": Vector2(400, 400),
		"max_nodes": 200,
	})
	for i in 40:
		l.advance(Vector2(i, -i * 0.7) * 250000.0, VIEW, 0.016)
	var worst := 0.0
	for chunk in l.get_children():
		worst = maxf(worst, chunk.position.length())
	_check("node coordinates stay small", worst < 4000.0, "max |pos| = %.0f" % worst)
	l.queue_free()
	await _frames(1)


func _test_recycling() -> void:
	var l := _mk_layer([_tex_a, _tex_b], {
		"scroll_factor": 1.0, "cell_size": Vector2(320, 320), "density": 0.7,
		"jitter": 1.0, "spin_range": Vector2(-0.05, 0.05), "twinkle": 0.3,
		"salt": 7, "seed": 99, "margin": Vector2(320, 320), "max_nodes": 200,
	})
	l.advance(Vector2.ZERO, VIEW, 0.016)
	var home := l.signature()
	# a long loop that ends exactly where it started
	for i in range(1, 601):
		l.advance(Vector2(i * 900.0, sin(i * 0.01) * 4000.0), VIEW, 0.016)
	for i in range(600, 0, -1):
		l.advance(Vector2(i * 900.0, sin(i * 0.01) * 4000.0), VIEW, 0.016)
	l.advance(Vector2.ZERO, VIEW, 0.016)
	var total_children := l.get_child_count()
	_check("nodes are recycled, not leaked", total_children <= 40,
		   "chunk nodes=%d live=%d" % [total_children, l.live_nodes()])
	_check("content returns after a round trip", l.signature() == home,
		   "cells=%d" % l.cell_count())
	l.queue_free()
	await _frames(1)


func _test_coverage() -> void:
	var tile: Texture2D = load("res://assets/space_bg/base_tile.png")
	var l := _mk_layer([tile], {
		"tiled": true, "scroll_factor": 0.05, "salt": 1, "seed": 7,
		"max_nodes": 64, "margin": Vector2(0, 0),
	})
	var worst := 1.0
	var worst_at := Vector2.ZERO
	for t in 14:
		var p := Vector2(t * 7919.0, t * -104729.0)
		l.advance(p, VIEW, 0.016)
		var rects: Array[Rect2] = []
		for chunk in l.get_children():
			rects.append(Rect2(chunk.position, Vector2(tile.get_size())))
		var hit := 0
		var total := 0
		for y in range(0, int(VIEW.size.y), 16):
			for x in range(0, int(VIEW.size.x), 16):
				total += 1
				for r in rects:
					if r.has_point(Vector2(x, y)):
						hit += 1
						break
		var cov := float(hit) / float(total)
		if cov < worst:
			worst = cov
			worst_at = p
	_check("tiled base always covers the screen", worst >= 0.999,
		   "worst coverage = %.4f at %s" % [worst, worst_at])
	l.queue_free()
	await _frames(1)


func _test_continuity() -> void:
	var cfg := {
		"scroll_factor": 1.0, "cell_size": Vector2(300, 300), "density": 0.8,
		"max_per_cell": 2, "jitter": 1.0, "size_range": Vector2(0.6, 1.2),
		"rotation_range": Vector2(0, TAU), "alpha_range": Vector2(0.5, 1.0),
		"salt": 41, "seed": 8181, "margin": Vector2(300, 300), "max_nodes": 300,
	}
	var l := _mk_layer([_tex_a, _tex_b], cfg.duplicate(true))
	l.advance(Vector2(40000, 20000), VIEW, 0.016)
	var before := _cell_map(l)
	# one pixel of travel must not re-roll anything that is still on screen
	l.advance(Vector2(40001, 20000), VIEW, 0.016)
	var after := _cell_map(l)
	var rerolled := 0
	for k in before:
		if after.has(k) and before[k] != after[k]:
			rerolled += 1
	_check("smooth travel does not re-roll content", rerolled == 0,
		   "%d cells changed, %d kept" % [rerolled, after.size()])

	# nothing may be born inside the camera rect: new cells belong to the ring
	var spawned_inside := 0
	for k in after:
		if not before.has(k):
			var r := Rect2(Vector2(k) * Vector2(300, 300) - Vector2(40001, 20000),
						   Vector2(300, 300))
			if r.intersection(VIEW).get_area() > 0.0:
				spawned_inside += 1
	_check("new cells appear off screen", spawned_inside == 0, "%d in view" % spawned_inside)

	# a teleport must land on exactly the world a ship flying there would see
	var dest := Vector2(900000, -300000)
	l.advance(dest, VIEW, 0.016)
	var fresh := _mk_layer([_tex_a, _tex_b], cfg.duplicate(true))
	fresh.advance(dest, VIEW, 0.016)
	_check("teleport matches a continuous flight", l.signature() == fresh.signature(),
		   "cells=%d vs %d" % [l.cell_count(), fresh.cell_count()])
	l.queue_free()
	await _frames(1)


func _cell_map(l: EchoSpaceLayer) -> Dictionary:
	var out := {}
	for child in l.get_children():
		out[child.get_meta("cell")] = _sprite_map(child)
	return out


func _sprite_map(chunk: Node2D) -> String:
	var parts: Array[String] = []
	for sp in chunk.get_children():
		var sprite := sp as Sprite2D
		if sprite == null:
			continue
		parts.append("%s@%.1f,%.1f" % [sprite.texture.resource_path.get_file(),
									  sprite.position.x, sprite.position.y])
	parts.sort()
	return "|".join(parts)


func _test_no_canvas_cut() -> void:
	var bg: EchoSpaceBackground = load("res://scenes/InfiniteSpaceBackground.tscn").instantiate()
	root.add_child(bg)
	await _frames(3)
	var offenders: Array[String] = []
	for child in bg.get_children():
		var l := child as EchoSpaceLayer
		if l == null or l.tiled:
			continue
		for tex in l.textures:
			if bg._touches_border(tex):
				offenders.append("%s/%s" % [l.name, tex.resource_path.get_file()])
	_check("no scattered sprite is cut by its crop edge", offenders.is_empty(),
		   ", ".join(offenders))

	# the game ships without rocks in the sky
	var visible_bands: Array[String] = []
	for child in bg.get_children():
		var l := child as EchoSpaceLayer
		if l != null and l.visible and l.name in ["MidgroundLayer", "NearObjectsLayer", "AnomalyLayer"]:
			visible_bands.append(l.name)
	_check("asteroid bands off by default", visible_bands.is_empty(), str(visible_bands))
	bg.queue_free()
	await _frames(2)


func _test_hash() -> void:
	var sum := 0.0
	var buckets := [0, 0, 0, 0]
	var prev := -1.0
	var repeats := 0
	for y in 100:
		for x in 100:
			var v := HASH.hashf(x, y, 3, 20261029)
			sum += v
			buckets[int(mini(v * 4.0, 3.99))] += 1
			if absf(v - prev) < 0.0005:
				repeats += 1
			prev = v
	var mean := sum / 10000.0
	_check("hash mean near 0.5", absf(mean - 0.5) < 0.03, "mean=%.4f" % mean)
	_check("hash buckets balanced", buckets.min() > 1900 and buckets.max() < 3100, str(buckets))
	_check("hash is stable", is_equal_approx(HASH.hashf(12, -34, 5, 9), HASH.hashf(12, -34, 5, 9)))
	_check("neighbouring cells differ", repeats < 30, "near-duplicates=%d" % repeats)
