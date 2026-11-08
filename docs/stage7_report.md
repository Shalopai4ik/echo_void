# Подэтап 7 — интерфейс корабля: оборудование, пауза, слоты и экраны

Дата: 07.11.2026
Проект: `D:\programming\ideas\echo_void`
Проверено: Godot 4.7.2, headless-прогоны всех логических сьютов.

Исходная точка (по отчёту 6.8): живой интерфейс игры — это HUD полёта и
панель улучшений. `ScannerScreen`, `ResearchScreen`, `EquipmentScreen` были
неподключёнными презентациями, `MainMenu` и `PauseMenu` игрой не
запускались, карточка «ИССЛЕДОВАТЬ СЕКТОР» была нарисованной надписью
«0 / 1», а слоты 1–4 на HUD не были привязаны ни к одному устройству.

Этот подэтап закрывает все семь пунктов задачи.

## 1. Что сделано

| # | Задача | Как сделано | Файлы |
|---|---|---|---|
| 1 | Включение сканера и исследовательского оборудования | Панель оборудования читает настоящий хаб `ShipSystems` и бросает его же переключатели через `toggle_enabled()` / `set_enabled()` | `ui/equipment/equipment_console.gd`, `ui/equipment/equipment_screen.gd`, `ui/equipment/equipment_card.gd`, `scenes/ui/screens/EquipmentScreen.tscn`, `scenes/ui/components/EquipmentCard.tscn`, `scenes/ui/EquipmentConsole.tscn` |
| 2 | Полноценная пауза | Единый механизм в `InterfaceScreen`: физический сервер выключается, корпус и поле астероидов перестают обрабатываться, скорости не пишутся | `ui/core/interface_screen.gd` |
| 3 | Карточка «ИССЛЕДОВАТЬ СЕКТОР» | Читает прогресс настоящего исследовательского стола, а не рисует «0 / 1» | `ui/hud/sector_objective.gd`, `scripts/hud.gd` |
| 4 | Слоты 1–4 | Один реестр слотов на весь корабль: номер, устройство, клавиша | `scripts/ship/systems/equipment_slots.gd`, `project.godot`, `scenes/world/SpaceMap.tscn` |
| 5 | Подключение всех экранов и меню | Сканер, исследования, главное меню и меню паузы получили свои консоли и читают настоящие данные | `ui/scanner/*`, `ui/research/*`, `ui/menu/*`, `scenes/ui/*Console.tscn` |
| 6 | Мультимониторность и полный экран | Соблюдена существующая политика `UiViewportPolicy`; ручной чек-лист — в `docs/display_testing.md` | `ui/core/interface_screen.gd`, `docs/display_testing.md` |
| 7 | Интеграционный прогон полного цикла | Новый сьют `tests/interface_integration_test.gd` | `tests/interface_integration_test.gd` |

Что намеренно **не** менялось: энергобаланс (`assets/ship/systems_parameters.tres`,
`ship_energy_system.gd`), баланс XP и улучшений (`research_upgrade_profile.tres`,
`research_upgrade_manager.gd`), модель полёта (`ship_controller.gd`) и генерация
мира (`world_field.gd`). Панели и слоты пользуются только существующими
ценами: включение устройства по-прежнему стоит `activation_energy_cost`
устройства, запуск приманки — `activation_cost` приманки.


## 2. Архитектура интерфейсного слоя

```
InterfaceScreen (ui/core/interface_screen.gd)   — один «владелец мира»
├── EquipmentScreen   ← EquipmentConsole ← хаб ShipSystems + EquipmentSlots
├── ScannerScreen     ← ScannerConsole   ← ShipScanner + ResearchSystem
├── ResearchScreen    ← ResearchConsole  ← ResearchSystem + ShipScanner
├── UpgradesScreen    ← UpgradesConsole  ← ResearchUpgradeManager
├── PauseMenuScreen   ← PauseMenuConsole ← SessionClock + корпус
└── MainMenuScreen    ← MainMenuConsole  ← SessionClock
```

* `InterfaceScreen` — модальная панель: входит в группу `ui_modal`, держит
  мир, закрывает остальные панели, закрывается по `Esc`.
* `InterfaceConsole` — слой между экраном и кораблём: находит систему через
  дерево, наполняет экран живыми данными, превращает нажатие кнопки в вызов
  системы. Каждая консоль в группе `interface_panel` и имеет `panel_id`, так
  что панель может передать экран другой панели («СКАНЕР» на панели
  оборудования открывает экран сканера), не зная её класса.
* Экран — только презентация: он показывает то, что ему дали, и сообщает о
  намерении пилота. Он не считает контактов сам, не тратит XP и не бросает
  переключатели.

### Клавиши

| Клавиша | Действие |
|---|---|
| `R` | обход сканера (радар HUD) — как было |
| `I` | панель оборудования |
| `C` | экран сканера |
| `N` | экран исследований |
| `U` | панель улучшений — как было |
| `1`–`4` | слоты оборудования: переключатель или пуск |
| `Esc` | закрыть панель / открыть меню паузы |

Слоты не имеют отдельных подсистем: `EquipmentSlots` один на корабль, и его
`_unhandled_input` отвечает только когда мир не держит панель.

## 3. Пауза: что пришлось изменить в плане

Планом предполагалось `SceneTree.paused`. **Так делать нельзя** — на этой
сцене и этой версии движка так ломается физический сервер.

Что измерено (проба была временной и удалена после замера):

* `SceneTree.paused = true` действительно замораживает физику: `physics_frame`
  продолжает приходить, скорость тела не меняется ни на бит;
* но при возврате в игру Godot 4.7.2 печатает
  `ERROR: Condition "p_elem->_root" is true. at: add (core/templates/self_list.h:46)`
  и процесс падает. Ошибка идёт из списка «проснувшихся тел» в 2D-физике
  (`GodotBody2D::active_list`, `modules/godot_physics_2d/godot_body_2d.h`):
  тело добавляется в список повторно;
* ошибка воспроизводится и с одним кораблём, и с одним полем астероидов, то
  есть дело не в количестве тел, а в самом переходе «пауза → пауза снята»;
* `PhysicsServer2D.set_active(false)` перед `SceneTree.paused` убирает ошибку
  полностью.

Поэтому пауза сделана без `SceneTree.paused`:

1. `PhysicsServer2D.set_active(false)` — физический сервер не шагает, тела не
   двигаются и не переписываются;
2. `process_mode = DISABLED` у корпуса и у поля астероидов — не тикает модель
   полёта, энергетические часы, сканер, исследовательский стол и стриминг
   мира;
3. обратно: `process_mode` возвращается к прежнему значению, сервер включается.

Проверено замерами: позиция, линейная и угловая скорости корпуса возвращаются
**бит в бит**, заряд энергии за время панели не меняется ни на единицу, ошибок
движка нет. Собственное состояние панелей (`ui_modal`) принадлежит группе, а не
экрану: панель, закрытая при открытой другой, не отпускает мир.

Экран при этом продолжает жить (`process_mode = ALWAYS`): он рисуется и
принимает клики, пока мир стоит.


## 4. Честные ограничения

* **Показ сканера и исследований замирает вместе с миром.** Панель держит
  мир, поэтому начатый обход или начатый анализ идут только после закрытия
  панели. Это следствие требования «пауза ничего не меняет»: энергия не
  тратится, XP не капает, физика стоит. Если понадобится «прибор работает, а
  корабль летит» — это отдельное решение (свой `process_mode` для приборов и
  свой флаг паузы), здесь оно не делалось.
* **Мультимониторность проверена только по документации и коду.** Автотест
  не может перенести окно на второй монитор; ручной чек-лист — в
  `docs/display_testing.md`, фактический прогон на втором мониторе не
  выполнялся.
* **Главное меню не открывается на старте.** Оно открывается из меню паузы
  («ЗАВЕРШИТЬ ИССЛЕДОВАНИЯ»). Открытие его на старте меняло бы поведение
  игры (полёт начинался бы с замороженного мира), а задача этого подэтапа —
  подключить меню, а не изменить порядок запуска.
* **Кнопка «НАСТРОЙКИ» удалена** из обоих меню: за ней не было действия, а
  декоративных кнопок в задании быть не должно.

## 5. Проверка

| Сьют | Что проверяет |
|---|---|
| `tests/interface_integration_test.gd` | панели держат мир (позиция и обе скорости бит в бит), энергия не тратится, панель показывает настоящие устройства, слот 1 бросает выключатель сканера, пустой слот 4 ничего не делает, карточка сектора считает настоящие предметы стола, открытая панель закрывает другую, в группе `ui_modal` ровно одна панель |
| `tests/hud_test.gd` | HUD не сломан: скан по `R` не доходит до сканера за открытой панелью и доходит после её закрытия, карточки улучшений не копятся |
| остальные логические сьюты | регрессии по энергии, сканеру, исследованиям, улучшениям, оборудованию, миру |

Запуск всех сьютов: `tools/testing/run_tests.ps1` (находит сьюты чтением
папки `tests`), список — `tools/testing/stage7_check.ps1`.

### Результат прогона (33 логических сьюта, Godot 4.7.2, headless)

| Сьют | Вердикт | Утверждений |
|---|---|---|
| `interface_integration_test` (новый) | PASS | 23 / 0 |
| `hud_test` | PASS | 28 / 0 |
| `ui_architecture_test` | PASS | 106 / 0 |
| `scanner_test`, `scanner_ui_test` | PASS | 105, 21 / 0 |
| `research_system_test`, `research_ui_test`, `research_upgrade_test` | PASS | 65, 60, 51 / 0 |
| `ship_energy_test`, `ship_equipment_test`, `ship_systems_test`, `ship_integration_test`, `ship_damage_test` | PASS | 61, 53, 99, 116, 72 / 0 |
| `upgrades_integration_test`, `upgrades_ui_test` | PASS | 59, 70 / 0 |
| `display_test`, `hud_visual_test` | PASS | 70, 22 / 0 |
| `stage1_control_test`, `stage2_world_test`, `stage3_*` | PASS | 155, 96, 43, 30 / 0 |
| `stage1_5_audio_test` | **2 упавших утверждения** | 103 / 2 |
| `stage3_3_world_chunks_test` | **ошибка в устаревшем утверждении** | 98 / 0 |

Оба оставшихся красных места **не связаны с этим подэтапом** и проверены на
чистом `HEAD` (git worktree, без единой из правок этого этапа):

* `stage1_5_audio_test` — «flying into a rock raises exactly one impact»
  падает и на `HEAD` (та же строка, те же цифры); второе утверждение
  («letting go does not cut the spin») — известная проблема времени на этой
  машине, она уже описана в `docs/testing.md` и проходит, когда сьют идёт
  без нагрузки;
* `stage3_3_world_chunks_test` — сьют читает `hud_state()["slice"]`, а такого
  ключа нет ни в `HEAD`, ни в текущем `scripts/hud.gd`: сьют отстал от HUD.
  Сьют печатает `RESULT: ALL PASS`, но падает на строке, поэтому раннер
  правильно помечает его как PARSE.

Свою регрессию — узкий футер панели оборудования на окне 640x360 —
подэтап поймал и починил (`ui_architecture_test` теперь 106/0).



## 6. Список изменённых файлов

Новые:

* `ui/core/interface_screen.gd`, `ui/core/interface_console.gd`
* `scripts/ship/systems/equipment_slots.gd`
* `ui/hud/sector_objective.gd`
* `ui/equipment/equipment_card.gd`, `equipment_console.gd`, `equipment_screen.gd`
* `ui/scanner/scanner_snapshot.gd`, `scanner_console.gd`
* `ui/research/research_snapshot.gd`, `research_console.gd`
* `ui/menu/session_clock.gd`, `pause_menu_screen.gd`, `pause_menu_console.gd`,
  `main_menu_screen.gd`, `main_menu_console.gd`
* `scenes/ui/EquipmentConsole.tscn`, `ScannerConsole.tscn`, `ResearchConsole.tscn`,
  `PauseMenuConsole.tscn`, `MainMenuConsole.tscn`
* `scenes/ui/components/EquipmentCard.tscn`
* `tests/interface_integration_test.gd`
* `tools/testing/stage7_check.ps1`
* `docs/stage7_report.md`, `docs/display_testing.md`

Изменённые:

* `project.godot` — действия `toggle_equipment` (`I`), `toggle_scanner` (`C`),
  `toggle_research` (`N`), `equipment_slot_1..4` (`1`–`4`)
* `scenes/world/SpaceMap.tscn` — реестр слотов и пять консолей
* `scenes/ui/screens/EquipmentScreen.tscn`, `PauseMenu.tscn`, `MainMenu.tscn`,
  `ScannerScreen.tscn`, `ResearchScreen.tscn`, `UpgradesScreen.tscn`
* `scripts/hud.gd` — карточка сектора и ряд слотов читают живые данные
* `ui/upgrades/upgrades_screen.gd`, `ui/upgrades/upgrades_console.gd` — перешли
  на общий модальный базовый класс
* `ui/scanner/scanner_screen.gd`, `ui/research/research_screen.gd` — живой режим
  поверх демонстрационного
