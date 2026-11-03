extends Node2D
class_name EngineVisuals

## The layer that decides what each nozzle looks like, and nothing else.
##
## It reads `EngineController` and writes pictures. That direction is the whole
## design: the flight model asks for a burn, the plant turns it into power, and
## this file turns power into flame. It never reads input, never touches the hull's
## velocity, and holds no number that the physics also owns - so a jet cannot make
## the ship move, and the ship moving cannot make a jet lie about what is burning.
##
## Three things decide a nozzle's brightness:
## - its group's power, which is the force;
## - how well the nozzle is aimed at the direction that force wants (the plant's
##   `thrust_local`), normalised so the best-aimed nozzle in a group reads full -
##   which is what makes a retro burn appear on the side of the hull the speed is
##   actually coming from, instead of always at the nose;
## - for the yaw verniers, which end of the turn they belong to, because a couple
##   has no direction to be aimed at.
##
## Every nozzle fades with `engine_effect_fade_time` rather than switching, so a
## group coming on or off is a ramp the eye can follow, and the fade is the same
## number for all eleven anchors - one knob for the whole ship's look.

## The plant this layer draws for. Left unset, it is found as the ship's own
## `Engines` child, which is how the scene wires them together without a designer
## having to drag a reference.
@export var controller: EngineController

var _parameters: ShipEngineParameters
## The power each nozzle was last drawn at, keyed by instance id. This is the
## smoothed value the eye sees; the controller's power is what the physics asked
## for, and the gap between them is exactly the fade.
var _shown := {}


func _ready() -> void:
	if controller == null:
		controller = get_parent().get_node_or_null("Engines") as EngineController
	if controller == null:
		return
	_parameters = controller.settings()
	for anchor in _anchors():
		adopt(anchor)


## Take one anchor into the layer: give it the parameters, turn its flame to face
## the way it pushes, and start it dark. Split out because a station created at
## runtime - a spare nozzle, a pod a later stage bolts on - has to be adopted the
## same way the scene's own are, not through a second code path.
func adopt(anchor: EngineNozzle) -> void:
	var jet := jet_of(anchor)
	if jet == null:
		return
	jet.parameters = _parameters
	# The flame is authored extending toward -X, so aligning it with the push
	# direction puts the exhaust on the correct side automatically.
	jet.face(anchor.thrust_local.angle())
	_shown[anchor.get_instance_id()] = 0.0


func _process(delta: float) -> void:
	if controller == null:
		return
	var fade := maxf(_parameters.engine_effect_fade_time if _parameters != null else 0.12, 0.001)
	var aim := _group_aims()
	for anchor in _anchors():
		var demand := _demand_for(anchor, aim)
		var id := anchor.get_instance_id()
		var shown: float = _shown.get(id, 0.0)
		shown = move_toward(shown, demand, delta / fade)
		_shown[id] = shown
		var jet := jet_of(anchor)
		if jet != null:
			jet.set_power(shown)


## What a nozzle is showing right now: the smoothed power its jet is drawn at.
## Read this rather than the controller's demand when something has to know what
## the picture looks like - the whole point of the fade is that the flame lags the
## physics by `engine_effect_fade_time`.
func shown(anchor: EngineNozzle) -> float:
	return _shown.get(anchor.get_instance_id(), 0.0)


## The anchors of one group, or all of them.
func anchors(group: String = "") -> Array[EngineNozzle]:
	return _anchors(group)


## The direction each group is pushing, in hull axes, plus the signed demand of the
## two groups that work in pairs. Read once per frame so the eleven nozzles cannot
## disagree with each other about what the plant is doing.
func _group_aims() -> Dictionary:
	return {
		"main": Vector2.RIGHT,
		"brake": controller.brake_direction_local(),
		"strafe": Vector2.DOWN * signf(controller.strafe_demand()),
		"spin": signf(controller.rotation_demand()),
	}


## How bright one anchor should be, before the fade.
func _demand_for(anchor: EngineNozzle, aim: Dictionary) -> float:
	match anchor.thruster:
		"main":
			return controller.main_power * _aim_share(anchor, aim["main"], "main")
		"brake":
			return controller.brake_power * _aim_share(anchor, aim["brake"], "brake")
		"strafe":
			return absf(controller.strafe_demand()) \
				* _aim_share(anchor, aim["strafe"], "strafe")
		"rotation":
			# A yaw vernier is a couple: it belongs to one end of the turn, and the
			# pair on the other end must be dark, not dim.
			if anchor.spin == 0 or signf(aim["spin"]) != float(anchor.spin):
				return 0.0
			return absf(controller.rotation_demand()) * anchor.authority
	return 0.0


## The nozzles of one group are aimed at different quarters, so the group's force
## is shared out by how well each one can serve it - normalised against the best
## aim in that group. Without the normalisation a 45-degree retro pair would draw
## at 0.71 of a burn that is working at full power, and the picture would disagree
## with the physics it is supposed to show.
func _aim_share(anchor: EngineNozzle, wanted: Vector2, group: String) -> float:
	if wanted.length_squared() < 0.0001:
		return 0.0
	var best := 0.0
	var mine := 0.0
	for other in _anchors(group):
		best = maxf(best, other.alignment_local(wanted))
	mine = anchor.alignment_local(wanted)
	if best <= 0.0001:
		return 0.0
	return clampf(mine / best, 0.0, 1.0) * anchor.authority


## The jet hanging under an anchor, if it has one. Anchors without a jet are legal:
## a station that is wired up for a thruster the art has not drawn yet.
func jet_of(anchor: Node2D) -> EngineJet:
	for child in anchor.get_children():
		if child is EngineJet:
			return child as EngineJet
	return null


func _anchors(group: String = "") -> Array[EngineNozzle]:
	var out: Array[EngineNozzle] = []
	for child in get_children():
		if child is EngineNozzle and (group == "" or child.thruster == group):
			out.append(child)
	return out
