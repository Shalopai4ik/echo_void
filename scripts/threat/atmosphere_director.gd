extends Node2D
class_name AtmosphereDirector

## The presence of the thing, between its appearances.
##
## Two jobs:
##
##   1. it narrates what the creature does in the language of the ship's
##      instruments - "interference rising", "large mass nearby", "biosignatures"
##      - so the pilot learns the creature's states without ever being told
##      them outright;
##   2. it schedules small uncanny events between the hunts: radio static, a
##      contact on the scope with nothing behind it, a call from very far away,
##      a tremor, a shadow under the ship. Their rate grows with the mission's
##      `level` and with the creature's attention, and there is always a gap of
##      quiet between two of them.

const GROUP := "atmosphere"
const WORLD_PAUSABLE_GROUP := "world_pausable"

## Set by the mission: 0 nothing strange happens, 4 the finale.
var level: int = 0

var _next_in: float = 50.0
var _lev: Leviathan = null
var _att: ThreatAttention = null
var _shadow_t: float = -1.0
var _shadow_from: Vector2
var _shadow_dir: Vector2
var _time: float = 0.0
var _whisper_index: int = 0

const WHISPERS := [
	["ПЕЛАГИЯ (ЗАПИСЬ)", "...говорит «Пелагия»... повторяю... не отвечайте на... ш-ш-ш..."],
	["НЕИЗВЕСТНЫЙ ИСТОЧНИК", "7 . 7 . 1 . 3 ... 7 . 7 . 1 . 3 ... (повтор каждые 41 с)"],
	["ПЕЛАГИЯ (ЗАПИСЬ)", "...оно идёт на свет. Не на корабль - на свет..."],
	["НЕИЗВЕСТНЫЙ ИСТОЧНИК", "...ваш собственный позывной, с задержкой 3,2 секунды..."],
	["ПЕЛАГИЯ (ЗАПИСЬ)", "...глубже, к облакам. Там оно спит. Там оно слышит всё..."],
]


func _ready() -> void:
	add_to_group(GROUP)
	add_to_group(WORLD_PAUSABLE_GROUP)
	z_index = -30
	call_deferred("_bind")


func _bind() -> void:
	_lev = get_tree().get_first_node_in_group(Leviathan.GROUP) as Leviathan
	_att = get_tree().get_first_node_in_group(ThreatAttention.GROUP) as ThreatAttention
	if _lev != null:
		_lev.state_changed.connect(_on_state_changed)
		_lev.lured.connect(_on_lured)
		_lev.brood_spawned.connect(_on_brood)
		_lev.manifested.connect(_on_manifest)


func set_level(value: int) -> void:
	level = clampi(value, 0, 4)
	_next_in = minf(_next_in, 30.0)


## -------------------------------------------------------------- narration ---

func _on_state_changed(_previous: int, current: int) -> void:
	var tree := get_tree()
	match current:
		Leviathan.State.OBSERVING:
			GameFeed.notify(tree, GameFeed.INFO, "СЕНСОРЫ",
				"Слабое периодическое возмущение на пределе дальности.")
			GameFeed.glitch(tree, 0.25, 1.0)
			GameFeed.sfx(tree, "radio_static", null, -8.0)
		Leviathan.State.INVESTIGATING:
			GameFeed.notify(tree, GameFeed.WARNING, "ПОМЕХИ",
				"Возмущение смещается. Что-то ищет источник шума.")
			GameFeed.glitch(tree, 0.4, 1.4)
		Leviathan.State.APPROACHING:
			GameFeed.notify(tree, GameFeed.PROBLEM, "ВНИМАНИЕ",
				"Крупная масса рядом. Снизьте шум: заглушите двигатели и сканер.")
			GameFeed.shake(tree, 6.0, 1.5)
			GameFeed.sfx(tree, "creature_near")
		Leviathan.State.RETREATING:
			GameFeed.notify(tree, GameFeed.INFO, "СЕНСОРЫ", "Возмущение уходит. Помехи стихают.")
		Leviathan.State.HIDDEN:
			_next_in = maxf(_next_in, 40.0)


func _on_lured(kind: String, _at: Vector2) -> void:
	var what := "сигнальный огонь" if kind.begins_with("signal_light") else "ложную цель"
	GameFeed.notify(get_tree(), GameFeed.INFO, "ОТВЛЕЧЕНИЕ",
		"Возмущение сместилось на %s." % what)


func _on_brood(count: int) -> void:
	GameFeed.notify(get_tree(), GameFeed.PROBLEM, "БИОСИГНАТУРЫ",
		"Малые объекты: %d. Идут на шум корпуса. Ложные цели [3], огни [4]." % count)
	GameFeed.sfx(get_tree(), "alarm")


func _on_manifest() -> void:
	GameFeed.shake(get_tree(), 14.0, 4.0)
	GameFeed.glitch(get_tree(), 0.8, 3.0)
	GameFeed.sfx(get_tree(), "creature_roar")
	GameFeed.notify(get_tree(), GameFeed.PROBLEM, "???", "Масса под кораблём превышает расчётную шкалу.")


## ------------------------------------------------------------------ events ---

func _physics_process(delta: float) -> void:
	_time += delta
	if _shadow_t >= 0.0:
		_shadow_t += delta
		if _shadow_t > 9.0:
			_shadow_t = -1.0
		queue_redraw()
	if level <= 0:
		return
	var urgency := 0.0
	if _att != null:
		urgency = _att.attention() / 100.0
	_next_in -= delta * (0.6 + 0.25 * float(level) + urgency * 0.5)
	if _next_in > 0.0:
		return
	_next_in = randf_range(38.0, 75.0)
	if _lev != null and _lev.is_near():
		return
	_fire(_pick())


func _pick() -> String:
	var pool: Array = ["static", "static", "phantom"]
	if level >= 2:
		pool += ["call", "whisper", "tremor"]
	if level >= 3:
		pool += ["shadow", "flicker", "call"]
	if _lev != null and _lev.state() == Leviathan.State.OBSERVING:
		pool += ["call", "phantom"]
	return pool[randi() % pool.size()]


## Fire one event by name. Public so the mission can script a specific one.
func fire(event_name: String) -> void:
	_fire(event_name)


func _fire(event_name: String) -> void:
	var tree := get_tree()
	var ship := GameNodes.ship(tree)
	match event_name:
		"static":
			GameFeed.glitch(tree, 0.55, 1.8)
			GameFeed.sfx(tree, "radio_static")
		"phantom":
			if ship != null:
				var at := ship.global_position + Vector2.RIGHT.rotated(randf() * TAU) * randf_range(900.0, 1800.0)
				tree.call_group("radar_overlay", "add_phantom", at, 4.0)
			GameFeed.notify(tree, GameFeed.WARNING, "СКАНЕР",
				"Контакт без отражения. Пропал через 4 секунды.")
			GameFeed.sfx(tree, "phantom_ping")
		"call":
			GameFeed.sfx(tree, "creature_call", null, -4.0)
			GameFeed.shake(tree, 2.5, 2.5)
		"whisper":
			var w: Array = WHISPERS[_whisper_index % WHISPERS.size()]
			_whisper_index += 1
			GameFeed.glitch(tree, 0.35, 2.5)
			GameFeed.sfx(tree, "radio_static", null, -6.0)
			GameFeed.comms(tree, str(w[0]), str(w[1]), "signal")
		"tremor":
			if ship != null and ship.has_method("apply_external_impulse"):
				var dir := Vector2.RIGHT.rotated(randf() * TAU)
				ship.call("apply_external_impulse", dir * 2400.0)
			GameFeed.shake(tree, 7.0, 1.2)
			GameFeed.sfx(tree, "tremor")
			GameFeed.notify(tree, GameFeed.WARNING, "ГРАВИМЕТР", "Локальное возмущение поля. Источник ниже облаков.")
		"flicker":
			tree.call_group("hud_flicker", "flicker", 1.6)
			GameFeed.sfx(tree, "power_flicker")
			GameFeed.notify(tree, GameFeed.WARNING, "ПИТАНИЕ", "Скачок напряжения в шине. Причина не установлена.")
		"shadow":
			if ship != null:
				_shadow_dir = Vector2.RIGHT.rotated(randf() * TAU)
				_shadow_from = ship.global_position - _shadow_dir * 2200.0 + _shadow_dir.orthogonal() * 700.0
				_shadow_t = 0.0
				GameFeed.sfx(tree, "creature_call", null, -10.0)


## A shadow under the belt: a long dim shape that crosses the frame slowly.
func _draw() -> void:
	if _shadow_t < 0.0:
		return
	var k := _shadow_t / 9.0
	var fade := sin(k * PI) * 0.4
	var center := to_local(_shadow_from + _shadow_dir * 4400.0 * k)
	var rot := _shadow_dir.angle()
	var pts := PackedVector2Array()
	for i in 32:
		var a := float(i) / 32.0 * TAU
		var p := Vector2(cos(a) * 1500.0, sin(a) * 380.0 * (1.0 + 0.2 * sin(a * 3.0 + _time)))
		pts.append(center + p.rotated(rot))
	draw_colored_polygon(pts, Color(0.0, 0.0, 0.0, fade))
