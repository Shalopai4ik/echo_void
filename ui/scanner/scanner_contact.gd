class_name ScannerContact
extends RefCounted

## Presentation-only contact snapshot used by the scanner UI.
## It deliberately mirrors no gameplay resource or system.

var id: String = ""
var title: String = ""
var type_label: String = "НЕИЗВЕСТНЫЙ СИГНАЛ"
var study: String = "0%"
var distance: String = "0.0 км"
var description: String = ""
var research_status: String = "НЕ ИССЛЕДОВАНО"
var analysis_available: bool = false
var anomaly: bool = false
var unknown: bool = false
var marker_kind: String = "unknown"
var bearing: float = 0.0
var normalized_position: Vector2 = Vector2.ZERO


static func from_dictionary(data: Dictionary) -> ScannerContact:
	var contact := ScannerContact.new()
	contact.id = str(data.get("id", "SIG-UNKNOWN"))
	contact.title = str(data.get("title", contact.id))
	contact.type_label = str(data.get("type", "НЕИЗВЕСТНЫЙ СИГНАЛ"))
	contact.study = str(data.get("study", "0%"))
	contact.distance = str(data.get("distance", "0.0 км"))
	contact.description = str(data.get("description", "Источник сигнала не идентифицирован."))
	contact.research_status = str(data.get("research_status", "НЕ ИССЛЕДОВАНО"))
	contact.analysis_available = bool(data.get("analysis_available", false))
	contact.anomaly = bool(data.get("anomaly", false))
	contact.unknown = bool(data.get("unknown", contact.type_label.to_upper().contains("НЕИЗВЕСТ")))
	contact.marker_kind = str(data.get("marker_kind", "anomaly" if contact.anomaly else ("unknown" if contact.unknown else "contact")))
	contact.bearing = float(data.get("bearing", 0.0))
	contact.normalized_position = data.get("position", Vector2.ZERO)
	return contact
