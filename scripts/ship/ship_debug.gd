extends Node2D
class_name ShipDebug

## Sub-stage 1.1 flight diagnostics.
##
## Temporary by design: three arrows out of the hull (nose, current motion, the
## acceleration the engines are actually commanding) and a corner readout of the
## numbers behind them. The point is to make the one rule of this stage visible -
## the nose and the velocity vector are allowed to disagree - so the yellow arrow
## keeps its own direction while the cyan one swings under the rudder.
##
## `top_level` on the node is what makes that readable: the ship yaws, and a debug
## layer welded to the hull would spin its own text upside down every time the
## pilot turns. Everything is drawn in world space, and every size that is meant
## for the eye - text, stroke, arrow head - is a screen measurement converted
## through `Camera2D.get_screen_transform()`, so the panel is the same size on the
## monitor at zoom 0.3 and at 1.3. Guessing it from `Camera2D.zoom` and the
## viewport size is not the same thing: the window is whatever the OS handed out,
## and that is how the panel ended up drawn off the bottom of the frame.
##
## Off unless `show_debug` is set on the ship. The void is the picture.

## World px drawn per px/s of speed. 780 px/s of cruise is a 195 px arrow - about
## two thirds of the hull length, which is what makes "the ship is going somewhere
## the nose is not" readable at a glance.
@export var speed_to_px := 0.25
## Same for the commanded acceleration: 760 px/s^2 of retro burn draws 137 px, a
## hand's width behind the motion arrow it is fighting.
@export var accel_to_px := 0.18
## Length of the plant's push arrow in world px: it is a direction, not a
## magnitude, so it gets its own fixed size rather than a scale.
@export var push_to_px := 150.0
## The nose marker is a fixed length, not a speed - it only says which way the
## ship thinks is forward.
@export var nose_length := 210.0

## The three vectors. Named here because the render test has to find them in the
## captured frame, and a colour that drifted out of this file would silently make
## that check blind.
const NOSE_COLOR := Color(0.35, 0.9, 1.0)
const MOTION_COLOR := Color(1.0, 0.85, 0.25)
const ACCEL_COLOR := Color(1.0, 0.35, 0.8)
const TEXT_COLOR := Color(0.78, 0.88, 0.98, 0.92)
## The net push of the engine plant, drawn as a fourth arrow: where the thrusters
## are forcing the hull, which is the one direction a pilot cannot read off the art.
const PUSH_COLOR := Color(0.55, 1.0, 0.65)

## Size the panel is written at, in screen pixels.
const TEXT_PX := 15
## Rows per column. Sixteen is the most that fits a 448 px window at this size with
## the corner margin kept; the panel has outgrown one column since the assists joined
## it, and a column that runs off the bottom of the screen is a panel with no bottom.
const ROWS_PER_COLUMN := 16
## How far the next column starts, in screen pixels: wider than the longest line at
## TEXT_PX, narrower than half a small window.
const COLUMN_PX := 300
## The action that switches this panel. F3 on the shipping input map; a project
## without the action simply has no key, and the ship's own `show_debug` export still
## opens it. Whichever way it is opened, the panel is not part of the game's HUD -
## it is a tool the developer raises over the flight and lowers again.
const TOGGLE_ACTION := "toggle_debug"

var _ship: ShipController
## Whether the toggle key was down on the previous frame. The panel latches the
## press itself, the same way the ship's stabilization key does, so a held F3 is one
## toggle and a scripted `Input.action_press()` is one too.
var _toggle_was := false
## The endless field, if this scene has one. Read for its chunk report and never
## written to: the flight panel is the instrument, the field is the thing measured.
var _world: Node = null


func _ready() -> void:
	top_level = true
	_ship = get_parent() as ShipController
	_world = get_tree().get_first_node_in_group("world_field")


func _process(_delta: float) -> void:
	if _ship == null:
		return
	# F3. Polled and latched rather than taken from `_unhandled_input`, so a scripted
	# `Input.action_press("toggle_debug")`, a rebinding or a gamepad all arrive the
	# same way - and so the flight model never has to know the panel exists.
	var held := InputMap.has_action(TOGGLE_ACTION) and Input.is_action_pressed(TOGGLE_ACTION)
	if held and not _toggle_was:
		_ship.show_debug = not _ship.show_debug
	_toggle_was = held
	var wanted := _ship.show_debug
	if visible != wanted:
		visible = wanted
	if not wanted:
		return
	global_position = _ship.global_position
	queue_redraw()


func _draw() -> void:
	if _ship == null:
		return
	var font := ThemeDB.fallback_font
	# One screen pixel measured in world pixels. Everything below is authored in
	# screen units - the arrows and the text have to stay the same size on the
	# monitor however far the view is pulled - and the camera's own transform is
	# the only honest source for that: it already carries the zoom and the window
	# stretch, which guessing from `Camera2D.zoom` and the viewport size does not.
	var px := _screen_px()

	# The three vectors, all out of the hull.
	_arrow(Vector2.ZERO, _ship.forward() * nose_length, NOSE_COLOR, "nose", px, font)
	_arrow(Vector2.ZERO, _ship.linear_velocity * speed_to_px, MOTION_COLOR,
		"motion", px, font)
	# The rose arrow is what is bending the path this frame, which since 1.4 is the
	# engines *and* whatever the world is pushing with: an anomaly that drags the hull
	# has to be visible on the same arrow a burn is, or the panel shows a ship being
	# moved by nothing.
	_arrow(Vector2.ZERO, (_ship.commanded_acceleration
		+ _ship.external_acceleration) * accel_to_px, ACCEL_COLOR, "accel", px, font)
	# The direction the plant is actually pushing, drawn from the hull as its own
	# arrow: it is the line the brake nozzles are lit along, and on a ship coasting
	# broadside it is a third direction neither the nose nor the path agrees with.
	if _ship.engines != null:
		var push := _ship.thrust_direction()
		if push.length_squared() > 0.0001:
			_arrow(Vector2.ZERO, push * push_to_px, PUSH_COLOR, "push", px, font)

	_panel(_corner(px), px, font)


## One vector with a head on it, labelled at the tip.
func _arrow(from: Vector2, to: Vector2, color: Color, label: String,
		px: float, font: Font) -> void:
	if to.length_squared() < (4.0 * px) * (4.0 * px):
		return
	var tip := from + to
	var unit := to.normalized()
	# three screen pixels: a thinner line is mostly antialiased edge, which reads
	# as a smudge over the hull and gives the pixel test almost nothing to match.
	var stroke := 3.0 * px
	var head := 14.0 * px
	draw_line(from, tip, color, stroke)
	draw_polyline(PackedVector2Array([
		tip - unit * head + unit.orthogonal() * head * 0.5,
		tip,
		tip - unit * head - unit.orthogonal() * head * 0.5,
	]), color, stroke)
	draw_string(font, tip + Vector2(8.0, -8.0) * px, label, HORIZONTAL_ALIGNMENT_LEFT,
		-1.0, _font_px(px), color)


## The numeric block, parked at the top-left of what the camera can actually see,
## so it stays put while the hull flies around inside the frame.
##
## Since 1.3 the panel is longer than any one column can hold on a small window: the
## flight block, the plant block and the three assist blocks together are twenty-eight
## rows, and a window 448 px tall shows sixteen. So it walks into columns of
## `ROWS_PER_COLUMN` rows, each offset by a width that is measured in screen pixels
## because the text is. The row order inside the first two columns is unchanged - a
## test reads `readout()[7]` for the yaw, and reordering it to look tidier would be a
## lie about what the panel showed.
func _panel(at: Vector2, px: float, font: Font) -> void:
	var size := _font_px(px)
	var step := TEXT_PX * 1.5 * px
	var rows := readout()
	var column := 0
	while column * ROWS_PER_COLUMN < rows.size():
		var first := column * ROWS_PER_COLUMN
		var last := mini(rows.size(), first + ROWS_PER_COLUMN)
		var x := at.x + column * COLUMN_PX * px
		var y := at.y
		for i in range(first, last):
			draw_string(font, Vector2(x, y), rows[i], HORIZONTAL_ALIGNMENT_LEFT,
				-1.0, size, TEXT_COLOR)
			y += step
		column += 1


## The panel's text, built here rather than inline so the numbers can be read by
## a headless run that has no renderer to draw them into.
func readout() -> Array[String]:
	if _ship == null:
		return []
	var v := _ship.linear_velocity
	var a := _ship.commanded_acceleration
	# Typed on purpose. A plain literal here is an untyped `Array`, and `untyped + typed`
	# stays untyped - which then fails at draw time with "can't assign Array to
	# Array[String]" the moment a block is appended to it. The panel drew fine for two
	# sub-stages before that became an error, because nothing was appended to a literal.
	var flight: Array[String] = [
		"mode      %s" % _ship.mode_name(),
		"speed     %s px/s" % _num(_ship.speed()),
		"velocity  %s, %s" % [_num(v.x), _num(v.y)],
		"along     %s px/s" % _num(_ship.forward_speed()),
		"across    %s px/s" % _num(_ship.drift_speed()),
		"nose      %s deg" % _num(rad_to_deg(_ship.rotation)),
		"accel     %s px/s^2 (%s, %s)" % [_num(a.length()), _num(a.x), _num(a.y)],
		"yaw       %s rad/s" % _num(_ship.angular_velocity, 2),
		"position  %s, %s" % [_num(_ship.global_position.x),
		_num(_ship.global_position.y)],
		"hands     %s   (main|retro|slide|turn)" % _ship.owners(),
	]
	var lines: Array[String] = []
	lines.append_array(flight)
	lines.append_array(_engine_lines())
	lines.append_array(_assist_lines())
	lines.append_array(_world_lines())
	lines.append_array(_chunk_lines())
	lines.append_array(_audio_lines())
	lines.append_array(_perf_lines())
	return lines


## The 1.4 block: what the hull says it is doing, whether anyone is allowed to fly it,
## what it last hit and what the world is pushing it with. Every line is read from the
## ship's own state layer, the contact report and the external set - none of it is
## recomputed here, which is the difference between a panel that helps find a conflict
## and a panel that quietly agrees with whatever it wants.
func _world_lines() -> Array[String]:
	var out: Array[String] = []
	if _ship == null or _ship.ship_state == null:
		return out
	var state := _ship.ship_state
	out.append("  state     %s" % state.name_of())
	out.append("  active    %s" % state.flags_text())
	out.append("  control   %s" % ("ENABLED" if _ship.movement_enabled else "DISABLED"))
	var external := _ship.external_acceleration
	out.append("  external  %s px/s^2 (%s, %s)  x%d" % [
		_num(external.length()), _num(external.x), _num(external.y),
		_ship.external_influence_count()])
	var hit := _ship.last_collision()
	if hit.is_empty():
		out.append("  last hit  none")
	else:
		out.append("  last hit  %s  %.0f px/s  %s" % [
			hit.category, hit.closing_speed,
			WorldObjects.summarize(hit.description)])
		out.append("  hit point %s, %s (%.2f s ago, est)" % [
			_num((hit.contact_point as Vector2).x),
			_num((hit.contact_point as Vector2).y), hit.age])
	return out


## The four lines of the streaming report that belong on a flight panel. The full
## chunk picture is the overlay's job (`ChunkDebug`); a pilot deciding whether to
## boost only needs to know that the space ahead is built and how much of it there
## is. `debug_lines()` is the field's own report, so the panel cannot print a
## number the field would disagree with.
func _chunk_lines() -> Array[String]:
	var out: Array[String] = []
	if _world == null or not is_instance_valid(_world):
		_world = get_tree().get_first_node_in_group("world_field")
	if _world == null or not _world.has_method("debug_lines"):
		return out
	var at: Vector2 = _ship.global_position if _ship != null else Vector2.INF
	for line in _world.debug_lines(at):
		if line.begins_with("CHUNK") or line.begins_with("ACTIVE") \
				or line.begins_with("OBJECTS") or line.begins_with("OPS"):
			out.append("  " + line.strip_edges().replace("  ", " "))
	return out


## The engine plant's own block. Read from the plant rather than recomputed here,
## so the panel and the jets can never disagree about what is burning.
func _engine_lines() -> Array[String]:
	var out: Array[String] = []
	if _ship == null or _ship.engines == null:
		return out
	for line in _ship.engines.report():
		out.append("  " + line)
	return out


## The three assists, each in its own voice. Every line is the system's own report,
## not a number recomputed here: the panel is the instrument for finding a conflict
## between the systems, and an instrument that averages two answers is useless for
## that. Order is stabilization, emergency brake, boost - the order the resolver
## consults them in.
func _assist_lines() -> Array[String]:
	var out: Array[String] = []
	if _ship == null:
		return out
	if _ship.stabilization != null:
		for line in _ship.stabilization.report():
			out.append("  " + line)
	if _ship.emergency_brake != null:
		for line in _ship.emergency_brake.report():
			out.append("  " + line)
	if _ship.boost != null:
		for line in _ship.boost.report():
			out.append("  " + line)
	return out


## The mixer's own account of itself, read from the `Audio` child rather than
## recomputed here: the point of the panel is to show what the game is actually
## doing, and a level the audio component did not smooth is a level it is not
## playing. The child is found by name and asked through `report()`, so a hull
## without an audio component simply has no audio lines.
func _audio_lines() -> Array[String]:
	var out: Array[String] = []
	if _ship == null:
		return out
	var audio := _ship.get_node_or_null("Audio")
	if audio != null and audio.has_method("report"):
		for line in audio.report():
			out.append("  " + String(line))
	return out


## The cost of the frame, for a stage whose whole job is to make sure the ship's
## systems do not quietly grow: how many frames a second the renderer managed, what
## the physics step cost, and how many nodes are alive on the hull and in the world.
## Read-only, and the only line in the panel that would notice a leak.
func _perf_lines() -> Array[String]:
	var out: Array[String] = []
	if _ship == null:
		return out
	var fps := Engine.get_frames_per_second()
	# Process time, not 1/fps: a headless run has no frame budget worth dividing into,
	# and even in a real window the CPU cost is the number a developer acts on.
	var frame_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var physics_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	out.append("  perf      %d fps  proc %.1f phys %.1f ms" % [
		fps, frame_ms, physics_ms])
	out.append("  nodes     %d hull  %d world" % [
		_ship.get_child_count(), int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))])
	return out


## A number for the panel with the negative zero folded away. `%.0f` prints -0.4
## as "-0", and a readout whose every other line is a sign is the one place a
## pilot is meant to trust - a bare "-0" reads as the axis being backwards.
func _num(value: float, digits: int = 0) -> String:
	var spec := "%%.%df" % digits
	var text := spec % value
	if text.begins_with("-") and float(text) == 0.0:
		return text.substr(1)
	return text


## World pixels per screen pixel, straight off the camera's world-to-screen
## transform. Falls back to 1.0 with no camera, which is the old unzoomed canvas.
func _screen_px() -> float:
	var cam := get_viewport().get_camera_2d()
	if cam == null:
		return 1.0
	var scale: float = cam.get_screen_transform().x.length()
	if scale <= 0.0001:
		return 1.0
	return 1.0 / scale


## The first line of the panel, a hand's width in from the top-left corner of the
## screen - which is a screen-space idea, so it is mapped back through the same
## transform rather than derived from the viewport's nominal size.
func _corner(px: float) -> Vector2:
	var cam := get_viewport().get_camera_2d()
	if cam == null:
		return Vector2(16.0, 20.0)
	var top_left: Vector2 = cam.get_screen_transform().affine_inverse() \
		* Vector2(16.0, 20.0)
	return top_left + Vector2(0.0, TEXT_PX * px)


func _font_px(px: float) -> int:
	return maxi(int(round(TEXT_PX * px)), 8)
