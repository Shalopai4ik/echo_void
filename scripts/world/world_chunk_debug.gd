extends Node2D
class_name WorldChunkDebug

## The streaming window, drawn over the void: chunk borders, the chunk the ship is
## in, and the numbers behind them.
##
## It reads the field and never writes to it. Every number in the panel comes from
## `EchoWorldField.debug_lines()`, so the overlay cannot agree with a bug: if the
## field says nothing is generating, the panel says so even when the screen looks
## like it is still filling in.
##
## Visibility follows the ship's `show_debug`, which is the F3 that already raises
## the flight panel - one key for "show me everything", and the overlay needs no
## input of its own. It is also gated on `OS.is_debug_build()`, so a release build
## has no chunk borders in it even if a scene forgets to set `show`.
##
## Colours: the gameplay plane is bright and every distant plane is dim, because
## the gameplay plane is the one whose chunks are actually where the ship is. A
## chunk on its way out is red and a chunk still waiting for the build budget is
## amber, which is what makes a hitch look like a backlog instead of a mystery.

const CHUNK := preload("res://scripts/world/world_chunk.gd")

const TEXT_COLOR := Color(0.72, 0.86, 0.98, 0.95)
const GRID_COLOR := Color(0.30, 0.55, 0.75, 0.30)
const REGION_COLOR := Color(0.45, 1.0, 0.75, 0.85)
const ACTIVE_COLOR := Color(0.30, 0.85, 1.0, 0.60)
const DIM_ACTIVE_COLOR := Color(0.35, 0.60, 0.80, 0.20)
const GENERATING_COLOR := Color(1.0, 0.78, 0.25, 0.85)
const UNLOADING_COLOR := Color(1.0, 0.35, 0.30, 0.85)

## Screen pixels the panel is written at, rows per column and the width it gives a
## column. Six rows of two columns is what fits the strip under the ship without
## landing on the flight panel above it or on the game's own telemetry below.
const TEXT_PX := 11
const ROWS_PER_COLUMN := 6
const COLUMN_PX := 230.0

@export var show := false
## Raise and lower with the ship's own debug flag (F3).
@export var follow_ship_debug := true
## Draw the per-plane chunk rectangles, not only the reference world grid.
@export var draw_plane_chunks := true
## How many chunk rectangles may be drawn in one frame. A guard, not a setting:
## the window is bounded anyway, and a frame spent drawing is a frame not spent
## flying.
@export var max_rects := 600

var _field: EchoWorldField
var _ship: Node2D
## The text half of the overlay, drawn in screen space. The borders have to live in
## the world - a chunk is a world rectangle - but the panel must not: text measured
## through the camera transform is at the mercy of the zoom and the window stretch,
## and the one thing a diagnostic panel cannot be is in the wrong place.
## Untyped on purpose: `ChunkPanel` is declared below, and a diagnostic overlay is
## not worth a forward-declaration dance.
var _panel = null


func _ready() -> void:
	# the field's own transform is identity today, but an overlay welded to it is
	# one reparent away from being wrong
	top_level = true
	z_index = 4096
	_field = get_parent() as EchoWorldField
	_panel = ChunkPanel.new()
	_panel.host = self
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	var layer := CanvasLayer.new()
	layer.name = "Text"
	layer.layer = 2
	add_child(layer)
	layer.add_child(_panel)
	visible = false


## The panel is a child of a `CanvasLayer`, so its `_draw` writes in screen pixels
## with no camera transform in the way. It asks the field for its own report: the
## overlay never composes a number the field would disagree with.
class ChunkPanel extends Control:
	var host: WorldChunkDebug

	func _draw() -> void:
		if host == null or not host.visible:
			return
		var lines: Array[String] = host.report()
		var font := ThemeDB.fallback_font
		var step := float(WorldChunkDebug.TEXT_PX) * 1.5
		var rows := WorldChunkDebug.ROWS_PER_COLUMN
		var columns := int(ceil(float(lines.size()) / float(rows)))
		var width := WorldChunkDebug.COLUMN_PX * float(columns)
		var height := step * float(rows)
		var origin := Vector2(maxf((size.x - width) * 0.5, 12.0),
			maxf(size.y - 30.0 - height, 12.0))
		for i in lines.size():
			var column := i / rows
			if column >= columns:
				break
			var at := origin + Vector2(float(column) * WorldChunkDebug.COLUMN_PX,
				float(i % rows) * step)
			draw_string(font, at + Vector2(0.0, float(WorldChunkDebug.TEXT_PX)), lines[i],
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, WorldChunkDebug.TEXT_PX,
				WorldChunkDebug.TEXT_COLOR)


func _process(_delta: float) -> void:
	var wanted := show
	if _ship == null or not is_instance_valid(_ship):
		_ship = get_tree().get_first_node_in_group("ship") as Node2D
	if follow_ship_debug and _ship != null:
		wanted = wanted or bool(_ship.get("show_debug"))
	if not OS.is_debug_build():
		wanted = false
	if visible != wanted:
		visible = wanted
	if _panel != null:
		# the CanvasLayer breaks the parent's visibility chain, so the panel is told
		# separately - and a Control that is merely hidden still holds its last draw
		_panel.visible = wanted
		if wanted:
			_panel.size = get_viewport().get_visible_rect().size
	if visible:
		queue_redraw()
		if _panel != null:
			_panel.queue_redraw()


## The panel's text, straight from the field's own report.
func report() -> Array[String]:
	if _field == null or not is_instance_valid(_field):
		return []
	var at := Vector2.INF
	if _ship != null and is_instance_valid(_ship):
		at = _ship.global_position
	return _field.debug_lines(at)


## World pixels per screen pixel, straight off the camera's world-to-screen
## transform: it already carries the zoom and the window stretch.
func _screen_px() -> float:
	var cam := get_viewport().get_camera_2d()
	if cam == null:
		return 1.0
	var scale: float = cam.get_screen_transform().x.length()
	return 1.0 / scale if scale > 0.0001 else 1.0


## The world rectangle the screen is showing right now.
func _view_rect() -> Rect2:
	var cam := get_viewport().get_camera_2d()
	var size := get_viewport().get_visible_rect().size
	if cam == null:
		return Rect2(Vector2.ZERO, size)
	var to_world := cam.get_screen_transform().affine_inverse()
	var a: Vector2 = to_world * Vector2.ZERO
	var b: Vector2 = to_world * size
	return Rect2(Vector2(minf(a.x, b.x), minf(a.y, b.y)),
		Vector2(absf(b.x - a.x), absf(b.y - a.y)))


func _draw() -> void:
	if _field == null or not is_instance_valid(_field):
		_field = get_parent() as EchoWorldField
		if _field == null:
			return
	var px := _screen_px()
	var rect := _view_rect()
	_draw_grid(rect, px)
	if draw_plane_chunks:
		_draw_chunks(px)
	_draw_region(px)


## The reference grid: one square of `chunk_size` px, with its coordinate written
## in the corner of each cell. Roughly a dozen lines on a 960x540 screen, which is
## enough to read a chunk change without turning the void into graph paper.
func _draw_grid(rect: Rect2, px: float) -> void:
	var size := _field.chunk_size_px()
	if size <= 0.0:
		return
	var font := ThemeDB.fallback_font
	var font_px := maxi(int(round(TEXT_PX * 0.85 * px)), 8)
	var first := Vector2i(int(floor(rect.position.x / size)), int(floor(rect.position.y / size)))
	var last := Vector2i(int(ceil(rect.end.x / size)), int(ceil(rect.end.y / size)))
	for cx in range(first.x, last.x + 1):
		var x := float(cx) * size
		draw_line(Vector2(x, rect.position.y), Vector2(x, rect.end.y), GRID_COLOR, 1.0 * px)
	for cy in range(first.y, last.y + 1):
		var y := float(cy) * size
		draw_line(Vector2(rect.position.x, y), Vector2(rect.end.x, y), GRID_COLOR, 1.0 * px)
	for cy in range(first.y, last.y):
		for cx in range(first.x, last.x):
			var at := Vector2(cx * size + 4.0 * px, cy * size + 12.0 * px)
			draw_string(font, at, "%d,%d" % [cx, cy], HORIZONTAL_ALIGNMENT_LEFT,
				-1.0, font_px, Color(GRID_COLOR, GRID_COLOR.a * 1.6))


## Every loaded chunk, each in its plane's own rectangle. The sizes differ on
## purpose - a sparse population has a bigger chunk - and seeing that is the point
## of drawing them rather than a single grid.
func _draw_chunks(px: float) -> void:
	var gameplay := _field.gameplay_plane()
	var drawn := 0
	for chunk in _field.active_chunk_rects():
		if drawn >= max_rects:
			return
		drawn += 1
		var box: Rect2 = chunk["rect"]
		var state := int(chunk["state"])
		var main := String(chunk["plane"]) == gameplay
		var color := ACTIVE_COLOR
		if state == CHUNK.State.UNLOADING:
			color = UNLOADING_COLOR
		elif state == CHUNK.State.GENERATING:
			color = GENERATING_COLOR
		elif not main:
			color = DIM_ACTIVE_COLOR
		draw_rect(box, color, false, (1.5 if main else 1.0) * px)


## The chunk the ship is in gets its own brighter rectangle: the one border on
## screen that is a fact about the hull rather than about the generator.
func _draw_region(px: float) -> void:
	if _ship == null or not is_instance_valid(_ship):
		return
	var key := _field.ship_chunk(_ship.global_position)
	var box := Rect2(Vector2(key) * _field.chunk_size_px(), Vector2.ONE * _field.chunk_size_px())
	draw_rect(box, Color(REGION_COLOR, 0.05), true)
	draw_rect(box, REGION_COLOR, false, 2.0 * px)
	var font := ThemeDB.fallback_font
	draw_string(font, box.position + Vector2(6.0 * px, -6.0 * px),
		"ship chunk %d,%d" % [key.x, key.y], HORIZONTAL_ALIGNMENT_LEFT, -1.0,
		maxi(int(round(TEXT_PX * px)), 8), REGION_COLOR)