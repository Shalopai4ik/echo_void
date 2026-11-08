extends CanvasLayer
class_name ScreenFx

## The glass between the pilot and the void: a vignette that tightens as the
## creature's attention grows, radio interference when something interferes,
## a red edge while the brood is out, and a camera shake. One full-screen
## shader, three numbers - kept cheap and kept subtle on purpose.

const GROUP := "screen_fx"

const SHADER_CODE := """
shader_type canvas_item;
uniform float tension : hint_range(0.0, 1.0) = 0.0;
uniform float glitch : hint_range(0.0, 1.0) = 0.0;
uniform float danger : hint_range(0.0, 1.0) = 0.0;
uniform float t = 0.0;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

void fragment() {
	vec2 uv = UV;
	vec2 c = uv - 0.5;
	float r = length(c * vec2(1.6, 1.0));
	float vig = smoothstep(0.55 - tension * 0.18, 1.05, r) * (0.35 + tension * 0.45);
	float n = hash(floor(uv * vec2(480.0, 270.0)) + floor(t * 30.0));
	float band = step(0.985 - glitch * 0.08, hash(vec2(floor(uv.y * 90.0), floor(t * 14.0))));
	float grain = (n - 0.5) * (0.04 + glitch * 0.35);
	vec3 col = vec3(0.0);
	float a = vig;
	col += vec3(grain + band * glitch * 0.35);
	a = max(a, abs(grain) * 1.4 + band * glitch * 0.45);
	vec3 red = vec3(0.55, 0.02, 0.02);
	float edge = smoothstep(0.6, 1.1, r) * danger * (0.55 + 0.45 * sin(t * 4.0));
	col = mix(col, red, clamp(edge * 1.6, 0.0, 1.0));
	a = max(a, edge * 0.6);
	COLOR = vec4(col, clamp(a, 0.0, 0.85));
}
"""

var _rect: ColorRect
var _mat: ShaderMaterial
var _time: float = 0.0
var _glitch: float = 0.0
var _glitch_left: float = 0.0
var _shake: float = 0.0
var _shake_left: float = 0.0
var _tension: float = 0.0
var _danger: float = 0.0
var _camera: Camera2D = null


func _ready() -> void:
	add_to_group(GROUP)
	layer = 1
	_rect = ColorRect.new()
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_mat = ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = SHADER_CODE
	_mat.shader = shader
	_rect.material = _mat
	add_child(_rect)


## Radio interference for `seconds`, at `strength` 0..1.
func glitch(strength: float, seconds: float) -> void:
	_glitch = maxf(_glitch, clampf(strength, 0.0, 1.0))
	_glitch_left = maxf(_glitch_left, seconds)


## Shake the camera by up to `strength` px for `seconds`.
func shake(strength: float, seconds: float) -> void:
	_shake = maxf(_shake, strength)
	_shake_left = maxf(_shake_left, seconds)


func _process(delta: float) -> void:
	if not get_tree().get_nodes_in_group("ui_modal").is_empty():
		return
	_time += delta
	_read_world(delta)
	_glitch_left = maxf(_glitch_left - delta, 0.0)
	if _glitch_left <= 0.0:
		_glitch = move_toward(_glitch, 0.0, delta * 2.0)
	_mat.set_shader_parameter("t", _time)
	_mat.set_shader_parameter("tension", _tension)
	_mat.set_shader_parameter("glitch", _glitch)
	_mat.set_shader_parameter("danger", _danger)
	_apply_shake(delta)


func _read_world(delta: float) -> void:
	var tree := get_tree()
	var target_tension := 0.0
	var att := tree.get_first_node_in_group(ThreatAttention.GROUP) as ThreatAttention
	if att != null:
		target_tension = att.attention() / 100.0
	var lev := tree.get_first_node_in_group(Leviathan.GROUP) as Leviathan
	if lev != null and lev.is_near():
		target_tension = maxf(target_tension, 0.85)
	_tension = move_toward(_tension, target_tension, delta * 0.25)
	var target_danger := 0.0
	if not tree.get_nodes_in_group(BroodHunter.GROUP).is_empty():
		target_danger = 0.6
	var ship := GameNodes.ship(tree)
	if ship != null:
		var systems := ship.get_node_or_null("Systems")
		if systems != null and systems.has_method("is_hull_critical") and bool(systems.call("is_hull_critical")):
			target_danger = 1.0
	_danger = move_toward(_danger, target_danger, delta * 0.8)


func _apply_shake(delta: float) -> void:
	if _camera == null or not is_instance_valid(_camera):
		_camera = get_viewport().get_camera_2d()
	if _camera == null:
		return
	_shake_left = maxf(_shake_left - delta, 0.0)
	if _shake_left <= 0.0:
		_shake = move_toward(_shake, 0.0, delta * 40.0)
	if _shake > 0.01:
		_camera.offset = Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * _shake
	elif _camera.offset != Vector2.ZERO:
		_camera.offset = Vector2.ZERO
