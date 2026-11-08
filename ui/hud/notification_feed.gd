extends VBoxContainer
class_name NotificationFeed

## The live system messages in the corner of the glass.
##
## Anything can push a message through `GameFeed.notify()` (the group
## "notification_feed"); the feed shows at most `max_items`, newest on top,
## each for `life_sec`, and drops a repeat of the same text that arrives
## while the first one is still up. Rows are the project's own
## `SystemNotificationItem` component.

const ITEM_SCENE := preload("res://scenes/ui/components/SystemNotificationItem.tscn")
const GROUP := "notification_feed"

@export var max_items: int = 3
@export var life_sec: float = 6.5

var _items: Array = []
## Every message pushed this run, for the log and for tests.
var history: Array = []


func _ready() -> void:
	add_to_group(GROUP)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_constant_override("separation", 4)


func push(kind: int, title: String, message: String) -> void:
	history.append({"kind": kind, "title": title, "message": message})
	for entry in _items:
		if entry["title"] == title and entry["message"] == message:
			entry["left"] = life_sec
			return
	var item: SystemNotificationItem = ITEM_SCENE.instantiate()
	add_child(item)
	move_child(item, 0)
	item.custom_minimum_size = Vector2(230, 0)
	item.configure(clampi(kind, 0, 2) as SystemNotificationItem.Kind, title, message)
	var msg_label := item.get_node_or_null("%Message") as Label
	if msg_label != null:
		msg_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		msg_label.custom_minimum_size.x = 205
		msg_label.add_theme_font_size_override("font_size", 10)
		msg_label.max_lines_visible = 3
		msg_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_items.append({"node": item, "left": life_sec, "title": title, "message": message})
	while _items.size() > max_items:
		var old: Dictionary = _items.pop_front()
		(old["node"] as Node).queue_free()


func _process(delta: float) -> void:
	if not get_tree().get_nodes_in_group("ui_modal").is_empty():
		return
	for i in range(_items.size() - 1, -1, -1):
		var entry: Dictionary = _items[i]
		entry["left"] = float(entry["left"]) - delta
		var node := entry["node"] as Control
		node.modulate.a = clampf(float(entry["left"]) / 0.8, 0.0, 1.0)
		if float(entry["left"]) <= 0.0:
			node.queue_free()
			_items.remove_at(i)


func visible_count() -> int:
	return _items.size()
