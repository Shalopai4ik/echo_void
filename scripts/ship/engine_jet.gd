extends Node2D
class_name EngineJet

## The picture of one thruster working.
##
## Three authored layers and a handful of sparks, all hanging off the nozzle's own
## pivot: the textures are drawn uncentred with `offset = -(width, height/2)`, so
## the right edge of every layer stays exactly in the nozzle however long the flame
## is or however the ship turns. That is what lets the same scene serve the main
## engine at 120 world px and a yaw vernier at 40.
##
## This file draws. It does not decide: the power it is shown comes from
## `EngineVisuals`, which got it from `EngineController`, which got it from the
## flight model. Nothing here touches the hull's motion, and no particle is
## connected to a physical calculation - the sparks are a consequence of the burn,
## never a cause of anything.

@onready var halo: Sprite2D = $Halo
@onready var plume: Sprite2D = $Plume
@onready var core: Sprite2D = $Core
@onready var sparks: CPUParticles2D = $Sparks

## Per-nozzle size: 1.0 is the authored main-engine exhaust, a vernier is a
## fraction of it. Multiplied by `engine_effect_scale` from the parameters.
@export_range(0.05, 3.0, 0.01) var size := 1.0
## The engine plant's visual knobs. Assigned by `EngineVisuals` from the ship's own
## resource, so one file holds every number and the scene does not carry eleven
## copies of the same settings.
var parameters: ShipEngineParameters


## Point the flame along the direction this nozzle pushes. The exhaust leaves the
## other way, and the textures are authored extending toward -X, so aligning the
## jet with the push is a rotation by the push's own angle.
func face(push_angle: float) -> void:
	rotation = push_angle


## Draw the jet at `power`, which is the group's authority as the plant reached it:
## 0..1 of what this nozzle is allowed to be doing, and *above* 1.0 for the main
## engine under boost. Below a floor the whole thing is switched off rather than
## drawn at alpha 0.01, so an idle nozzle costs the renderer nothing and cannot leave
## a stray bright pixel on the hull.
##
## The boost case is why `length` reads `power` and every alpha reads `intensity`:
## over-authorised means a longer flame and a wider halo, not a flame that has gone
## white. A sprite cannot exceed opaque, and a jet that tried would just be a
## rectangle.
func set_power(power: float) -> void:
	var p := parameters if parameters != null else ShipEngineParameters.new()
	var burning := power > 0.02
	visible = burning
	if not burning:
		sparks.emitting = false
		return
	var glow := p.engine_glow_intensity
	var intensity := minf(power, 1.0)
	var length := p.engine_effect_scale * size * (0.3 + 0.7 * power)
	# Width scales with `size` as well as with power: a vernier is a short jet, not
	# a stubby one, and the authored 18 px strip has to shrink along the hull it
	# belongs to or the small nozzles end up wider than they are long.
	var width := p.engine_effect_scale * size
	plume.scale = Vector2(2.0 * length, 2.0 * width * (0.6 + 0.4 * intensity))
	plume.modulate.a = (0.35 + 0.65 * intensity) * glow
	core.scale = Vector2(2.0 * length * 0.75, 2.0 * width * (0.5 + 0.5 * intensity))
	core.modulate.a = (0.4 + 0.6 * intensity) * glow
	# The halo is the one layer that keeps growing past full power, which is how a
	# boosted engine reads as more light around the same nozzle rather than a
	# different-shaped flame: 1.3 at cruise, 2.3 at boost x1.8.
	halo.scale = Vector2(2.0 * length, 2.0 * width * (1.0 + 0.35 * maxf(power - 1.0, 0.0)))
	halo.modulate.a = minf(0.3 * power * glow, 0.55)
	# The buffer size is set once - `amount` resizes the particle pool, so a jet
	# that re-wrote it every frame would stutter. Intensity rides on alpha and on
	# the speed the sparks leave at, which are read as each particle is born.
	sparks.amount = p.engine_particles_amount
	sparks.modulate.a = intensity * glow * 0.8
	sparks.initial_velocity_min = 30.0 + 60.0 * intensity
	sparks.initial_velocity_max = 60.0 + 90.0 * intensity
	sparks.emitting = intensity > 0.05
