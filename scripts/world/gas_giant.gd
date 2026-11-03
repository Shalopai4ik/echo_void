extends Node2D
class_name GasGiant
## The planet the survey is taking place around, drawn as a shader on a quad.
##
## It is deliberately not a sprite. The disc is several thousand world pixels
## across and only a slice of it is ever on screen; a bitmap that size would be
## the largest asset in the game and would still be resampled down to a curved
## edge. A shader costs the pixels the camera can actually see, so the radius can
## be any number the designer types in, and the bands, the terminator and the
## rings stay smooth at that scale instead of turning into a stretched JPEG.
##
## The planet is placed in the sky rather than in the world. `parallax` is the
## fraction of the ship's motion it shows on screen, the same convention the
## background bands and `EchoWorldField` use, so at 0.05 it hangs where it hangs
## while the belt moves under it. `sky_leash` is how far the centre may be pulled
## from its place, and it is what keeps the thing you are supposed to be afraid of in
## the picture however far the pilot runs.
##
## Not in scope for this stage, and nothing here assumes it: landing, a surface,
## a sphere you can circle, moons, and a gravity well that bends the ship's path.

const SHADER := preload("res://scripts/world/gas_giant.gdshader")

@export_group("Place")
## Radius of the disc in world pixels. At the ship's own scale - a 296 px hull on
## a 1920 px view - 5200 is a body whose edge takes eleven ship lengths to curve
## out of the frame.
@export_range(400.0, 60000.0, 50.0, "suffix:px") var planet_radius: float = 5200.0
## Where the centre sits, in world pixels from the ship at the start - and the one
## number that decides whether the planet is in the picture at all. The visible
## frame is `window / zoom` wide, so with the ship's camera at 0.5 a 798 px window
## sees 1596 world px. Put the centre at a little over the radius and the limb cuts
## across a corner: 5200 px of planet with the centre 5600 px away leaves the ship
## 400 world px clear of the disc and everything past that corner off screen. Put it
## at less than the radius and the camera ends up inside the picture.
@export var sky_anchor: Vector2 = Vector2(3480, -4640)
## Fraction of the ship's motion the planet shows. 0 pins it to the sky, 1 puts it
## at rest in the world - and then it is something you can fly away from.
@export_range(0.0, 1.0, 0.005) var parallax: float = 0.05
## How far the centre may be slid off its place in the sky, in world pixels, in any
## direction. It is what keeps the thing you are supposed to be afraid of in the
## picture however far the pilot runs, and it has to be small: the disc reaches the
## frame while the centre is under about 6190 px away and swallows the view once it
## is closer than the radius, so 5800 +/- 300 is the room there is.
@export_range(0.0, 20000.0, 10.0, "suffix:px") var sky_leash: float = 300.0
## Driven from the current Camera2D when this is empty.
@export var view_source: Node2D

@export_group("Surface")
## Belts across the whole disc, so a frame that only catches a corner of the planet
## still catches two or three of them - which is what makes it read as a gas giant
## rather than as a lamp.
@export_range(2.0, 26.0, 0.5) var band_count: float = 16.0
## How far the belts are dragged off latitude by the flow.
@export_range(0.0, 2.0, 0.01) var turbulence: float = 0.9
@export_range(0.0, 1.0, 0.01) var cloud_amount: float = 0.42
## Cloud and belt drift, in shader time units per second.
@export_range(0.0, 1.0, 0.005) var cloud_speed: float = 0.05
## Direction the star is, in radians, and how much of the disc it reaches.
@export_range(-6.2832, 6.2832, 0.01) var light_angle: float = 2.35
@export_range(0.0, 1.0, 0.01) var limb_darkening: float = 0.6
## Thickness of the lit rim and the halo outside the disc, in disc radii. Kept
## tight: a wide halo around a planet this big fills the frame with fog and the
## limb - the one thing that says "huge" - disappears into it.
@export_range(0.0, 0.3, 0.005) var atmosphere: float = 0.022
@export var night_color: Color = Color(0.004, 0.010, 0.020)
@export var band_dark: Color = Color(0.030, 0.052, 0.082)
@export var band_light: Color = Color(0.115, 0.150, 0.185)
@export var band_warm: Color = Color(0.175, 0.130, 0.085)
@export var haze_color: Color = Color(0.28, 0.50, 0.70)

@export_group("Rings")
@export var show_rings: bool = true
## Both radii in disc radii, so a ring can never be sized inside the planet it
## belongs to. They are also a framing decision: the ship sits `sky_anchor.length()`
## from the centre, so anything past `sky_anchor.length() / planet_radius` would put
## the camera inside the ring band and paint a stripe across the whole sky.
@export_range(1.02, 4.0, 0.01) var ring_inner: float = 1.02
@export_range(1.05, 6.0, 0.01) var ring_outer: float = 1.06
## 1.0 is the ring seen face on, which is what a top-down sky gives you; less
## tilts it into an ellipse.
@export_range(0.08, 1.0, 0.01) var ring_squash: float = 1.0
@export_range(0.0, 1.0, 0.01) var ring_density: float = 0.7
@export var ring_color: Color = Color(0.30, 0.33, 0.38)

@export_group("Report")
@export var print_report_on_ready: bool = false

var _quad: Sprite2D
var _mat: ShaderMaterial
var _time := 0.0
var _pushed := {}
var _view := Vector2.ZERO
var _explicit_view := false


func _ready() -> void:
	_mat = ShaderMaterial.new()
	_mat.shader = SHADER
	_quad = Sprite2D.new()
	_quad.name = "Disc"
	_quad.centered = true
	# one white pixel, stretched: the shader only reads UV, so the texture is a
	# quad and nothing else
	_quad.texture = _white()
	_quad.material = _mat
	add_child(_quad)
	_resize()
	_sync()
	if print_report_on_ready:
		print("GasGiant ", stats())


func _process(delta: float) -> void:
	_time += delta
	_place()
	_sync()


## Where the planet has to be for its screen offset to be `sky_anchor - parallax*view`,
## held to the leash. Working from the view point rather than from a fixed world
## coordinate is what keeps the node's own numbers small after the ship has flown a
## hundred thousand pixels, and it is the same trick the sky bands use.
func _place() -> void:
	var view := _view_point()
	global_position = view + _offset(view)


## The planet's offset from the ship: where it lives in the sky, plus however far
## the ship's running has slid it, with the slide held to the leash.
##
## The leash is on the drift *vector*, not on the distance. Holding the distance
## instead would let the direction swing, and at this scale three degrees is enough
## to carry the limb out of the frame: the ship would fly off in one direction and
## find the planet simply gone.
func _offset(view: Vector2) -> Vector2:
	var drift := -view * parallax
	if sky_leash > 0.0:
		drift = drift.limit_length(sky_leash)
	return sky_anchor + drift


## Drive it from an explicit view point, for a review scene with no camera.
func set_view_center(v: Vector2) -> void:
	_explicit_view = true
	_view = v


func stats() -> Dictionary:
	return {
		"radius": planet_radius, "quad_px": _quad.scale.x,
		"disc_uv": _pushed.get("disc_radius", 0.0),
		"centre": _offset(_view_point()),
		"distance": _offset(_view_point()).length(),
		"position": global_position,
	}


## Is the disc reaching the frame at all, from a given view point. Used by the
## review harness to fail loudly instead of screenshotting an empty sky.
func covers_screen(view: Vector2, screen_half: Vector2) -> bool:
	var c := _offset(view)
	var nearest := Vector2(absf(c.x) - screen_half.x, absf(c.y) - screen_half.y)
	if nearest.x > planet_radius or nearest.y > planet_radius:
		return false
	if nearest.x > 0.0 and nearest.y > 0.0:
		return nearest.length() < planet_radius
	return true


func _view_point() -> Vector2:
	if _explicit_view:
		return _view
	if view_source != null and is_instance_valid(view_source):
		return view_source.global_position
	var vp := get_viewport()
	if vp != null:
		var cam := vp.get_camera_2d()
		if cam != null:
			return cam.global_position
	return global_position


## The quad has to be big enough for the widest thing it draws: the ring system
## when there is one, the halo when there is not.
##
## `Sprite2D.scale` multiplies the texture, and the texture here is one pixel, so
## the scale IS the side of the quad in world pixels and the sprite reaches only
## half of it in each direction. Sizing it as if the scale were the half-side puts
## the disc outside its own picture, and the planet silently stops being drawn.
func _resize() -> void:
	var reach := 1.0 + atmosphere * 5.0
	if show_rings:
		reach = maxf(reach, maxf(ring_outer, ring_outer * ring_squash))
	var side := 2.0 * planet_radius * reach * 1.02
	_quad.scale = Vector2(side, side)


func _sync() -> void:
	_resize()
	var side: float = _quad.scale.x
	var want := {
		"disc_radius": planet_radius / side,
		"light_angle": light_angle,
		"band_count": band_count,
		"turbulence": turbulence,
		"cloud_amount": cloud_amount,
		"cloud_drift": cloud_speed,
		"limb_darkening": limb_darkening,
		"atmosphere": atmosphere,
		"time": _time,
		"show_rings": show_rings,
		"ring_inner": ring_inner,
		"ring_outer": ring_outer,
		"ring_squash": ring_squash,
		"ring_density": ring_density,
		"night_color": night_color,
		"band_dark": band_dark,
		"band_light": band_light,
		"band_warm": band_warm,
		"haze_color": haze_color,
		"ring_color": ring_color,
	}
	for k in want:
		if _pushed.get(k) != want[k]:
			_pushed[k] = want[k]
			_mat.set_shader_parameter(k, want[k])


var _white_tex: Texture2D


func _white() -> Texture2D:
	if _white_tex == null:
		var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		img.set_pixel(0, 0, Color(1, 1, 1, 1))
		_white_tex = ImageTexture.create_from_image(img)
	return _white_tex
