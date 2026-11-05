extends SceneTree

## The cut cruiser: the hull the player flies, and the exhaust that hangs off it.
## Run: godot --headless --path . --script tests/cruiser_test.gd
##
## Two claims, and both are about agreement rather than looks:
##
## - **The scene agrees with the art.** The hull is drawn 1:1, every collision vertex
##   stays inside the silhouette's envelope, and every nozzle sits on the hull instead
##   of floating in empty sky. A redrawn hull that skipped any of those would look fine
##   in a screenshot and be wrong in the hand.
## - **The exhaust is an animation, not a sliding sprite.** Four distinct frames cycle
##   while the nozzle burns, a cold nozzle does not advance, and the pivot of every
##   layer stays on the nozzle so a long flame cannot walk off the bell.

const MAP := "res://scenes/test/TestControlMap.tscn"
const HULL_SIZE := Vector2(284, 97)
const HALF_HEIGHT := 48.0        # +-47 in the art, rounded out
const NOSE_X := 141.0

var _ship: ShipController
var _fx: EngineVisuals
var _sprite: Sprite2D
var _checks := 0
var _failed := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed: PackedScene = load(MAP)
	if packed == null:
		print("RESULT: FAILED  could not load ", MAP)
		quit(2)
		return
	var scene: Node = packed.instantiate()
	root.add_child(scene)
	_ship = scene.get_node("Ship") as ShipController
	_fx = _ship.get_node("EngineFx") as EngineVisuals
	_sprite = _ship.get_node("Visuals/Sprite2D") as Sprite2D
	await process_frame
	await physics_frame

	_test_the_cut()
	_test_the_body()
	_test_the_nozzles()
	await _test_the_exhaust()
	_finish()


func _test_the_cut() -> void:
	var tex: Texture2D = _sprite.texture
	_ok("the player flies the cut cruiser", tex != null and tex.get_size() == HULL_SIZE
		and _sprite.scale.is_equal_approx(Vector2.ONE),
		"%s at scale %s" % [str(tex.get_size() if tex != null else Vector2.ZERO),
			str(_sprite.scale)])
	if tex == null:
		return
	var img: Image = tex.get_image()
	var tail := _span(img, 1)
	# the very tip is a handful of half-transparent pixels, so the nose column is found
	# rather than assumed: the cut is tight, but "tight" runs on alpha > 8/255
	var tip := img.get_width() - 1
	while tip > 0 and _span(img, tip).x < 0:
		tip -= 1
	var nose := _span(img, tip)
	_ok("the nose is on +X: the silhouette tapers to the right",
		tip >= img.get_width() - 3
		and nose.y - nose.x + 1 < (tail.y - tail.x + 1) / 2,
		"tip at %d, %d rows against %d at the tail" % [tip, nose.y - nose.x + 1,
			tail.y - tail.x + 1])
	_ok("the cut is tight: one pixel of pad, nothing else",
		_span(img, 0) == Vector2i(-1, -1)
		and _span(img, img.get_width() - 1) == Vector2i(-1, -1),
		"edge columns empty")
	# the sheet's own flame was cut off at the bell: the tail column is the bell's metal,
	# not a wash of transparent blue
	var painted := 0
	for y in img.get_height():
		if img.get_pixel(1, y).a > 0.9:
			painted += 1
	_ok("the tail column is hull, not leftover exhaust", painted > 20, "%d solid rows" % painted)


func _test_the_body() -> void:
	var shapes := 0
	var widest := 0.0
	var longest := 0.0
	var convex := 0
	for node in _ship.get_children():
		if not node is CollisionPolygon2D:
			continue
		shapes += 1
		var poly: PackedVector2Array = node.polygon
		if _is_convex(poly):
			convex += 1
		for p in poly:
			widest = maxf(widest, absf(p.y))
			longest = maxf(longest, absf(p.x))
	_ok("the hull is a body of slabs", shapes >= 8, "%d slabs" % shapes)
	_ok("every slab is convex, as CollisionPolygon2D requires", convex == shapes,
		"%d of %d convex" % [convex, shapes])
	_ok("the slabs stay inside the art", widest <= HALF_HEIGHT and longest <= NOSE_X + 1.0,
		"widest %.1f, nose %.1f" % [widest, longest])
	_ok("the slabs reach the art, not just sit inside it",
		widest > HALF_HEIGHT - 6.0 and longest > NOSE_X - 4.0,
		"widest %.1f, nose %.1f" % [widest, longest])


func _test_the_nozzles() -> void:
	var img: Image = _sprite.texture.get_image()
	var off_hull := 0
	var anchors := _fx.anchors()
	for anchor in anchors:
		var reach := _half_height(img, anchor.position.x)
		if absf(anchor.position.y) > reach + 6.0:
			off_hull += 1
	_ok("every nozzle sits on the hull it burns from", off_hull == 0,
		"%d of %d off the silhouette" % [off_hull, anchors.size()])
	var main_anchor: EngineNozzle = _fx.anchors("main")[0]
	var jet: EngineJet = _fx.jet_of(main_anchor)
	_ok("the main flame leaves along the tail axis",
		jet != null and is_zero_approx(jet.rotation) and main_anchor.position.x < -130.0,
		"anchor %s, jet rotation %.3f" % [str(main_anchor.position),
			jet.rotation if jet != null else 99.0])
	if jet == null:
		return
	var plume: Sprite2D = jet.get_node("Plume") as Sprite2D
	var frame_size: Vector2 = EngineJet.FRAMES[0].get_size()
	_ok("the plume is pivoted on its nozzle, not on its middle", plume.centered == false
		and plume.offset.is_equal_approx(Vector2(-frame_size.x, -frame_size.y / 2.0)),
		"offset %s" % str(plume.offset))


func _test_the_exhaust() -> void:
	var frames: Array = EngineJet.FRAMES
	_ok("the exhaust is a cycle of four frames", frames.size() == 4, "%d frames" % frames.size())
	var size: Vector2 = frames[0].get_size()
	var same := 0
	for i in frames.size():
		if frames[i].get_size() == size:
			same += 1
	_ok("the frames share one canvas, so the pivot holds", same == frames.size(),
		"%d of %d at %s" % [same, frames.size(), str(size)])
	var distinct := 0
	for i in frames.size():
		for j in range(i + 1, frames.size()):
			if frames[i].get_image().get_data() != frames[j].get_image().get_data():
				distinct += 1
	_ok("the frames are different pictures, not one frame repeated", distinct == 6,
		"%d distinct pairs of 6" % distinct)
	# The taper is the picture, not padding: if a trail is wider than its canvas,
	# the cut turns the pointed tail into a flat wall at the left edge.
	var clipped := 0
	for frame in frames:
		var img: Image = frame.get_image()
		for y in img.get_height():
			if img.get_pixel(0, y).a > 0.08:
				clipped += 1
				break
	_ok("the flame tapers to nothing instead of hitting a crop edge", clipped == 0,
		"%d of %d frames painted at x=0" % [clipped, frames.size()])

	var jet: EngineJet = _fx.jet_of(_fx.anchors("main")[0])
	var plume: Sprite2D = jet.get_node("Plume") as Sprite2D
	Input.action_press("thrust_forward")
	for i in 150:
		await process_frame
	_ok("the nozzle is burning", jet.visible, "visible=%s" % jet.visible)
	var seen := {}
	for i in 150:
		await process_frame
		seen[plume.texture.resource_path] = true
	_ok("a burning nozzle flickers through its frames", seen.size() >= 2,
		"%d frames seen" % seen.size())

	# and it stops: a dark jet must not animate, or a stopped engine would still be
	# advertising motion through a flame that keeps changing
	Input.action_release("thrust_forward")
	for i in 400:
		await process_frame
		if not jet.visible:
			break
	_ok("the nozzle goes dark when the plant is cold", not jet.visible,
		"visible=%s" % jet.visible)
	var frozen := plume.texture.resource_path
	for i in 60:
		await process_frame
	_ok("a dark nozzle holds its frame", plume.texture.resource_path == frozen,
		"%s then %s" % [frozen, plume.texture.resource_path])


# ------------------------------------------------------------------ plumbing --

## First and last painted row of one texture column; (-1,-1) when it is empty.
func _span(img: Image, x: int) -> Vector2i:
	var lo := -1
	var hi := -1
	for y in img.get_height():
		if img.get_pixel(x, y).a > 0.08:
			if lo < 0:
				lo = y
			hi = y
	return Vector2i(-1, -1) if lo < 0 else Vector2i(lo, hi)


## How far the silhouette reaches from the axis at hull-local x, in hull-local px.
## Sampled over a few columns because a nozzle sits on an edge, not on a centre line.
func _half_height(img: Image, x_local: float) -> float:
	var cx := (img.get_width() - 1) / 2.0
	var cy := (img.get_height() - 1) / 2.0
	var reach := 0.0
	for dx in range(-3, 4):
		var x := int(round(x_local + cx + dx))
		if x < 0 or x >= img.get_width():
			continue
		var span := _span(img, x)
		if span.x < 0:
			continue
		reach = maxf(reach, maxf(absf(span.x - cy), absf(span.y - cy)))
	return reach


## CollisionPolygon2D only accepts convex rings, and Godot's triangulator fails on a
## degenerate one - so this is checked from the outside rather than trusted.
func _is_convex(poly: PackedVector2Array) -> bool:
	if poly.size() < 3:
		return false
	var sign_seen := 0
	for i in poly.size():
		var a := poly[i]
		var b := poly[(i + 1) % poly.size()]
		var c := poly[(i + 2) % poly.size()]
		var cross := (b - a).cross(c - b)
		if is_zero_approx(cross):
			continue
		var s := 1 if cross > 0.0 else -1
		if sign_seen == 0:
			sign_seen = s
		elif s != sign_seen:
			return false
	return sign_seen != 0


func _ok(name: String, condition: bool, detail := "") -> void:
	_checks += 1
	print(("PASS  " if condition else "FAIL  ") + name + "   " + detail)
	if not condition:
		_failed += 1


func _finish() -> void:
	print("RESULT: ", "FAILED %d of %d" % [_failed, _checks] if _failed > 0 else "ALL PASS")
	quit(1 if _failed else 0)