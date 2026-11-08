extends Node2D
class_name Decoy

## Ложная цель в открытом космосе.
##
## Отдельный объект, запускаемый пусковой установкой с корабля. Появляется в
## точке запуска, улетает в заданном направлении, постепенно тормозит,
## транслирует сигнал через SignalBroadcaster и удаляет себя по истечении
## времени жизни.
##
## Сигнал летит вместе с приманкой: позиция в эфире обновляется несколько раз в
## секунду, поэтому угроза идёт за приманкой, а не в точку пуска. Угроза может
## «поглотить» приманку (`consume()`), и тогда она гаснет раньше срока.
##
## Не знает о корабле, об ИИ угроз и об интерфейсе.

## Группа мира, который останавливается вместе с открытой панелью.
const WORLD_PAUSABLE_GROUP := "world_pausable"
## Группа всех приманок в полёте, чтобы угроза находила их без реестра.
const GROUP := "decoy"
## Как часто сигнал переносится в текущую точку, секунд.
const REBROADCAST_SEC := 0.2
## Доля скорости, теряемая за секунду: приманка не улетает в бесконечность.
const DRAG_PER_SEC := 0.12

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

## Излучаемый текстурный спрайт (опционально).
@export var texture: Texture2D

## Опубликован в конце жизни.
signal finished()
## Приманку поглотила угроза.
signal consumed()

var _velocity: Vector2 = Vector2.ZERO
var _ends_at: float = 0.0
var _started_at: float = 0.0
var _source_id: String = ""
var _started: bool = false
var _rebroadcast_in: float = 0.0
var _time: float = 0.0


func _ready() -> void:
	add_to_group(WORLD_PAUSABLE_GROUP)
	add_to_group(GROUP)
	z_index = 5
	if texture != null:
		var sprite := Sprite2D.new()
		sprite.texture = texture
		sprite.name = "DecoySprite"
		add_child(sprite)


## Запустить приманку. Вызывается пусковым устройством сразу после создания.
func start(direction: Vector2) -> void:
	if _started:
		return
	_started = true
	_velocity = direction.normalized() * speed
	var now := ShipSystemEvent.now()
	_started_at = now
	_ends_at = now + maxf(lifetime, 0.1)
	_source_id = "decoy:%d" % get_instance_id()
	_broadcast_here(now)
	set_physics_process(true)
	set_process(true)


func _physics_process(delta: float) -> void:
	if not _started:
		set_physics_process(false)
		return
	global_position += _velocity * delta
	_velocity *= maxf(1.0 - DRAG_PER_SEC * delta, 0.0)
	_rebroadcast_in -= delta
	var now := ShipSystemEvent.now()
	if _rebroadcast_in <= 0.0:
		_rebroadcast_in = REBROADCAST_SEC
		_broadcast_here(now)
	if now >= _ends_at:
		_finish()


func _process(delta: float) -> void:
	_time += delta
	queue_redraw()


func _draw() -> void:
	if not _started:
		return
	var left := time_remaining()
	var fade := clampf(left / 2.0, 0.0, 1.0)
	var pulse := 0.5 + 0.5 * sin(_time * 9.0)
	var core := Color(0.55, 0.95, 1.0, 0.95 * fade)
	# the decoy wears a hull's signature: a small bright diamond and two rings
	var s := 14.0
	draw_colored_polygon(PackedVector2Array([Vector2(s, 0), Vector2(0, s * 0.6),
		Vector2(-s, 0), Vector2(0, -s * 0.6)]), core)
	draw_arc(Vector2.ZERO, 26.0 + pulse * 10.0, 0.0, TAU, 32,
		Color(0.4, 0.9, 1.0, (0.55 - pulse * 0.4) * fade), 2.0)
	var ring := fmod(_time * 0.9, 1.0)
	draw_arc(Vector2.ZERO, 40.0 + ring * 220.0, 0.0, TAU, 48,
		Color(0.3, 0.8, 1.0, (1.0 - ring) * 0.35 * fade), 2.0)


## Угроза добралась до приманки и поглотила её: сигнал гаснет сразу.
func consume() -> void:
	if not _started:
		return
	consumed.emit()
	_finish()


## Закончить жизнь приманки: убрать сигнал из эфира, удалить узел.
func _finish() -> void:
	if not _started:
		return
	_started = false
	set_physics_process(false)
	set_process(false)
	var broadcaster := _broadcaster()
	if broadcaster != null and not _source_id.is_empty():
		broadcaster.retract(_source_id)
	_source_id = ""
	finished.emit()
	queue_free()


func _broadcast_here(now: float) -> void:
	var broadcaster := _broadcaster()
	if broadcaster == null:
		return
	var msg := SignalMessage.new(_source_id, global_position, signal_intensity,
			signal_radius, signal_kind, _started_at, lifetime)
	broadcaster.broadcast(msg)


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


## Жива ли приманка.
func is_active() -> bool:
	return _started


func _broadcaster() -> Object:
	if not is_inside_tree():
		return null
	return get_tree().get_root().get_node_or_null("SignalBroadcaster")
