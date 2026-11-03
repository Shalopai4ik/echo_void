extends SceneTree

## One-shot author of the world settings file.
##
## The defaults live in code (`EchoWorldField.default_settings()`), because that is
## the only way the game still runs if the resource is missing. This turns those
## defaults into a real `.tres` on disk, which is what the inspector then edits.
## Run after changing the code defaults only if you want the file to catch up:
##     godot --headless --path . --script tools/author_world_settings.gd

const FIELD := preload("res://scripts/world/world_field.gd")
const PATH := "res://assets/world/space_generation.tres"


func _initialize() -> void:
	var field: EchoWorldField = FIELD.new()
	root.add_child(field)
	var s: SpaceGenerationSettings = field.default_settings()
	var err := ResourceSaver.save(s, PATH)
	print("save %s -> %s" % [PATH, error_string(err)])
	var again: SpaceGenerationSettings = load(PATH)
	print("reloaded: seed=%d kinds=%d" % [again.world_seed, again.kinds.size()])
	for k in again.kinds:
		print("  %-12s %s  chance=%.2f step=%.0f..%.0f parallax=%.2f classes=%d"
			% [k.label, "solid" if k.physics else "decor", k.chance, k.min_distance,
				k.max_distance, k.parallax, k.classes.size()])
	quit(0 if err == OK else 1)
