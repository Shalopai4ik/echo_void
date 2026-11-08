extends ShipComponent
class_name ShipDecoyLauncher

## Пусковая установка ложных целей: бортовой прибор, который выпускает отдельный
## объект-приманку в космос. Монтируется под Ship/Systems как любое другое
## оборудование. Платтит энергией за каждый запуск, перезаряжается между пусками,
## ограничивает количество одновременно Existing приманок.
##
## Интеграция в существующую архитектуру: ShipComponent + ShipSystems bus +
## SignalBroadcaster. Нет автозагрузок, нет прямых ссылок между приборами, нет
## правки ShipController и без интерфейса управления.
##
## Характеристики приманки (скорость, время жизни, сила сигнала) экспонируются и
## готовы к улучшению через ресурс или инспектор.

## Энергия, списываемая за один запуск.
@export_range(0.0, 500.0, 1.0, "suffix:units") var activation_cost: float = 30.0
## Задержка между пусками, секунд.
@export_range(0.0, 120.0, 0.5, "suffix:sec") var cooldown_sec: float = 15.0
## Скорость приманки, пикселей в секунду.
@export_range(0.0, 1000.0, 5.0, "suffix:px/s") var decoy_speed: float = 150.0
## Время жизни приманки, секунд.
@export_range(1.0, 300.0, 1.0, "suffix:sec") var decoy_lifetime: float = 20.0
## Сила сигнала приманки.
@export_range(0.0, 8.0, 0.1) var signal_intensity: float = 1.2
## Радиус сигнала приманки, пикселей.
@export_range(0.0, 4096.0, 10.0, "suffix:px") var signal_radius: float = 900.0
## Максимум приманок одновременно в полёте.
@export_range(1, 20, 1) var max_concurrent_decoys: int = 3
## Ёмкость магазина приманок. Отрицательное значение - без ограничения (так
## прибор вели себя до введения зарядов, и так его проверяют старые сьюты).
## Хранится как float, потому что улучшение пишет его через `set()`.
@export_range(-1.0, 20.0, 1.0) var max_charges: float = -1.0:
	set(value):
		var grown := value > max_charges and max_charges >= 0.0
		max_charges = value
		if grown:
			add_charges(1)
## Сколько приманок в магазине сейчас.
@export_range(0, 20, 1) var charges: int = 0

## Изменилось число зарядов.
signal charges_changed(charges: int, max_charges: int)
## Сцена приманки. Если пуста, создаётся Decoy.new() прямо в коде.
@export var decoy_scene: PackedScene

## Приманка запущена: её id, направление, скорость, время жизни.
signal decoy_launched(source_id: String, direction: Vector2, speed: float, lifetime: float)
## Приманка завершила жизнь.
signal decoy_finished(source_id: String)
## Запуск отклонён: cooldown / energy / blocked / limit / no_scene / spawn_failed.
signal decoy_refused(reason: String)
## Осталось до конца перезарядки changed.
signal decoy_cooldown_changed(remaining: float)

var _active_decoys: Array = []
var _cooldown_until: float = 0.0

func _ready() -> void:
	super._ready()
	if has_charge_limit() and charges <= 0:
		charges = int(max_charges)


## Ограничен ли магазин.
func has_charge_limit() -> bool:
	return max_charges >= 0.0


## Положить заряды в магазин (награда за исследование). Возвращает сколько
## легло на самом деле.
func add_charges(amount: int) -> int:
	if not has_charge_limit() or amount <= 0:
		return 0
	var before := charges
	charges = mini(charges + amount, int(max_charges))
	if charges != before:
		charges_changed.emit(charges, int(max_charges))
	return charges - before

## Пуск приманки. direction - вектор направления (по умолчанию нос корабля, +X).
## Возвращает true, если приманка запущена, и false с decoy_refused при отказе.
func launch(direction: Vector2 = Vector2(1, 0)) -> bool:
	var now := ShipSystemEvent.now()

	if now < _cooldown_until:
		_refuse("cooldown")
		return false

	if has_charge_limit() and charges <= 0:
		_refuse("no_charges")
		return false

	var hub_node := _systems()
	if hub_node == null:
		_refuse("blocked")
		return false
	var hub := hub_node as ShipSystems
	if hub == null:
		_refuse("blocked")
		return false

	var blocked := hub.activation_block_reason(component_id)
	if not blocked.is_empty():
		_refuse(blocked)
		return false

	if not hub.can_activate(component_id, activation_cost):
		_refuse("energy")
		return false

	if not hub.spend_energy(component_id, activation_cost):
		_refuse("energy")
		return false

	var active := active_decoy_count()
	if active >= max_concurrent_decoys:
		_refuse("limit")
		hub.add_energy(activation_cost)
		return false

	var decoy: Decoy
	if decoy_scene != null:
		decoy = decoy_scene.instantiate() as Decoy
	if decoy == null:
		decoy = Decoy.new()

	var where := _launcher_position()
	decoy.global_position = where

	var dir := direction
	if dir == Vector2.ZERO:
		dir = Vector2(1, 0).rotated(_launcher_rotation())

	decoy.speed = decoy_speed
	decoy.lifetime = decoy_lifetime
	decoy.signal_intensity = signal_intensity
	decoy.signal_radius = signal_radius
	decoy.signal_kind = "decoy:%s" % resolved_id()
	decoy.texture = null

	decoy.finished.connect(_on_decoy_finished.bind(decoy))
	var host: Node = get_tree().current_scene
	if host == null:
		host = get_tree().get_root()
	host.add_child(decoy)
	decoy.start(dir)

	_active_decoys.append(decoy)
	if has_charge_limit():
		charges = maxi(charges - 1, 0)
		charges_changed.emit(charges, int(max_charges))
	_cooldown_until = now + maxf(cooldown_sec, 0.0)
	decoy_cooldown_changed.emit(cooldown_remaining())

	decoy_launched.emit(decoy.source_id(), dir, decoy_speed, decoy_lifetime)
	publish("decoy_launched", {
		"source_id": decoy.source_id(),
		"direction": dir,
		"speed": decoy_speed,
		"lifetime": decoy_lifetime,
		"at": now,
	})

	return true

## Можно ли запустить прямо сейчас (без попыток потратить энергию).
func can_launch_now() -> bool:
	var now := ShipSystemEvent.now()
	if now < _cooldown_until:
		return false
	if has_charge_limit() and charges <= 0:
		return false
	var hub_node := _systems()
	if hub_node == null:
		return false
	var hub := hub_node as ShipSystems
	if hub == null:
		return false
	var blocked := hub.activation_block_reason(component_id)
	if not blocked.is_empty():
		return false
	return hub.can_activate(component_id, activation_cost)

## Осталось до конца перезарядки, секунд.
func cooldown_remaining() -> float:
	var now := ShipSystemEvent.now()
	if now >= _cooldown_until:
		return 0.0
	return _cooldown_until - now

## Количество приманок в полёте прямо сейчас. Очищает мёртвые ссылки.
func active_decoy_count() -> int:
	var count := 0
	var alive: Array = []
	for decoy in _active_decoys:
		if decoy != null and is_instance_valid(decoy):
			count += 1
			alive.append(decoy)
	_active_decoys = alive
	return count

func _on_decoy_finished(decoy: Object) -> void:
	var idx := _active_decoys.find(decoy)
	if idx >= 0:
		_active_decoys.remove_at(idx)
	decoy.finished.disconnect(_on_decoy_finished.bind(decoy))

	var sid := ""
	if decoy is Decoy:
		sid = decoy.source_id()
	decoy_finished.emit(sid)
	publish("decoy_finished", {
		"source_id": sid,
		"at": ShipSystemEvent.now(),
	})

func _refuse(reason: String) -> void:
	decoy_refused.emit(reason)
	publish("decoy_refused", {
		"source_id": component_id,
		"reason": reason,
		"at": ShipSystemEvent.now(),
	})

func _systems() -> Node:
	if systems != null and is_instance_valid(systems):
		return systems
	var node := get_parent()
	while node != null:
		if node.has_method("spend_energy") and node.has_method("publish"):
			return node
		node = node.get_parent()
	return null

## Позиция пусковой установки в мире: ближайший Node2D вверх по дереву (корпус корабля).
func _launcher_position() -> Vector2:
	var node := get_parent()
	while node != null:
		if node is Node2D:
			return (node as Node2D).global_position
		node = node.get_parent()
	return Vector2.ZERO

## Поворот корпуса (для направления по умолчанию "вперёд от носа").
func _launcher_rotation() -> float:
	var node := get_parent()
	while node != null:
		if node is Node2D:
			return (node as Node2D).rotation
		node = node.get_parent()
	return 0.0

func status() -> Dictionary:
	var out := super()
	out["active_decoys"] = active_decoy_count()
	out["cooldown_remaining"] = cooldown_remaining()
	out["can_launch"] = can_launch_now()
	out["activation_cost"] = activation_cost
	out["decoy_speed"] = decoy_speed
	out["decoy_lifetime"] = decoy_lifetime
	out["signal_intensity"] = signal_intensity
	out["signal_radius"] = signal_radius
	out["charges"] = charges if has_charge_limit() else -1
	out["max_charges"] = int(max_charges)
	if has_charge_limit() and charges <= 0:
		out["can_launch"] = false
	return out
