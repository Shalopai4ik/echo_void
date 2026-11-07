class_name ScannerDemoData
extends RefCounted

## Local, temporary contact snapshots for the visual-only scanner screen.


static func contacts() -> Array[ScannerContact]:
	var rows := [
		{"id": "AST-044", "title": "АСТЕРОИД КЛАССА C / ТЯЖЁЛЫЙ НИЗКООРБИТАЛЬНЫЙ", "type": "АСТЕРОИД", "study": "72%", "distance": "18.4 км", "description": "Каменная масса с устойчивой металлической сигнатурой. Визуальных признаков искусственной структуры не зафиксировано.", "research_status": "ЧАСТИЧНО ИЗУЧЕН", "analysis_available": true, "marker_kind": "asteroid", "position": Vector2(-0.48, -0.32)},
		{"id": "DR-109", "title": "ОБЛОМКИ КОРАБЛЯ", "type": "ОБЛОМКИ", "study": "41%", "distance": "31.7 км", "description": "Фрагмент корпуса с повреждённым силовым контуром. Возможна связь с исчезнувшим грузовым судном.", "research_status": "НЕ ИССЛЕДОВАНО", "analysis_available": true, "marker_kind": "debris", "position": Vector2(0.44, 0.18)},
		{"id": "BCN-7A", "title": "МАЯКОВЫЙ КОРАБЛЬ", "type": "МАЯК", "study": "100%", "distance": "46.2 км", "description": "Активный навигационный передатчик. Сигнал синхронизирован с межзвёздной сетью.", "research_status": "ИЗУЧЕНО", "analysis_available": true, "marker_kind": "beacon", "position": Vector2(0.12, -0.58)},
		{"id": "SIG-???", "title": "НЕИЗВЕСТНЫЙ СИГНАЛ / ИСТОЧНИК ЗА ПРЕДЕЛАМИ КЛАССИФИКАЦИИ", "type": "НЕИЗВЕСТНЫЙ СИГНАЛ", "study": "0%", "distance": "87.5 км", "description": "Периодический импульс без опознанного спектра. Направление сигнала стабильно, носитель неизвестен.", "research_status": "ТРЕБУЕТСЯ ИССЛЕДОВАНИЕ", "analysis_available": false, "unknown": true, "marker_kind": "unknown", "position": Vector2(-0.68, 0.56)},
		{"id": "ANO-003", "title": "ГРАВИТАЦИОННАЯ АНОМАЛИЯ / ЯДРО БЕЗ МАССЫ", "type": "АНОМАЛИЯ", "study": "8%", "distance": "112.0 км", "description": "Локальное искажение пространства не соответствует наблюдаемому веществу. Возможен искусственный источник.", "research_status": "КРИТИЧЕСКАЯ АНОМАЛИЯ", "analysis_available": false, "anomaly": true, "marker_kind": "anomaly", "position": Vector2(0.72, -0.12)},
	]
	var result: Array[ScannerContact] = []
	for row in rows:
		result.append(ScannerContact.from_dictionary(row))
	return result


static func stress_contacts(count: int = 28) -> Array[ScannerContact]:
	var result: Array[ScannerContact] = []
	var kinds := ["asteroid", "debris", "beacon", "unknown", "anomaly"]
	for index in count:
		var kind: String = str(kinds[index % kinds.size()])
		var anomaly := kind == "anomaly"
		var unknown := kind == "unknown"
		result.append(ScannerContact.from_dictionary({
			"id": "T-%03d" % index,
			"title": "ТЕСТОВЫЙ КОНТАКТ %02d / ОЧЕНЬ ДЛИННОЕ ТЕХНИЧЕСКОЕ ОБОЗНАЧЕНИЕ СИГНАТУРЫ" % index,
			"type": "АНОМАЛИЯ" if anomaly else ("НЕИЗВЕСТНЫЙ СИГНАЛ" if unknown else "ОБЪЕКТ"),
			"study": "%d%%" % (index * 3 % 100),
			"distance": "%d.%d км" % [100 + index, index % 10],
			"description": "Демонстрационная запись для проверки переполнения, прокрутки и читаемости длинных строк.",
			"research_status": "НЕ ИССЛЕДОВАНО",
			"analysis_available": index % 2 == 0,
			"anomaly": anomaly,
			"unknown": unknown,
			"marker_kind": kind,
			"position": Vector2(sin(index * 1.7), cos(index * 1.3)),
		}))
	return result
