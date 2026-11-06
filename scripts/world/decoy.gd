extends Node2D
class_name Decoy

## Ложная цель в открытом космосе.
##
## Отдельный объект, запускаемый пусковой установкой с корабля. Появляется в
## точке запуска, улетает в заданном направлении с заданной скоростью,
## транслирует сигнал через SignalBroadcaster и удаляет себя по истечении
## времени жизни.
##
## Не знает о корабле, об ИИ угроз и об интерфейсе. Отвечает только за своё
## движение, время жизни и свой сигнал. Совместим с будущим ИИ через существующий
## сигнальный广播: угроза может опросить SignalBroadcaster.signals_near(точка)
## и решить, реагировать ли на приманку вместо корабля. Сигнал не гарантирует
## перехвата.

## Скорость перемещения в пикселях в секунду.
@export_range(0.0, 2000.0, 1.0, "suffix:px/s") var speed: float = 150.0
## Время существования в секундах.
@export_range(1.0, 300.0, 1.0, "suffix:sec") var lifetime: float = 20.0
## Сила сигнала (громкость).
@export_range(0.0, 8.0, 0.1) var signal_intensity: float = 1.0
## Радиус сигнала в пикселях.
@export_range(0.0, 4096.0, 10.0, "suffix:px") var signal_radius: float = 800.0
## Вид сигнала, чтобы получатель мог отличить приманку от другого излучения.
@export var signal_kind: String = "decoy"

## Излучаемый текстурный спрайт (опционально, для отладки и визуального контроля).
@export var texture: Texture2D

## Опубликован в конце жизни.
signal finished()

var _velocity: Vector2 = Vector2.ZERO
var _ends_at: float = 0.0
var _source_id: String = ""
var _started: bool = false

func _ready() -> void:
	if texture != null:
		var sprite := Sprite2D.new()
		sprite.texture = texture
		sprite.name = "DecoySprite"
		add_child(sprite)

## Запустить приманку. Вызывается пусковым устройством сразу после создания.
## direction - вектор направления movement (не обязательно нормализованный).
func start(direction: Vector2) -> void:
	if _started:
		return
	_started = true
	_velocity = direction.normalized() * speed
	var now := ShipSystemEvent.now()
	_ends_at = now + maxf(lifetime, 0.1)
	_source_id = "decoy:%d" % get_instance_id()

	var msg := SignalMessage.new(_source_id, global_position, signal_intensity,
			signal_radius, signal_kind, now, lifetime)
	var broadcaster := _broadcaster()
	if broadcaster != null:
		broadcaster.broadcast(msg)

	set_physics_process(true)

func _physics_process(_delta: float) -> void:
	if not _started:
		set_physics_process(false)
		return

	global_position += _velocity * _delta

	if ShipSystemEvent.now() >= _ends_at:
		_finish()

## Закончить жизнь приманки: убрать сигнал из эфира, удалить узел.
func _finish() -> void:
	if not _started:
		return
	_started = false
	set_physics_process(false)

	var broadcaster := _broadcaster()
	if broadcaster != null and not _source_id.is_empty():
		broadcaster.retract(_source_id)
	_source_id = ""

	finished.emit()
	queue_free()

## Осталось времени жизни, секунд. 0, если ещё не запущен или уже уничтожен.
func time_remaining() -> float:
	if not _started:
		return 0.0
	return maxf(_ends_at - ShipSystemEvent.now(), 0.0)

## Текущий вектор скорости.
func velocity() -> Vector2:
	return _velocity

## Идентификатор источника сигнала (для SignalBroadcaster).
func source_id() -> String:
	return _source_id

func _broadcaster() -> Object:
	var node := get_tree().get_root().get_node_or_null("SignalBroadcaster")
	if node != null:
		return node
	return null