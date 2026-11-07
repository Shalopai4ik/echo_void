class_name ResearchObject
extends RefCounted

## Presentation-only snapshot of one researched cosmic object.
##
## It mirrors no gameplay resource and no research system state. The research
## desk of stage 5.2 is deliberately not referenced here: stage 7 will map a
## gameplay snapshot onto this visual model.

enum State {
	UNSTUDIED,      ## The object has never been observed closely.
	AVAILABLE,      ## Analysis may be ordered.
	IN_PROGRESS,    ## Analysis is running right now.
	PAUSED,         ## Analysis was interrupted and can be resumed.
	COMPLETED,     ## Analysis just finished; results are being revealed.
	FULLY_STUDIED,  ## Everything known about the object is already known.
}

const STATE_NAMES := {
	State.UNSTUDIED: "НЕ ИССЛЕДОВАН",
	State.AVAILABLE: "ИССЛЕДОВАНИЕ ДОСТУПНО",
	State.IN_PROGRESS: "АНАЛИЗ ВЫПОЛНЯЕТСЯ",
	State.PAUSED: "АНАЛИЗ ПРИОСТАНОВЛЕН",
	State.COMPLETED: "АНАЛИЗ ЗАВЕРШЁН",
	State.FULLY_STUDIED: "ПОЛНОСТЬЮ ИЗУЧЕН",
}

var id: String = ""
var title: String = ""
var type_label: String = "НЕОПОЗНАННЫЙ ОБЪЕКТ"
var category: String = "НЕ КЛАССИФИЦИРОВАН"
var description: String = ""
var state: int = State.UNSTUDIED
var progress: float = 0.0
var time_remaining: float = 0.0
var time_total: float = 0.0
var xp_awarded: int = 0
var xp_total: int = 0
var knowledge_level: int = 0
var knowledge_max: int = 5
var discovered_properties: Array[String] = []
var is_new: bool = false
var is_rare: bool = false
var is_dangerous: bool = false
var is_unknown: bool = false
var visual_kind: String = "unknown"
var notification: String = ""


static func from_dictionary(data: Dictionary) -> ResearchObject:
	var object := ResearchObject.new()
	object.id = str(data.get("id", "OBJ-000"))
	object.title = str(data.get("title", object.id))
	object.type_label = str(data.get("type", "НЕОПОЗНАННЫЙ ОБЪЕКТ"))
	object.category = str(data.get("category", "НЕ КЛАССИФИЦИРОВАН"))
	object.description = str(data.get("description", ""))
	object.state = state_from_string(str(data.get("state", "unstudied")))
	object.progress = clampf(float(data.get("progress", 0.0)), 0.0, 1.0)
	object.time_remaining = maxf(float(data.get("time_remaining", 0.0)), 0.0)
	object.time_total = maxf(float(data.get("time_total", object.time_remaining)), 0.0)
	object.xp_awarded = maxi(int(data.get("xp_awarded", 0)), 0)
	object.xp_total = maxi(int(data.get("xp_total", 0)), 0)
	object.knowledge_level = maxi(int(data.get("knowledge_level", 0)), 0)
	object.knowledge_max = maxi(int(data.get("knowledge_max", 5)), 1)
	object.is_new = bool(data.get("is_new", false))
	object.is_rare = bool(data.get("is_rare", false))
	object.is_dangerous = bool(data.get("is_dangerous", false))
	object.is_unknown = bool(data.get("is_unknown", false))
	object.visual_kind = str(data.get("visual_kind", "unknown"))
	object.notification = str(data.get("notification", ""))
	var properties: Array = data.get("discovered_properties", [])
	if properties is Array:
		for property in properties:
			object.discovered_properties.append(str(property))
	return object


static func state_from_string(text: String) -> int:
	match text.strip_edges().to_lower():
		"unstudied", "new":
			return State.UNSTUDIED
		"available":
			return State.AVAILABLE
		"in_progress", "running":
			return State.IN_PROGRESS
		"paused":
			return State.PAUSED
		"completed":
			return State.COMPLETED
		"fully_studied", "studied":
			return State.FULLY_STUDIED
	return State.UNSTUDIED


static func state_name(state_value: int) -> String:
	return str(STATE_NAMES.get(state_value, "НЕ ИССЛЕДОВАН"))


func is_finished() -> bool:
	return state == State.COMPLETED or state == State.FULLY_STUDIED


func status_text() -> String:
	return state_name(state)


func progress_percent() -> int:
	return int(round(clampf(progress, 0.0, 1.0) * 100.0))


func knowledge_text() -> String:
	return "%d/%d" % [knowledge_level, knowledge_max]


static func format_time(seconds: float) -> String:
	var total := int(maxf(seconds, 0.0))
	return "%02d:%02d" % [total / 60, total % 60]


static func format_number(value: int) -> String:
	var digits := str(absi(value))
	var grouped := ""
	var count := 0
	for index in range(digits.length() - 1, -1, -1):
		grouped = digits[index] + grouped
		count += 1
		if count % 3 == 0 and index > 0:
			grouped = " " + grouped
	return ("-" if value < 0 else "") + grouped
