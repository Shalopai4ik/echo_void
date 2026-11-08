extends SceneTree
## Ad-hoc visual playthrough: drives the real systems and saves screenshots.
const OUT := "res://test-output/shots/"

var map: Node
var ship: RigidBody2D
var systems: Node


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	call_deferred("_run")


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


func _run() -> void:
	map = (load("res://scenes/world/SpaceMap.tscn") as PackedScene).instantiate()
	root.add_child(map)
	ship = map.get_node("Ship")
	systems = ship.get_node("Systems")
	await _frames(240)
	await _save("p01_start")
	var slots := systems.get_node("Slots")
	slots.call("activate_slot", 0)
	await _frames(30)
	systems.get_node("Scanner").call("start_scan")
	await _frames(260)
	await _save("p02_scanned")
	slots.call("activate_slot", 1)
	var desk := systems.get_node("Research")
	var contacts: Array = systems.get_node("Scanner").call("last_contacts")
	var started := false
	for c in contacts:
		if str(c.get("id", "")) == "poi:tutorial_wreck":
			started = bool(desk.call("start_research", c))
	print("research started: ", started, " contacts=", contacts.size())
	await _frames(120)
	await _save("p03_researching")
	await _frames(60 * 12)
	await _save("p04_research_done")
	print("xp=", desk.call("get_xp"), " hull=", systems.call("hull_ratio"))
	# jump to chapter 3 and provoke the creature
	var mission := map.get_node("Mission")
	mission.call("debug_jump", 2)
	var att := map.get_node("Threats/Attention")
	att.call("set_attention", 95.0)
	var lev := map.get_node("Threats/Leviathan")
	lev.call("force_hunt")
	await _frames(60 * 6)
	print("lev state=", lev.call("state_name"), " dist=", lev.call("distance_to_ship"))
	await _save("p05_hunt")
	await _frames(60 * 3)
	print("brood=", get_nodes_in_group("brood").size())
	await _save("p06_brood")
	slots.call("activate_slot", 2)
	await _frames(20)
	slots.call("activate_slot", 3)
	await _frames(60 * 2)
	await _save("p07_decoy_flare")
	await _frames(60 * 6)
	print("brood after decoy=", get_nodes_in_group("brood").size(), " hull=", systems.call("hull_ratio"))
	lev.call("request_manifest")
	await _frames(60 * 4)
	print("lev state=", lev.call("state_name"))
	await _save("p08_manifest")
	# open pause menu & main menu for screenshots
	var pause := map.get_node("PauseMenuConsole")
	pause.call("open_panel")
	await _frames(10)
	(pause.get_node("Screen") as PauseMenuScreen).settings_panel().visible = true
	await _frames(5)
	await _save("p09_pause")
	pause.call("close_panel")
	map.get_node("UpgradesConsole").call("open_panel")
	await _frames(10)
	await _save("p10_upgrades")
	map.get_node("UpgradesConsole").call("close_panel")
	map.get_node("RunEnd").call("show_end", true, "ДЕМОВЕРСИЯ ЗАВЕРШЕНА", MissionStory.ENDING_TEXT, mission.call("stats"))
	await _frames(10)
	await _save("p11_end")
	var mm := map.get_node("MainMenuConsole")
	mm.call("open_in", MainMenuScreen.Mode.START)
	await _frames(10)
	await _save("p12_menu")
	print("feed history: ", map.get_node("FlightOverlay").feed.history.size())
	for h in map.get_node("FlightOverlay").feed.history:
		print("  ", h["title"], " | ", h["message"])
	print("comms: ")
	for l in map.get_node("FlightOverlay").comms.log_lines:
		print("  ", l)
	print("sounds: ", map.get_node("SoundBank").played)
	quit(0)


func _save(file: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	var image: Image = root.get_texture().get_image()
	image.save_png(OUT + file + ".png")
	print("saved ", file, " speed=", ship.call("speed"), " mode=", ship.call("mode_name"), " pos=", ship.global_position)
