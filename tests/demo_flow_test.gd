extends SceneTree

## Headless suite for the demo layer (stages 6.6 - 12): every new system
## against the real flight scene, no stand-ins.
##
##   1. the game clock stops behind a panel and the held world stays put;
##   2. decoys and flares are limited by charges, refuse when empty, and the
##      capacity upgrades really grow the rack;
##   3. the scanner finds research objects; studying one pays XP and applies
##      the kind's reward to the ship; the desk waits when the hull is far;
##   4. the creature's ear: noise raises attention, silence lowers it;
##   5. the creature: it is lured by a flare, it hunts and sends the brood,
##      the brood is lured by a decoy and dies on it, a beam hurts the hull;
##   6. upgrades: research speed changes the desk, a one-time module cannot
##      be bought twice;
##   7. the mission: the tutorial steps move the chapter on, the waypoint
##      points at real objects, the ending and the death screen open;
##   8. menus and sound: menu modes, volume sliders move the buses, every
##      sound the game asks for exists, the music mood follows the threat.
##
## Run: godot --headless --path . --script tests/demo_flow_test.gd

var _failed := 0
var map: Node
var ship: RigidBody2D
var systems: Node


func _initialize() -> void:
	call_deferred("_run")


func _check(name: String, condition: bool, detail: String = "") -> void:
	if condition:
		print("PASS  ", name, "  ", detail)
	else:
		_failed += 1
		print("FAIL  ", name, "  ", detail)


func _steps(count: int) -> void:
	for i in count:
		await physics_frame


func _run() -> void:
	map = (load("res://scenes/world/SpaceMap.tscn") as PackedScene).instantiate()
	root.add_child(map)
	ship = map.get_node("Ship")
	systems = ship.get_node("Systems")
	await _steps(30)
	await _clock_and_pause()
	await _charges()
	await _research_objects()
	await _attention()
	await _creature()
	await _upgrades()
	await _mission()
	await _menus_and_sound()
	print("RESULT: ", "FAILED" if _failed > 0 else "ALL PASS", "  demo flow")
	quit(1 if _failed > 0 else 0)


func _clock_and_pause() -> void:
	print("-- 1. game clock and pause")
	var t0 := ShipSystemEvent.now()
	var lev := map.get_node("Threats/Leviathan") as Node2D
	var at := lev.global_position
	var pause := map.get_node("PauseMenuConsole")
	pause.call("open_panel")
	await _steps(90)
	var held := ShipSystemEvent.now()
	_check("the game clock stands still behind a panel", is_equal_approx(held, t0) or held - t0 < 0.05,
		"%.3f -> %.3f" % [t0, held])
	_check("the creature is held with the world", lev.global_position == at)
	_check("the creature joins the held set",
		lev.process_mode == Node.PROCESS_MODE_DISABLED)
	pause.call("close_panel")
	await _steps(30)
	_check("the clock runs again after the panel closes", ShipSystemEvent.now() > held + 0.3)
	_check("the creature runs again", lev.process_mode != Node.PROCESS_MODE_DISABLED)


func _charges() -> void:
	print("-- 2. decoys and flares are limited")
	var launcher := systems.get_node("DecoyLauncher")
	var light := systems.get_node("SignalLight")
	var slots := systems.get_node("Slots")
	_check("the launcher starts with a limited magazine", int(launcher.get("charges")) == 2
		and float(launcher.get("max_charges")) == 3.0)
	_check("slot 3 fires the decoy launcher", bool(slots.call("activate_slot", 2)))
	await _steps(5)
	_check("one decoy spent", int(launcher.get("charges")) == 1)
	_check("the decoy is in the world", get_nodes_in_group("decoy").size() == 1)
	var decoy := get_nodes_in_group("decoy")[0] as Node2D
	var from := decoy.global_position
	await _steps(30)
	var air := root.get_node("SignalBroadcaster")
	var msgs: Array = air.call("messages")
	var follows := false
	for m in msgs:
		if str(m["kind"]).begins_with("decoy") and (m["position"] as Vector2).distance_to(decoy.global_position) < 80.0:
			follows = true
	_check("the decoy's signal follows it through space", follows and decoy.global_position.distance_to(from) > 50.0)
	launcher.set("charges", 0)
	launcher.set("_cooldown_until", 0.0)
	_check("an empty magazine refuses", not bool(launcher.call("launch", Vector2.RIGHT)))
	_check("add_charges refills up to the cap", int(launcher.call("add_charges", 5)) == 3)
	_check("slot 4 drops a flare", bool(slots.call("activate_slot", 3)))
	await _steps(3)
	_check("a flare burns in the world", get_nodes_in_group("flare").size() == 1)
	_check("one flare spent", int(light.get("charges")) == 2)
	var status: Dictionary = slots.call("slot_status", 3)
	_check("the slot reports charges and the flare", int(status.get("charges", -1)) == 2
		and str(status.get("component_id", "")) == "signal_light")
	# let the flare burn out and clear the air for the next phases
	light.call("_end_signal", "finished")
	for d in get_nodes_in_group("decoy"):
		d.call("_finish")
	await _steps(90)
	_check("the flare goes out with its signal", get_nodes_in_group("flare").is_empty())


func _research_objects() -> void:
	print("-- 3. research objects")
	var scanner := systems.get_node("Scanner")
	var desk := systems.get_node("Research")
	systems.call("set_enabled", "scanner", true)
	systems.call("set_enabled", "research", true)
	var field := map.get_node("POIField") as POIField
	var crystal := field.story_poi("tutorial_crystal")
	_check("the mission placed the tutorial objects", crystal != null and field.story_poi("tutorial_wreck") != null)
	ship.global_position = crystal.global_position + Vector2(300, 0)
	ship.linear_velocity = Vector2.ZERO
	await _steps(5)
	scanner.call("start_scan")
	await _steps(300)
	var contact := {}
	for c in scanner.call("last_contacts"):
		if str(c.get("id", "")) == "poi:tutorial_crystal":
			contact = c
	_check("the scanner finds a research object", not contact.is_empty(), str(contact.get("signature", "")))
	_check("the object is named", bool(contact.get("identified", false)) and str(contact.get("title", "")) != "")
	_check("the object is marked as discovered", crystal.is_discovered())
	systems.call("set_energy", 300.0)
	var energy_before := float(systems.call("energy_charge"))
	var xp_before := int(desk.call("get_xp"))
	_check("the desk accepts the object", bool(desk.call("start_research", contact)))
	ship.global_position = crystal.global_position + Vector2(4000, 0)
	await _steps(120)
	_check("far from the object the analysis waits", bool(desk.call("is_out_of_range"))
		and float(desk.call("progress")) < 0.05, "%.2f" % float(desk.call("progress")))
	ship.global_position = crystal.global_position + Vector2(300, 0)
	await _steps(60 * 22)
	_check("the analysis completes", bool(desk.call("is_completed", "poi:tutorial_crystal")))
	_check("XP is paid", int(desk.call("get_xp")) >= xp_before + 45, str(desk.call("get_xp")))
	_check("the crystal's energy reaches the reserve", float(systems.call("energy_charge")) > energy_before + 200.0,
		"%.0f -> %.0f" % [energy_before, float(systems.call("energy_charge"))])
	_check("a studied object reads as studied", crystal.is_studied())


func _attention() -> void:
	print("-- 4. the creature's ear")
	var att := map.get_node("Threats/Attention") as ThreatAttention
	att.threat_scale = 1.0
	att.set_attention(0.0)
	systems.get_node("Scanner").call("start_scan")
	await _steps(10)
	_check("a sweep is heard", att.attention() > 5.0, "%.1f" % att.attention())
	_check("a sweep is loud", att.noise() > 0.8, "%.2f" % att.noise())
	await _steps(60 * 8)
	var after_sweep := att.attention()
	await _steps(60 * 5)
	_check("silence lowers attention", att.attention() < after_sweep, "%.1f -> %.1f" % [after_sweep, att.attention()])


func _creature() -> void:
	print("-- 5. the creature")
	var att := map.get_node("Threats/Attention") as ThreatAttention
	var lev := map.get_node("Threats/Leviathan") as Leviathan
	lev.set_aggression(3)
	ship.global_position = Vector2.ZERO
	ship.linear_velocity = Vector2.ZERO
	lev.place(Vector2(3000, 0))
	att.set_attention(90.0)
	lev.force_hunt()
	_check("a forced hunt approaches", lev.state() == Leviathan.State.APPROACHING)
	# a flare far away wins over a quiet ship
	var light := systems.get_node("SignalLight")
	light.set("_cooldown_until", 0.0)
	light.set("charges", 3)
	ship.global_position = Vector2(-2500, 0)
	light.call("activate")
	ship.global_position = Vector2.ZERO
	await _steps(5)
	_check("a burning flare lures the creature", lev.state() == Leviathan.State.INVESTIGATING)
	light.call("_end_signal", "finished")
	await _steps(5)
	# hunt again and let the brood come
	att.set_attention(90.0)
	lev.place(Vector2(1800, 0))
	lev.force_hunt()
	await _steps(60 * 2)
	var brood := get_nodes_in_group("brood")
	_check("the hunt sends the brood", brood.size() >= 1, str(brood.size()))
	if brood.is_empty():
		return
	var hunter := brood[0] as BroodHunter
	hunter.global_position = ship.global_position + Vector2(300, 0)
	var hull_before := float(systems.call("hull_ratio"))
	await _steps(60 * 3)
	_check("the brood's beam hurts the hull", float(systems.call("hull_ratio")) < hull_before,
		"%.2f -> %.2f" % [hull_before, float(systems.call("hull_ratio"))])
	var launcher := systems.get_node("DecoyLauncher")
	launcher.set("_cooldown_until", 0.0)
	launcher.call("add_charges", 3)
	systems.call("set_enabled", "decoy_launcher", true)
	hunter.global_position = ship.global_position + Vector2(500, 0)
	var brood_before := get_nodes_in_group("brood").size()
	_check("the decoy is launched at the hunter", bool(launcher.call("launch", Vector2.RIGHT)))
	await _steps(60 * 5)
	var dying := 0
	for h in get_nodes_in_group("brood"):
		if (h as BroodHunter).state() == BroodHunter.State.DYING:
			dying += 1
	_check("a hunter chases the decoy and dies on it", get_nodes_in_group("brood").size() + dying > 0
		and (get_nodes_in_group("brood").size() < brood_before or dying > 0),
		"%d -> %d, dying %d" % [brood_before, get_nodes_in_group("brood").size(), dying])
	_check("the decoy was consumed early", get_nodes_in_group("decoy").is_empty())
	for h in get_nodes_in_group("brood"):
		h.queue_free()
	lev.request_manifest()
	att.set_attention(95.0)
	lev.place(Vector2(1500, 0))
	lev.set_aggression(4)
	lev.force_hunt()
	await _steps(10)
	_check("the creature can show itself", lev.state() == Leviathan.State.MANIFEST, lev.state_name())
	var music := map.get_node("Music") as MusicDirector
	await _steps(5)
	_check("the music turns to the climax", music.mood() == MusicDirector.Mood.CLIMAX, music.mood_name())
	await _steps(60 * 12)
	_check("after showing itself it withdraws", lev.state() in [Leviathan.State.RETREATING, Leviathan.State.HIDDEN],
		lev.state_name())
	for h in get_nodes_in_group("brood"):
		h.queue_free()
	lev.set_aggression(0)
	att.set_attention(0.0)
	systems.call("repair_hull", 1.0)


func _upgrades() -> void:
	print("-- 6. upgrades")
	var mgr := systems.get_node("UpgradeDesk")
	var desk := systems.get_node("Research")
	desk.set("_xp", 2000)
	var before := float(desk.get("time_multiplier"))
	_check("research speed can be bought", bool(mgr.call("purchase", "research.speed")))
	_check("research speed changes the desk", float(desk.get("time_multiplier")) < before,
		"%.2f -> %.2f" % [before, float(desk.get("time_multiplier"))])
	_check("the threat module can be bought", bool(mgr.call("purchase", "scanner.threat_sense")))
	_check("the threat module is fitted", float(systems.get_node("Scanner").get("threat_sense")) >= 1.0)
	_check("a one-time module cannot be bought twice", not bool(mgr.call("purchase", "scanner.threat_sense")))
	var launcher := systems.get_node("DecoyLauncher")
	_check("the magazine upgrade grows the launcher", bool(mgr.call("purchase", "decoy.capacity"))
		and float(launcher.get("max_charges")) == 4.0, str(launcher.get("max_charges")))
	var light := systems.get_node("SignalLight")
	_check("flare upgrades reach the mounted rack", bool(mgr.call("purchase", "signal_light.radius")))
	var snap := UpgradesSnapshot.build(mgr)
	var ids: Array = []
	for d in snap:
		ids.append(d.id)
	_check("the upgrades panel lists all four devices", ids.has("research") and ids.has("signal_light")
		and ids.has("decoy_launcher") and ids.has("scanner"), str(ids))
	_check("the flare rack still works after upgrades", float(light.get("radius_px")) > 2400.0)


func _mission() -> void:
	print("-- 7. the mission")
	var mission := map.get_node("Mission") as MissionDirector
	_check("the tutorial chapter is done (scanner, sweep, desk, study)", mission.chapter() >= 1,
		mission.chapter_title())
	var wp := mission.waypoint()
	_check("the waypoint points at the first beacon", not wp.is_empty() and str(wp["label"]).begins_with("МАЯК"))
	var field := map.get_node("POIField") as POIField
	_check("the beacons are in the world", field.story_poi("beacon_1") != null and field.story_poi("beacon_3") != null)
	var lines: Array = mission.objective_lines()
	_check("the HUD gets objective lines", lines.size() >= 1, str(lines))
	mission.debug_jump(4)
	await _steps(5)
	_check("the finale places the Source", field.story_poi("source") != null)
	mission._flags["source_done"] = true
	ship.global_position = MissionStory.route()["extraction"]
	await _steps(30)
	var end := map.get_node("RunEnd") as RunEndLayer
	_check("reaching the extraction ends the demo", mission.is_finished() and end.screen.is_open()
		and end.screen.is_victory())
	end.screen.close()
	await _steps(5)


func _menus_and_sound() -> void:
	print("-- 8. menus and sound")
	var menu := map.get_node("MainMenuConsole")
	menu.call("open_in", MainMenuScreen.Mode.FINISHED)
	await _steps(2)
	var screen := menu.get_node("Screen") as MainMenuScreen
	_check("a finished run's menu offers no 'continue'", not (screen.get_node("%Continue") as Button).visible)
	screen.settings_panel().visible = true
	var music_slider := screen.settings_panel().slider("music")
	music_slider.value = 0.25
	_check("the music slider moves the Music bus",
		absf(AudioMixer.volume_linear(&"Music") - 0.25) < 0.02, "%.2f" % AudioMixer.volume_linear(&"Music"))
	music_slider.value = 0.7
	menu.call("close_panel")
	var bank := map.get_node("SoundBank") as SoundBank
	var names := ["scan", "scan_done", "research_done", "discover", "ui_click", "ui_confirm", "upgrade",
		"refuse", "warning", "alarm", "hull_hit", "comms_in", "radio_static", "phantom_ping",
		"creature_call", "creature_near", "creature_roar", "tremor", "power_flicker", "flare",
		"decoy_launch", "brood_emerge", "brood_attack", "brood_die", "power_on"]
	var missing: Array = []
	for n in names:
		if not bank.has_sound(n):
			missing.append(n)
	_check("every sound the game plays exists", missing.is_empty(), str(missing))
	var audio := ship.get_node("Audio")
	if audio.has_method("missing_streams"):
		var miss: Variant = audio.call("missing_streams")
		_check("the ship's 19 streams are on disk", (miss as Array).is_empty(), str(miss))
	var feed := map.get_node("FlightOverlay").feed as NotificationFeed
	var titles: Array = []
	for h in feed.history:
		titles.append(h["title"])
	_check("discoveries were announced", titles.has("ОБНАРУЖЕН ОБЪЕКТ"))
	_check("finished studies were announced", "КРИСТАЛЛИЧЕСКОЕ ТЕЛО ИЗУЧЕН" in titles, str(titles))
	_check("purchases were announced", titles.has("УЛУЧШЕНИЕ"))
	_check("hull damage was announced", titles.has("КОРПУС"))
