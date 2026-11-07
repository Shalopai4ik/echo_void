extends UiViewportPolicy
class_name ShipHudScreen

## Visual-only HUD screen. The exported resource is a demonstration snapshot;
## it is deliberately separate from all gameplay systems.

@export var demo_data: HudVisualData

@onready var _ship_status: ShipStatusPanel = %ShipStatus
@onready var _notifications: Control = %Notifications


func _ready() -> void:
	super._ready()
	if demo_data != null:
		_ship_status.apply_data(demo_data)
	_configure_demo_notifications()


func _configure_demo_notifications() -> void:
	var items := _notifications.get_node("Content/Items")
	var info := items.get_node("Info") as SystemNotificationItem
	var warning := items.get_node("Warning") as SystemNotificationItem
	var problem := items.get_node("Problem") as SystemNotificationItem
	info.configure(SystemNotificationItem.Kind.INFO, "ИНФОРМАЦИЯ", "Калибровка систем завершена")
	warning.configure(SystemNotificationItem.Kind.WARNING, "ПРЕДУПРЕЖДЕНИЕ", "Заряд энергии ниже резерва")
	problem.configure(SystemNotificationItem.Kind.PROBLEM, "ПРОБЛЕМА", "Обнаружена микроповреждение обшивки")
