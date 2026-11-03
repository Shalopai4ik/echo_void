# Готовность к Этапу 3

Документ отвечает на вопрос «что уже есть, чего нет и куда это ложится» для
Этапа 3. Текста спецификации Этапа 3 в проекте нет (в воркспейсе его не
найдено), поэтому матрица собрана из аудита кода и из фактического состояния
репозитория. Каждая строка опирается на конкретные `файл:строка`, чтобы её
можно было проверить, не перечитывая весь проект.

Правило Этапа 3: правится **только текущий срез** —
`scenes/world/SpaceMap.tscn` + `scripts/ship/ship_controller.gd` +
`scripts/world/world_field.gd`. Легаси-срез (`scenes/main.tscn`,
`scripts/ship.gd`, `scripts/asteroid_field.gd`) — только эталон поведения и
источник регрессий; новых фич в него не добавляем.

## 1. Два среза и почему это важно

| | Легаси | Текущий |
|---|---|---|
| Сцена | `scenes/main.tscn` | `scenes/world/SpaceMap.tscn` |
| Корабль | `scripts/ship.gd` (Node2D, ручная физика) | `scripts/ship/ship_controller.gd` (RigidBody2D, физика движка) |
| Поле | `scripts/asteroid_field.gd` | `scripts/world/world_field.gd` |
| HUD | был вшит в `main.tscn` | `scenes/hud/HUD.tscn` (общий, см. §2) |

Легаси-срез давно не трогаем: он держит щит/корпус, разрушение камней и
собственный HUD. Текущий срез — это то, во что превратится игра.

## 2. Что сделано в этой итерации

Один HUD на оба среза, и HUD, который честен относительно того, что у корабля
есть на самом деле.

| # | Требование | Статус | Доказательство |
|---|---|---|---|
| 1 | HUD/сканер в текущем срезе | **реализовано** | `scenes/world/SpaceMap.tscn:22` (инстанс `scenes/hud/HUD.tscn`), `scripts/hud.gd:262` (`_scan` → `_world_contacts`) |
| 2 | Один HUD вместо дублей | **реализовано** | `scenes/main.tscn:167` теперь инстанцирует `scenes/hud/HUD.tscn`; 100 строк inline-узлов из `main.tscn` удалены |
| 3 | Легаси-путь HUD не сломан | **реализовано, проверено** | `tests/hud_test.gd` — 19 PASS / 0 FAIL; `tests/combat_test.gd` — ALL PASS |
| 4 | Радар видит камни текущего мира | **реализовано** | `scripts/hud.gd:274` (`_world_contacts`: позиция, поворот, силуэт из `StageRock.piece`) |
| 5 | Стекло не врёт про броню | **реализовано** | `scripts/hud.gd:160` (`_armour` = есть `shield_ratio()`); у текущего корабля щита нет → вместо полос телеметрия `scripts/hud.gd:336` (`telemetry_lines`) |
| 6 | Стекло не ломает геометрию движка | **реализовано** | `scripts/hud.gd:301` (`_is_solid`) + `_clean_ring:315` — силуэты с вырожденными рёбрами рисуются контуром, без заливки (были ошибки `triangulation failed`) |
| 7 | Крючок для задач | **реализовано** | `scripts/hud.gd:154` (`_find_mission`): узел в группе `mission` с `objective_lines()` / `objective_title()` включает строки задач; проверено в `tests/hud_test.gd` |

## 3. Матрица требований Этапа 3


## 4. Файлы к изменению и новые файлы

Правки (текущий срез):

- `scripts/ship/ship_controller.gd` — щит/корпус/урон, точки входа оружия,
  отчёт о попадании.
- `scripts/hud.gd` — расширить телеметрию под новые системы; полосы щита и
  корпуса появятся сами, как только у корабля появятся `shield_ratio()` и
  `hull_ratio()` (контракт уже заложен).
- `scripts/world/world_field.gd` — shatter, новые популяции (debris / hazard /
  interactable), игровой потребитель `kind`.
- `scripts/world/world_objects.gd` — новые kind'ы и их описания.
- `scenes/world/SpaceMap.tscn` — узлы миссий, оружия, новых объектов мира.

Новые файлы (с обоснованием):

| Файл | Зачем |
|---|---|
| `scripts/ship/damage_system.gd` | щит/корпус/урон отдельно от пилота: правила регенерации и урона не должны жить в контроллере полёта |
| `scripts/ship/weapon_system.gd` | оружие, отдача, перезарядка, потребление энергии |
| `scripts/ship/targeting.gd` | выбор цели и удержание курса — отдельный узел, чтобы не смешивать с ИИ/полётом |
| `scripts/mission/mission_manager.gd` | состояние задач; реализует контракт `objective_lines()` / `objective_title()`, который HUD уже ждёт |
| `tests/stage3_*.gd` | headless-сьюты на каждый новый блок (по образцу `tests/stage1_5_audio_test.gd`) |

## 5. План тестов Этапа 3

1. `tests/stage3_damage_test.gd` — щит поглощает урон, корпус получает остаток,
   корабль гибнет и сцена это переживает.
2. `tests/stage3_weapon_test.gd` — выстрел, перезарядка, энергия, попадание по
   цели.
3. `tests/stage3_mission_test.gd` — задачи появляются, HUD показывает строки,
   цель закрывается.
4. `tests/stage3_world_test.gd` — shatter и новые kind'ы в текущем мире.
5. Render-сьют `tests/stage3_screens.gd` — кадры с HUD и боем.
6. Полная регрессия: 17 сьютов (10 headless + 7 render) + новые.

## 6. Что не решено без спецификации

- точные значения урона, ёмкости щита и времени регенерации;
- состав и правила оружия, формула энергии;
- список задач, условия победы и поражения;
- что именно считается «корабль уничтожен» в текущем срезе;
- нужна ли отдельная сцена боя или всё в одной `SpaceMap.tscn`.

Пока спецификации нет, код выше трогать нельзя: любые числа будут выдуманными,
а это худший вид «сделанного Этапа 3».

Статусы: **реализовано** / **частично** / **отсутствует** / **проблемно**.

| # | Требование-кандидат | Статус | Доказательство | Куда ложится | Системы |
|---|---|---|---|---|---|
| A | HUD и сканер в текущем срезе | реализовано | `scenes/hud/HUD.tscn`, `scenes/world/SpaceMap.tscn:22` | — | HUD |
| B | Телеметрия корабля на стекле | реализовано | `scripts/hud.gd:336` — скорость, режим, состояние, заряд, счётчик мира | — | HUD, корабль |
| C | Щит / корпус / урон на `ShipController` | **отсутствует** | в `scripts/ship/ship_controller.gd` нет `shield_ratio()`, `hull_ratio()`, `destroyed`; есть только `boost` | новый `scripts/ship/damage_system.gd` + хуки в `ship_controller.gd` | корабль, HUD, звук |
| D | Задачи / миссии | **отсутствует** (контракт готов) | группа `mission` в проекте не используется; контракт описан в `scripts/hud.gd:79` | новый `scripts/mission/mission_manager.gd` (+ узел в `SpaceMap.tscn`) | HUD, мир |
| E | Оружие / наведение / энергия | **отсутствует** | в `scripts/ship/` нет ни одного узла оружия; `ship_controller.gd` знает только буст (`scripts/ship/boost_system.gd`) | новый `scripts/ship/weapon_system.gd`, `scripts/ship/targeting.gd` | корабль, мир, звук |
| F | Потребитель контракта `WorldObjects` | **частично** | `scripts/world/world_objects.gd:45,76,110` — `kind_of/describe/summarize`; читают их только отчёт о столкновении (`ship_controller.gd:847`) и debug (`ship_debug.gd:231`) — на вид kind'а не реагирует никто | `scripts/world/world_field.gd` + миссии | мир, HUD |
| G | Виды `DEBRIS` / `HAZARD` / `INTERACTABLE` | **отсутствует** | ветки `world_objects.gd:55-62`; в мире есть только группы `world_field` (`world_field.gd:87`) и `obstacle` (`rock.gd:62`) | новые узлы/популяции в `world_field.gd` + `world_objects.gd` | мир |
| H | Разрушение камней (shatter) в текущем срезе | **отсутствует** | есть только в легаси: `scripts/asteroid_field.gd:124`; в `scripts/world/world_field.gd` разрушения нет | `scripts/world/world_field.gd` + `scripts/obstacles/rock.gd` | мир, корабль, звук |
| I | Единая физика столкновений для корабля | **реализовано** | `ship_controller.gd:158,164` — сигналы `obstacle_hit`, `ship_collision_detected`; `:167` — `ship_state_changed` | — | корабль |
| J | Внешнее влияние на корабль | **реализовано** | `ship_controller.gd:730,740` — `add_external_acceleration`, `apply_external_impulse`; `:764,768` — `enable_control/disable_control` | — | корабль, физика |
