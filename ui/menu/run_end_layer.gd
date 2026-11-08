extends CanvasLayer
class_name RunEndLayer

## Hosts the end-of-run screen and answers the mission's "show_end" call
## (group "run_end"). Its buttons are real: a new run reloads the flight and
## skips the menu, "Главное меню" opens the main menu in its finished mode,
## "Выход" quits.

const GROUP := "run_end"

var screen: RunEndScreen


func _ready() -> void:
	add_to_group(GROUP)
	layer = 8
	process_mode = Node.PROCESS_MODE_ALWAYS
	screen = RunEndScreen.new()
	screen.name = "Screen"
	add_child(screen)
	screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	screen.new_run_requested.connect(_on_new_run)
	screen.menu_requested.connect(_on_menu)
	screen.quit_requested.connect(func() -> void: get_tree().quit())


func show_end(victory: bool, title: String, text: String, stats: Dictionary) -> void:
	get_tree().call_group("music", "force_mood", MusicDirector.Mood.UNCERTAIN if victory else MusicDirector.Mood.TENSION)
	screen.show_result(victory, title, text, stats)


func _on_new_run() -> void:
	MainMenuConsole._skip_next_boot = true
	get_tree().reload_current_scene()


func _on_menu() -> void:
	for node in get_tree().get_nodes_in_group(InterfaceConsole.GROUP):
		if str(node.get("panel_id")) == "main_menu" and node.has_method("open_in"):
			node.call("open_in", MainMenuScreen.Mode.FINISHED)
			return
