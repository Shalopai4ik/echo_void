extends Node
class_name ShipNotifier

## Turns what the ship's own systems say into the pilot's system messages.
##
## Every message here is a reaction to a real signal from a real device -
## nothing is polled or guessed: the reserve's low/empty/restored latches, the
## hull pool, a device changing state, a sweep finishing, a research object
## found, an upgrade bought or refused, a decoy or flare refused. Sounds for
## the same moments are asked for through `GameFeed.sfx()`.

const REASONS := {
	"cooldown": "перезарядка",
	"energy": "недостаточно энергии",
	"no_charges": "нет зарядов",
	"limit": "предел одновременных пусков",
	"blocked": "заблокировано",
	"offline": "прибор выключен",
	"unpowered": "нет питания",
	"busy": "уже работает",
	"insufficient_xp": "недостаточно Research XP",
	"max_level": "максимальный уровень",
	"device_not_found": "прибор не установлен",
}

var _systems: Node
var _last_hull_note: float = -100.0


func _ready() -> void:
	call_deferred("_bind")


func _bind() -> void:
	var ship := GameNodes.ship(get_tree())
	if ship == null:
		return
	_systems = ship.get_node_or_null("Systems")
	if _systems == null:
		return
	_systems.connect("energy_low", func(_r: float) -> void:
		_note(GameFeed.WARNING, "ЭНЕРГИЯ", "Резерв ниже четверти. Приборы потребляют больше, чем даёт реактор.", "warning"))
	_systems.connect("energy_depleted", func() -> void:
		_note(GameFeed.PROBLEM, "ЭНЕРГИЯ", "Резерв исчерпан. Шина обесточена до восстановления.", "alarm"))
	_systems.connect("energy_restored", func() -> void:
		_note(GameFeed.INFO, "ЭНЕРГИЯ", "Шина снова под напряжением.", "power_on"))
	_systems.connect("hull_damaged", _on_hull_damaged)
	_systems.connect("hull_critical", func(_r: float) -> void:
		_note(GameFeed.PROBLEM, "КОРПУС", "Критическое состояние. Изучайте обломки - они дают материал для ремонта.", "alarm"))
	_systems.connect("system_state_changed", _on_state_changed)
	_systems.connect("activation_refused", func(id: String, _cost: float, _available: float) -> void:
		_note(GameFeed.WARNING, _title_of(id), "Отказ: недостаточно энергии.", "refuse"))
	var scanner := _systems.get_node_or_null("Scanner")
	if scanner != null:
		scanner.connect("scan_completed", _on_scan_completed)
		scanner.connect("scan_refused", func(reason: String) -> void:
			_note(GameFeed.WARNING, "СКАНЕР", "Обход невозможен: %s." % _reason(reason), "refuse"))
		scanner.connect("scan_started", func(_r: float, _s: float) -> void:
			GameFeed.sfx(get_tree(), "scan"))
	var desk := _systems.get_node_or_null("Research")
	if desk != null:
		desk.connect("research_started", func(_s: String, _t: String, time: float) -> void:
			_note(GameFeed.INFO, "ИССЛЕДОВАНИЕ", "Анализ начат: %d с. Держитесь рядом с объектом." % roundi(time), "ui_confirm"))
		desk.connect("research_cancelled", func(_s: String, reason: String) -> void:
			if reason != "paused":
				_note(GameFeed.WARNING, "ИССЛЕДОВАНИЕ", "Анализ прерван: %s. Прогресс сохранён." % _reason(reason), "refuse"))
		desk.connect("xp_gained", func(amount: int, total: int) -> void:
			_note(GameFeed.INFO, "RESEARCH XP", "+%d XP. Всего: %d." % [amount, total], ""))
	var launcher := _systems.get_node_or_null("DecoyLauncher")
	if launcher != null:
		launcher.connect("decoy_refused", func(reason: String) -> void:
			_note(GameFeed.WARNING, "ЛОЖНЫЕ ЦЕЛИ", "Пуск невозможен: %s." % _reason(reason), "refuse"))
		launcher.connect("decoy_launched", func(_id: String, _d: Vector2, _s: float, _l: float) -> void:
			GameFeed.sfx(get_tree(), "decoy_launch"))
		launcher.connect("charges_changed", func(c: int, m: int) -> void:
			if c == 0:
				_note(GameFeed.WARNING, "ЛОЖНЫЕ ЦЕЛИ", "Магазин пуст (0/%d). Пополняется из обломков кораблей." % m, ""))
	var light := _systems.get_node_or_null("SignalLight")
	if light != null:
		light.connect("signal_refused", func(reason: String) -> void:
			_note(GameFeed.WARNING, "СИГНАЛЬНЫЕ ОГНИ", "Пуск невозможен: %s." % _reason(reason), "refuse"))
		light.connect("signal_activated", func(_d: float, _i: float, _r: float) -> void:
			GameFeed.sfx(get_tree(), "flare"))
	var upgrades := _systems.get_node_or_null("UpgradeDesk")
	if upgrades != null:
		upgrades.connect("upgrade_purchased", func(id: String, level: int, spent: int, left: int) -> void:
			_note(GameFeed.INFO, "УЛУЧШЕНИЕ", "%s: уровень %d. Потрачено %d XP, осталось %d." % [_upgrade_name(upgrades, id, level), level, spent, left], "upgrade"))
		upgrades.connect("upgrade_refused", func(_id: String, reason: String) -> void:
			_note(GameFeed.WARNING, "УЛУЧШЕНИЕ", "Отказ: %s." % _reason(reason), "refuse"))
	var field := get_tree().get_first_node_in_group(POIField.GROUP) as POIField
	if field != null:
		field.poi_discovered.connect(func(poi: ResearchPOI) -> void:
			_note(GameFeed.INFO, "ОБНАРУЖЕН ОБЪЕКТ", "%s. %s" % [poi.title, poi.description], "discover"))


func _note(kind: int, title: String, message: String, sound: String) -> void:
	GameFeed.notify(get_tree(), kind, title, message)
	if not sound.is_empty():
		GameFeed.sfx(get_tree(), sound)


func _on_hull_damaged(amount: float, integrity: float, maximum: float, source: String) -> void:
	var now := ShipSystemEvent.now()
	if now - _last_hull_note < 2.0:
		return
	_last_hull_note = now
	var cause := "столкновение" if source.is_empty() or source == "impact" else ("луч биосигнатуры" if source == "brood" else source)
	_note(GameFeed.WARNING, "КОРПУС", "Повреждение -%d%% (%s). Целостность %d%%." % [
		roundi(amount / maxf(maximum, 0.001) * 100.0), cause, roundi(integrity / maxf(maximum, 0.001) * 100.0)], "hull_hit")


func _on_state_changed(id: String, _previous: int, current: int) -> void:
	if id.is_empty():
		return
	var comp: Variant = _systems.call("component", id)
	if comp == null or not bool(comp.get("enabled")):
		return
	var text := ""
	match current:
		ShipSystemState.Value.DAMAGED:
			text = "Повреждён: эффективность снижена."
		ShipSystemState.Value.OFFLINE:
			text = "Отказ: прибор не работает."
	if text.is_empty():
		return
	_note(GameFeed.WARNING, _title_of(id), text, "warning")


func _on_scan_completed(contacts: Array) -> void:
	var objects := 0
	var unknown := 0
	for c in contacts:
		if str(c.get("id", "")).begins_with("poi:"):
			objects += 1
		elif str(c.get("signature", "")) == "poi_leviathan":
			unknown += 1
	var text := "Контактов: %d. Объектов исследования: %d." % [contacts.size(), objects]
	if unknown > 0:
		text += " Есть контакт без классификации."
	_note(GameFeed.INFO if unknown == 0 else GameFeed.WARNING, "ОБХОД ЗАВЕРШЁН", text, "scan_done")


func _title_of(id: String) -> String:
	match id:
		"scanner": return "СКАНЕР"
		"research": return "ИССЛЕДОВАТЕЛЬСКИЙ СТОЛ"
		"decoy_launcher": return "ЛОЖНЫЕ ЦЕЛИ"
		"signal_light": return "СИГНАЛЬНЫЕ ОГНИ"
	return id.to_upper()


func _reason(reason: String) -> String:
	return str(REASONS.get(reason, reason))


func _upgrade_name(upgrades: Node, id: String, level: int) -> String:
	var profile: Variant = upgrades.get("profile")
	if profile != null:
		var entry: Variant = profile.call("find", id, level)
		if entry != null:
			return str(entry.get("display_name"))
	return id
