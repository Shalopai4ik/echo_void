class_name ResearchDemoData
extends RefCounted

## Local, temporary object snapshots for the visual-only research screen.
##
## The data covers every presentation state of the research interface plus
## stress cases: long names, long descriptions, rare finds, unknown signals,
## dangerous objects and very large progress/XP values.


static func objects_for_state(state: int) -> Array[ResearchObject]:
	var objects := base_objects()
	for object in objects:
		if object.state == state:
			return objects
	if not objects.is_empty():
		_apply_state(objects[0], state)
	return objects


static func base_objects() -> Array[ResearchObject]:
	var result: Array[ResearchObject] = []
	for row in _rows():
		result.append(ResearchObject.from_dictionary(row))
	return result


static func stress_objects(count: int = 24) -> Array[ResearchObject]:
	var result: Array[ResearchObject] = []
	for index in count:
		var state := index % 6
		result.append(ResearchObject.from_dictionary({
			"id": "STRESS-%03d" % index,
			"title": "ТЕСТОВЫЙ ОБЪЕКТ %02d / ОЧЕНЬ ДЛИННОЕ ТЕХНИЧЕСКОЕ ОБОЗНАЧЕНИЕ КОСМИЧЕСКОГО КЛАССА" % index,
			"type": "НЕИЗВЕСТНЫЙ СИГНАЛ" if index % 3 == 0 else "АНОМАЛИЯ",
			"category": "СТРЕСС-ТЕСТ / ОЧЕНЬ ДЛИННАЯ КАТЕГОРИЯ",
			"description": "Демонстрационная запись для проверки переполнения, обрезки, прокрутки и читаемости очень длинных описаний космических объектов в интерфейсе исследования.",
			"state": _state_name(state),
			"progress": 1.0 if state >= 4 else float(index % 100) / 100.0,
			"time_remaining": 3661.0,
			"time_total": 7200.0,
			"xp_awarded": 1250000 if state >= 4 else 0,
			"xp_total": 1250000,
			"knowledge_level": index % 6,
			"knowledge_max": 5,
			"is_rare": index % 5 == 0,
			"is_dangerous": index % 7 == 0,
			"is_unknown": index % 3 == 0,
			"is_new": index % 2 == 0,
			"visual_kind": "unknown" if index % 3 == 0 else "anomaly",
			"discovered_properties": [
				"Спектральная частота: 0.73 ГГц",
				"Гравитационное смещение: 4.2e-6",
				"Период пульсации: 88.4 с",
			] if state >= 4 else [],
			"notification": "АНАЛИЗ ЗАВЕРШЁН · ПРОТОКОЛ АРХИВА ОБНОВЛЁН" if state == 4 else "",
		}))
	return result



static func _rows() -> Array[Dictionary]:
	return [
		{
			"id": "SIG-4417",
			"title": "НЕИЗВЕСТНЫЙ СИГНАЛ / ИСТОЧНИК ЗА ПРЕДЕЛАМИ КЛАССИФИКАЦИИ",
			"type": "НЕИЗВЕСТНЫЙ СИГНАЛ",
			"category": "СИГНАЛЫ / НЕ КЛАССИФИЦИРОВАН",
			"description": "Периодический импульс без опознанного спектра. Направление сигнала стабильно, но носитель не определён: ни масса, ни искусственная структура не подтверждены. Объект требует длительного анализа в безопасной дистанции.",
			"state": "unstudied",
			"progress": 0.0,
			"knowledge_level": 0,
			"is_unknown": true,
			"visual_kind": "unknown",
		},
		{
			"id": "AST-044",
			"title": "АСТЕРОИД КЛАССА C / ТЯЖЁЛЫЙ НИЗКООРБИТАЛЬНЫЙ",
			"type": "АСТЕРОИД",
			"category": "АСТЕРОИДЫ / КЛАСС C",
			"description": "Каменная масса с устойчивой металлической сигнатурой. Визуальных признаков искусственной структуры не зафиксировано. Состав поверхности: никел, железо, силикаты.",
			"state": "available",
			"progress": 0.0,
			"time_total": 20.0,
			"knowledge_level": 0,
			"is_new": true,
			"visual_kind": "asteroid",
		},
		{
			"id": "DR-109",
			"title": "ОБЛОМКИ КОРАБЛЯ / КОРПУСНОЙ МОДУЛЬ 17-B",
			"type": "ОБЛОМКИ",
			"category": "ОБЛОМКИ / ГРУЗОВОЕ СУДНО",
			"description": "Фрагмент корпуса с повреждённым силовым контуром. Возможна связь с исчезнувшим грузовым судном: найдены следы наддува и маркировка закрытого трюма.",
			"state": "in_progress",
			"progress": 0.63,
			"time_remaining": 37.0,
			"time_total": 100.0,
			"knowledge_level": 1,
			"visual_kind": "debris",
		},
		{
			"id": "BCN-7A",
			"title": "МАЯКОВЫЙ КОРАБЛЬ / НАВИГАЦИОННЫЙ ПЕРЕДАТЧИК",
			"type": "МАЯК",
			"category": "МАЯКИ / НАВИГАЦИЯ",
			"description": "Активный навигационный передатчик. Сигнал синхронизирован с межзвёздной сетью и продолжает транслировать маяк даже после потери экипажа.",
			"state": "paused",
			"progress": 0.34,
			"time_remaining": 112.0,
			"time_total": 170.0,
			"knowledge_level": 1,
			"visual_kind": "beacon",
		},
		{
			"id": "ANO-003",
			"title": "РЕЗОНАНСНАЯ АНОМАЛИЯ / ЯДРО БЕЗ МАССЫ",
			"type": "АНОМАЛИЯ",
			"category": "АНОМАЛИИ / РЕЗОНАНС",
			"description": "Локальное искажение пространства не соответствует наблюдаемому веществу. Возможен искусственный источник. Анализ подтвердил периодическую структуру поля, не совпадающую ни с одним известным классом объектов.",
			"state": "completed",
			"progress": 1.0,
			"time_remaining": 0.0,
			"time_total": 120.0,
			"xp_awarded": 300,
			"xp_total": 1250,
			"knowledge_level": 3,
			"is_rare": true,
			"visual_kind": "anomaly",
			"discovered_properties": [
				"Спектральная частота: 0.73 ГГц",
				"Гравитационное смещение: 4.2e-6",
				"Период пульсации: 88.4 с",
			],
			"notification": "АНАЛИЗ ЗАВЕРШЁН · РЕЗОНАНСНЫЙ ИСТОЧНИК ПОДТВЕРЖДЁН",
		},
		{
			"id": "HAZ-77",
			"title": "ЭКОЛОГИЧЕСКАЯ ОПАСНОСТЬ / ЗАРЯЖЕННЫЙ ФРАГМЕНТ",
			"type": "ОПАСНОСТЬ",
			"category": "ОПАСНОСТИ / ЭНЕРГИЯ",
			"description": "Фрагмент с остаточным зарядом. Эмиссия нестабильна, но подтверждённое исследование позволило построить безопасный протокол обследования.",
			"state": "fully_studied",
			"progress": 1.0,
			"time_remaining": 0.0,
			"time_total": 40.0,
			"xp_awarded": 80,
			"xp_total": 1250,
			"knowledge_level": 5,
			"is_dangerous": true,
			"visual_kind": "hazard",
			"discovered_properties": [
				"Остаточный заряд: 18.4 кДж",
				"Период распада: 62.0 с",
				"Рекомендуемая дистанция: 240 м",
			],
		},
	]


static func _apply_state(object: ResearchObject, state: int) -> void:
	object.state = state
	match state:
		ResearchObject.State.IN_PROGRESS:
			object.progress = 0.63
			object.time_remaining = 37.0
		ResearchObject.State.PAUSED:
			object.progress = 0.34
			object.time_remaining = 112.0
		ResearchObject.State.COMPLETED, ResearchObject.State.FULLY_STUDIED:
			object.progress = 1.0
			object.time_remaining = 0.0
		_:
			object.progress = 0.0
			object.time_remaining = 0.0


static func _state_name(state: int) -> String:
	match state:
		ResearchObject.State.AVAILABLE:
			return "available"
		ResearchObject.State.IN_PROGRESS:
			return "in_progress"
		ResearchObject.State.PAUSED:
			return "paused"
		ResearchObject.State.COMPLETED:
			return "completed"
		ResearchObject.State.FULLY_STUDIED:
			return "fully_studied"
	return "unstudied"
