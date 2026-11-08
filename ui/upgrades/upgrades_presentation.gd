class_name UpgradesPresentation
extends RefCounted

## The one display table for the equipment upgrades panel.
##
## Prices, levels and multipliers are *not* here: the catalogue in
## `assets/research/research_upgrade_profile.tres` owns every gameplay number.
## This table only says how a device and its paths read on screen - a title, a
## one-line description, the characteristic caption, the unit and how many
## decimals the value shows.
##
## `read` names an optional getter on the device that returns the characteristic
## *as the pilot experiences it* - the scanner's `range_now()` already folds in
## its profile and damage - so the panel shows what the ship can really do. When
## it is empty the panel reads the upgrade's own `attribute` property.
##
## A device that is not mounted does not appear in the panel: the live snapshot
## is built from the ship's components, so an upgrade can never be bought for a
## device the hull does not carry.

const DEVICES := [
	{
		"id": "scanner",
		"title": "СКАНЕР ОБЗОРА",
		"role": "SURVEY SCANNER / SENSOR ARRAY",
		"glyph": "◎",
		"description": "Основной сенсор корабля: обход диска пространства, классификация возвратов и отметка контактов. Улучшения ускоряют обход и повышают чувствительность к слабым сигнатурам.",
		"paths": [
			{
				"id": "scanner.range",
				"title": "ДАЛЬНОСТЬ ОБЗОРА",
				"description": "Расширяет радиус обхода. Контакты на границе диска приходят позже и слабее, поэтому дальность важнее скорости.",
				"caption": "РАДИУС ОБХОДА",
				"unit": "px",
				"decimals": 0,
				"read": "range_now",
			},
			{
				"id": "scanner.scan_time",
				"title": "ВРЕМЯ ОБХОДА",
				"description": "Сокращает время одного обхода. Обход остаётся наблюдаемым процессом: контакты приходят по одному.",
				"caption": "ВРЕМЯ ОБХОДА",
				"unit": "с",
				"decimals": 1,
				"read": "sweep_seconds_now",
			},
			{
				"id": "scanner.sensitivity",
				"title": "ЧУВСТВИТЕЛЬНОСТЬ",
				"description": "Повышает шанс опознать слабый или аномальный возврат. Без улучшения часть сигнатур остаётся неразличимой.",
				"caption": "ЧУВСТВИТЕЛЬНОСТЬ",
				"unit": "×",
				"decimals": 2,
			},
			{
				"id": "scanner.threat_sense",
				"title": "МОДУЛЬ УГРОЗ",
				"description": "Одноразовый модуль. Показывает на радаре пеленг крупной массы, когда она рядом.",
				"caption": "МОДУЛЬ",
				"unit": "",
				"decimals": 0,
			},
			{
				"id": "scanner.silent",
				"title": "ТИХИЙ ОБХОД",
				"description": "Одноразовый модуль. Обход сканера становится вдвое тише для того, что слушает пустоту.",
				"caption": "ШУМ ОБХОДА",
				"unit": "×",
				"decimals": 2,
			},
		],
	},
	{
		"id": "signal_light",
		"title": "СИГНАЛЬНЫЕ ОГНИ",
		"role": "SIGNAL BEACON / ONE-SHOT",
		"glyph": "✦",
		"description": "Одноразовый маяк, который пилот выбрасывает в космос. Горит заданное время и передаёт сигнал всему, что способно его услышать.",
		"paths": [
			{
				"id": "signal_light.radius",
				"title": "РАДИУС СИГНАЛА",
				"description": "Увеличивает радиус, в котором маяк слышен. Дальность распространения сигнала в пустоте.",
				"caption": "РАДИУС",
				"unit": "px",
				"decimals": 0,
			},
			{
				"id": "signal_light.duration",
				"title": "ДЛИТЕЛЬНОСТЬ ГОРЕНИЯ",
				"description": "Продлевает время работы маяка. Дольше горит - дольше его можно услышать.",
				"caption": "ДЛИТЕЛЬНОСТЬ",
				"unit": "с",
				"decimals": 0,
			},
			{
				"id": "signal_light.intensity",
				"title": "ИНТЕНСИВНОСТЬ",
				"description": "Усиливает сигнал маяка. Интенсивность определяет, насколько уверенно приёмник отличает его от фона.",
				"caption": "ИНТЕНСИВНОСТЬ",
				"unit": "×",
				"decimals": 2,
			},
			{
				"id": "signal_light.capacity",
				"title": "СТОЙКА ОГНЕЙ",
				"description": "Ещё одно место на стойке. Огни пополняются из сигнальных буёв и тайников.",
				"caption": "ЁМКОСТЬ",
				"unit": "шт",
				"decimals": 0,
			},
		],
	},
	{
		"id": "decoy_launcher",
		"title": "ЛОЖНЫЕ ЦЕЛИ",
		"role": "DECOY LAUNCHER / COUNTER",
		"glyph": "◇",
		"description": "Пусковая установка приманок. Выпускает объект с собственной сигнатурой, который уводит чужое внимание от корпуса.",
		"paths": [
			{
				"id": "decoy.lifetime",
				"title": "ВРЕМЯ ЖИЗНИ",
				"description": "Сколько приманка остаётся в полёте. Дольше живёт - дольше отвлекает.",
				"caption": "ВРЕМЯ ЖИЗНИ",
				"unit": "с",
				"decimals": 0,
			},
			{
				"id": "decoy.signal",
				"title": "СИЛА СИГНАЛА",
				"description": "Насколько громко приманка звучит для слушателя. Слабая приманка не отличима от обломка.",
				"caption": "СИГНАЛ",
				"unit": "×",
				"decimals": 2,
			},
			{
				"id": "decoy.speed",
				"title": "СКОРОСТЬ ВЫХОДА",
				"description": "Скорость, с которой приманка уходит от корпуса. Быстрый выход разводит приманку и корабль.",
				"caption": "СКОРОСТЬ",
				"unit": "px/s",
				"decimals": 0,
			},
			{
				"id": "decoy.capacity",
				"title": "МАГАЗИН",
				"description": "Ещё одно место в пусковом магазине. Ложные цели пополняются из обломков кораблей.",
				"caption": "ЁМКОСТЬ",
				"unit": "шт",
				"decimals": 0,
			},
		],
	},
	{
		"id": "research",
		"title": "ИССЛЕДОВАТЕЛЬСКИЙ СТОЛ",
		"role": "RESEARCH DESK / ANALYSIS",
		"glyph": "⌖",
		"description": "Анализ найденных объектов. Каждый изученный объект даёт Research XP и часто - материалы для корабля.",
		"paths": [
			{
				"id": "research.speed",
				"title": "СКОРОСТЬ АНАЛИЗА",
				"description": "Сокращает время любого анализа. Меньше времени у объекта - меньше шума.",
				"caption": "МНОЖИТЕЛЬ ВРЕМЕНИ",
				"unit": "×",
				"decimals": 2,
			},
			{
				"id": "research.range",
				"title": "ДАЛЬНОСТЬ СВЯЗИ",
				"description": "Анализ продолжается на большем расстоянии от объекта.",
				"caption": "ДАЛЬНОСТЬ",
				"unit": "px",
				"decimals": 0,
			},
		],
	},
]


## Every device the table describes, in panel order.
static func device_ids() -> Array[String]:
	var ids: Array[String] = []
	for device in DEVICES:
		ids.append(str(device.get("id", "")))
	return ids


## The display entry for `device_id`, or an empty dictionary when unknown.
static func device(device_id: String) -> Dictionary:
	for device in DEVICES:
		if str(device.get("id", "")) == device_id:
			return device
	return {}


## The display entry for upgrade path `upgrade_id`, or an empty dictionary.
static func path(upgrade_id: String) -> Dictionary:
	for device in DEVICES:
		for path in device.get("paths", []):
			if str(path.get("id", "")) == upgrade_id:
				return path
	return {}