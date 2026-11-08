class_name GameFeed

## The three loose channels the world uses to talk to the pilot, as groups:
##
##   * "notification_feed" - short system messages in the corner of the glass;
##   * "comms"             - radio transmissions and logs, the story's voice;
##   * "sound_fx"          - one-shot sounds by name.
##
## A system that wants to say something calls one of these helpers; it never
## holds a reference to the HUD, and a scene without a feed (a bare test)
## simply says nothing. Kinds for notify(): 0 info, 1 warning, 2 problem.

const INFO := 0
const WARNING := 1
const PROBLEM := 2


static func notify(tree: SceneTree, kind: int, title: String, message: String) -> void:
	if tree != null:
		tree.call_group("notification_feed", "push", kind, title, message)


static func comms(tree: SceneTree, speaker: String, text: String, tag: String = "") -> void:
	if tree != null:
		tree.call_group("comms", "say", speaker, text, tag)


static func sfx(tree: SceneTree, name: String, at: Variant = null, volume_db: float = 0.0) -> void:
	if tree != null:
		tree.call_group("sound_fx", "play", name, at, volume_db)


static func shake(tree: SceneTree, strength: float, seconds: float) -> void:
	if tree != null:
		tree.call_group("screen_fx", "shake", strength, seconds)


static func glitch(tree: SceneTree, strength: float, seconds: float) -> void:
	if tree != null:
		tree.call_group("screen_fx", "glitch", strength, seconds)
