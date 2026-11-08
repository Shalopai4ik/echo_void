extends SceneTree

## The cinematic trailer, played out by the game's own systems and recorded
## with Godot's Movie Maker. Nothing is pre-rendered: the ship, the belt, the
## gas giant, the research objects, the brood, the decoy, the flare and the
## creature's manifestation are the real nodes, driven along a timeline.
##
## Record (writes an AVI with the game's own audio):
##   godot --path . --write-movie build/trailer/trailer.avi --fixed-fps 30 \
##         --resolution 1920x1080 --script tools/trailer/trailer.gd
## Then tools/trailer/make_trailer.ps1 encodes the MP4.

const FPS := 30.0

var map: Node
var ship: RigidBody2D
var systems: Node
var cam: Camera2D
var lev: Leviathan
var music: MusicDirector
var field: POIField
var layer: CanvasLayer
var fade: ColorRect
var card_title: Label
var card_sub: Label
var _ship_vel := Vector2.ZERO
var _cam_follow := true
var _cam_offset := Vector2.ZERO


func _initialize() -> void:
	call_deferred("_run")


func _wait(seconds: float) -> void:
	for i in int(seconds * FPS):
		await process_frame


func _run() -> void:
	map = (load("res://scenes/world/SpaceMap.tscn") as PackedScene).instantiate()
	root.add_child(map)
	ship = map.get_node("Ship")
	systems = ship.get_node("Systems")
	lev = map.get_node("Threats/Leviathan")
	music = map.get_node("Music")
	field = map.get_node("POIField")
	_quiet_the_game()
	_build_layer()
	cam = Camera2D.new()
	map.add_child(cam)
	cam.make_current()
	cam.zoom = Vector2.ONE * 0.32
	physics_frame.connect(_drive)
	process_frame.connect(_camera)
	await _wait(0.2)
	await _timeline()
	quit(0)


## No tutorial, no comms, no random events: the trailer directs everything.
func _quiet_the_game() -> void:
	map.get_node("Mission").process_mode = Node.PROCESS_MODE_DISABLED
	map.get_node("Threats/Atmosphere").process_mode = Node.PROCESS_MODE_DISABLED
	(map.get_node("Threats/Attention") as ThreatAttention).threat_scale = 0.0
	lev.set_aggression(0)
	lev.place(Vector2(40000, -40000))
	ship.collision_mask = 0
	ship.collision_layer = 0
	(map.get_node("HUD") as CanvasLayer).visible = false
	(map.get_node("FlightOverlay") as CanvasLayer).visible = false
	music.force_mood(MusicDirector.Mood.CALM)


func _build_layer() -> void:
	layer = CanvasLayer.new()
	layer.layer = 30
	map.add_child(layer)
	var bars := Control.new()
	bars.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bars.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(bars)
	for top in [true, false]:
		var bar := ColorRect.new()
		bar.color = Color.BLACK
		bar.anchor_right = 1.0
		if top:
			bar.offset_bottom = 66.0
		else:
			bar.anchor_top = 1.0
			bar.anchor_bottom = 1.0
			bar.offset_top = -66.0
		bars.add_child(bar)
	fade = ColorRect.new()
	fade.color = Color.BLACK
	fade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(fade)
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(box)
	card_title = Label.new()
	card_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	card_title.add_theme_font_size_override("font_size", 30)
	card_title.add_theme_color_override("font_color", Color(0.85, 0.96, 1.0))
	card_title.add_theme_color_override("font_shadow_color", Color(0.2, 0.7, 0.9, 0.5))
	card_title.add_theme_constant_override("shadow_outline_size", 6)
	card_title.modulate.a = 0.0
	box.add_child(card_title)
	card_sub = Label.new()
	card_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	card_sub.add_theme_font_size_override("font_size", 13)
	card_sub.add_theme_color_override("font_color", Color(0.45, 0.78, 0.86))
	card_sub.modulate.a = 0.0
	box.add_child(card_sub)


## A title card: fades in, holds, fades out. Not awaited by the caller.
func _card(title: String, sub: String, hold: float, size: int = 30) -> void:
	card_title.text = _spaced(title)
	card_sub.text = sub
	card_title.add_theme_font_size_override("font_size", size)
	var t := create_tween()
	t.tween_property(card_title, "modulate:a", 1.0, 0.7)
	t.parallel().tween_property(card_sub, "modulate:a", 1.0, 1.0)
	t.tween_interval(hold)
	t.tween_property(card_title, "modulate:a", 0.0, 0.7)
	t.parallel().tween_property(card_sub, "modulate:a", 0.0, 0.7)


func _spaced(text: String) -> String:
	var out := ""
	for i in text.length():
		out += text[i]
		if i < text.length() - 1 and text[i] != " ":
			out += " "
	return out


func _fade_to(alpha: float, seconds: float) -> void:
	create_tween().tween_property(fade, "color:a", alpha, seconds)


func _zoom_to(z: float, seconds: float) -> void:
	create_tween().set_trans(Tween.TRANS_SINE).tween_property(cam, "zoom", Vector2.ONE * z, seconds)


func _offset_to(o: Vector2, seconds: float) -> void:
	create_tween().set_trans(Tween.TRANS_SINE).tween_method(func(v: Vector2) -> void: _cam_offset = v,
		_cam_offset, o, seconds)


func _drive() -> void:
	if ship == null:
		return
	ship.linear_velocity = _ship_vel
	if _ship_vel.length() > 5.0:
		ship.rotation = lerp_angle(ship.rotation, _ship_vel.angle(), 0.05)
	ship.angular_velocity = 0.0


func _camera() -> void:
	if cam != null and _cam_follow:
		cam.global_position = cam.global_position.lerp(ship.global_position + _cam_offset, 0.08)


## ------------------------------------------------------------------ timeline ---

func _timeline() -> void:
	# 0 - 7: the giant, the dark, the ship
	ship.global_position = Vector2(-2600, 1800)
	ship.rotation = Vector2(0.6, -0.8).angle()
	cam.global_position = ship.global_position + Vector2(900, -700)
	_cam_offset = Vector2(700, -500)
	_ship_vel = Vector2(0.6, -0.8) * 160.0
	_fade_to(0.0, 3.0)
	await _wait(1.2)
	_card("ТИФОН", "газовый гигант · сектор 09 · орбита исследования", 3.2, 34)
	_zoom_to(0.42, 6.0)
	await _wait(5.8)
	# 7 - 13: the lost expedition
	_card("ТРИ ГОДА НАЗАД", "здесь пропала экспедиция «Пелагия»", 3.0)
	_offset_to(Vector2(120, -80), 5.0)
	_ship_vel = Vector2(0.6, -0.8) * 320.0
	await _wait(6.0)
	# 13 - 22: survey - the HUD, a sweep, the first finds
	field.add_story_poi("t_wreck", "hull_section", ship.global_position + Vector2(900, -900))
	field.add_story_poi("t_crystal", "crystal", ship.global_position + Vector2(-500, -1100))
	field.add_story_poi("t_buoy", "story_beacon", ship.global_position + Vector2(1500, -300))
	_ship_vel = Vector2(0.6, -0.8) * 120.0
	(map.get_node("HUD") as CanvasLayer).visible = true
	(map.get_node("FlightOverlay") as CanvasLayer).visible = true
	_zoom_to(0.5, 2.0)
	systems.call("set_enabled", "scanner", true)
	await _wait(0.6)
	systems.get_node("Scanner").call("start_scan")
	map.get_node("HUD/Root").call("_scan")
	_card("ИССЛЕДУЙ", "сканируй · изучай · улучшай корабль", 2.6)
	await _wait(4.0)
	music.force_mood(MusicDirector.Mood.UNCERTAIN)
	await _wait(4.4)
	(map.get_node("HUD") as CanvasLayer).visible = false
	(map.get_node("FlightOverlay") as CanvasLayer).visible = false
	# 22 - 30: the wreck of the Pelagia, something on the radio
	_fade_to(1.0, 0.4)
	await _wait(0.5)
	var pel_at := ship.global_position + Vector2(1600, -1400)
	field.add_story_poi("t_pelagia", "pelagia", pel_at)
	ship.global_position = pel_at + Vector2(-1500, 900)
	_ship_vel = (pel_at - ship.global_position).normalized() * 140.0
	cam.global_position = ship.global_position
	_cam_offset = Vector2(500, -350)
	cam.zoom = Vector2.ONE * 0.36
	_fade_to(0.0, 0.8)
	_card("ОНИ НАШЛИ ЧТО-ТО", "в облаках под кольцами", 3.0)
	await _wait(4.2)
	GameFeed.glitch(self, 0.7, 2.2)
	GameFeed.sfx(self, "radio_static")
	music.force_mood(MusicDirector.Mood.TENSION)
	_card("ОНО СЛЫШИТ ТЕБЯ", "каждый импульс сканера · каждый запуск двигателя", 2.4)
	await _wait(3.8)
	# 30 - 42: the brood
	_fade_to(1.0, 0.3)
	await _wait(0.35)
	ship.global_position = Vector2(6000, -6000)
	cam.global_position = ship.global_position
	_cam_offset = Vector2.ZERO
	cam.zoom = Vector2.ONE * 0.48
	_ship_vel = Vector2(1, 0) * 90.0
	ship.rotation = 0.0
	(map.get_node("Threats/Attention") as ThreatAttention).threat_scale = 1.0
	for i in 3:
		var h := BroodHunter.new()
		map.get_node("Threats").add_child(h)
		h.global_position = ship.global_position + Vector2.RIGHT.rotated(-0.9 + i * 0.9) * 900.0
	_fade_to(0.0, 0.3)
	music.force_mood(MusicDirector.Mood.DANGER)
	GameFeed.sfx(self, "alarm")
	await _wait(2.6)
	_card("НЕ ШУМИ", "", 1.4, 40)
	await _wait(2.4)
	systems.call("set_enabled", "decoy_launcher", true)
	systems.get_node("DecoyLauncher").call("launch", Vector2(0.3, -1.0))
	_card("ОБМАНИ", "ложные цели уводят выводок", 1.6, 40)
	await _wait(2.3)
	var light := systems.get_node("SignalLight")
	systems.call("set_enabled", "signal_light", true)
	light.call("activate")
	_ship_vel = Vector2(-1, 0.3).normalized() * 260.0
	_card("СВЕТИ", "огонь отпугивает малых и манит большое", 1.8, 40)
	await _wait(3.2)
	# 42 - 54: the manifestation
	_fade_to(1.0, 0.25)
	await _wait(0.3)
	for h in get_nodes_in_group("brood"):
		h.queue_free()
	light.call("_end_signal", "finished")
	ship.global_position = Vector2(12000, -15000)
	cam.global_position = ship.global_position
	_ship_vel = Vector2(0.6, -0.8) * 70.0
	cam.zoom = Vector2.ONE * 0.28
	_cam_offset = Vector2.ZERO
	(map.get_node("Threats/Attention") as ThreatAttention).set_attention(95.0)
	lev.manifest_sec = 12.0
	lev.set_aggression(4)
	lev.place(ship.global_position + Vector2(1400, 0))
	lev.request_manifest()
	lev.force_hunt()
	music.force_mood(MusicDirector.Mood.CLIMAX)
	_fade_to(0.0, 0.6)
	await _wait(1.5)
	for h in get_nodes_in_group("brood"):
		h.queue_free()
	_zoom_to(0.22, 9.0)
	await _wait(3.5)
	_card("НЕ СМОТРИ ВНИЗ", "", 2.4, 44)
	await _wait(6.0)
	# 54 - 66: title
	_fade_to(1.0, 1.4)
	await _wait(1.6)
	(map.get_node("HUD") as CanvasLayer).visible = false
	GameFeed.sfx(self, "impact_heavy")
	_card("ЭХО ПУСТОТЫ", "2D космический хоррор · демоверсия · Godot 4", 4.6, 64)
	await _wait(6.4)
	await _wait(1.0)
