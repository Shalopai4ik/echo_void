# Подэтап 6.6 — интерфейс улучшений оборудования и Research XP

Дата: 07.11.2026
Проект: `D:\programming\ideas\echo_void`
Проверено: `Godot 4.7.2`, headless-прогоны логических сьютов и оконный прогон
визуального сьюта на этой машине (NVIDIA RTX 3060 Ti, `gl_compatibility`).

Отчёт описывает только то, что сделано и проверено. Покупка улучшений и
списание Research XP сознательно **не** подключены.

## 1. Что было до начала работы

| Область | Фактическое состояние | Статус |
|---|---|---|
| `ResearchSystem` | XP, сигналы `xp_gained` / `xp_spent`, `spend_xp()`, save/load | реализовано, не тронуто |
| `ResearchUpgrade` / `ResearchUpgradeProfile` | каталог: 9 веток × 4 уровня, стоимость 50/100/200/400 XP | реализовано, не тронуто |
| `ResearchUpgradeManager` | покупка уровня, снимок базового значения, сигналы, save/load | реализовано, к UI не подключено |
| `assets/research/research_upgrade_profile.tres` | сканер (3 ветки), сигнальные огни (3), ложные цели (3) | реализовано |
| `scenes/ui/screens/UpgradesScreen.tscn` | статический макет-заглушка без скрипта: одна карточка «УСИЛЕНИЕ СКАНЕРА», «МАТЕРИАЛЫ 000» | заменено |
| `ResearchXpBadge` | отсутствовал; Research XP показывался только строкой в `ResearchScreen` | создано |
| `ui/upgrades/` | каталога не было | создано |
| Тема, `UiViewportPolicy`, карточки исследований | готовый визуальный язык и политика безопасных отступов | переиспользовано |

Дубликатов не создавалось: числа и правила каталога остаются в
`assets/research/research_upgrade_profile.tres`, панель получает их
демонстрационной таблицей только для отображения.

## 2. Что создано и изменено

Создано:

- `ui/upgrades/upgrade_visual.gd` — снимок одной ветки улучшения (уровень,
  текущее и следующее значение, цена, состояние `AVAILABLE` /
  `INSUFFICIENT_XP` / `MAXED`).
- `ui/upgrades/upgrade_device.gd` — снимок устройства: уровень, максимум,
  список веток, сводное состояние.
- `ui/upgrades/upgrades_demo_data.gd` — одна таблица данных: сканер, сигнальные
  огни, ложные цели; лестница 4 уровня × 50/100/200/400 XP повторяет каталог,
  базовые значения — экспорты самих устройств.
- `ui/upgrades/research_xp_badge.gd` + `scenes/ui/components/ResearchXpBadge.tscn`
  — иконка, подпись, число; пульс и всплывающее `+N` при получении очков.
- `ui/upgrades/upgrade_device_card.gd` + `scenes/ui/components/UpgradeDeviceCard.tscn`
  — карточка устройства: иконка, название, роль, уровень, состояние.
- `ui/upgrades/upgrade_path_row.gd` + `scenes/ui/components/UpgradePathRow.tscn`
  — строка ветки: уровень, `текущее → следующее`, цена, состояние.
- `ui/upgrades/upgrades_screen.gd` — презентер панели: открытие/закрытие,
  выбор устройства и ветки, пересчёт доступности, состояние кнопки.
- `scenes/ui/screens/UpgradesPreview.tscn` — изолированная сцена просмотра.
- `tests/upgrades_ui_test.gd` — 68 headless-проверок.
- `tests/upgrades_ui_visual.gd` — скриншоты в `test-output/upgrades-ui/`.

Изменено:

- `scenes/ui/screens/UpgradesScreen.tscn` — макет заменён рабочей панелью.
- `scenes/ui/screens/HUD.tscn`, `ui/hud/hud_screen.gd`,
  `ui/hud/hud_visual_data.gd`, `ui/hud/hud_demo_data.tres` — бейдж Research XP
  в правом верхнем углу визуального HUD.
- `project.godot` — действие `toggle_upgrades` (клавиша `U`). Управление
  кораблём не менялось.
- `tests/ui_architecture_test.gd` — `UpgradesPreview.tscn` добавлен в список
  проверяемых сцен.
- `tools/testing/run_tests.ps1` — `upgrades_ui_visual` в списке визуальных сьютов.
- `README.md`, `docs/README.md`, `docs/testing.md`, `docs/ui/README.md`.

## 3. Как открыть и проверить

```powershell
# сцена просмотра
godot --path . scenes/ui/screens/UpgradesPreview.tscn
# логический сьют панели
godot --headless --path . --script tests/upgrades_ui_test.gd
# скриншоты панели
godot --path . --script tests/upgrades_ui_visual.gd
```

Внутри панели: `U` — открыть/закрыть, `Esc` — закрыть, клик по карточке
устройства — выбор, клик по строке ветки — выбор улучшения, `ДЕМО: +150 XP` —
показать выделение получения очков и пересчёт доступности.

## 4. Что работает только визуально

- Каталог и уровни — снимок `ui/upgrades/upgrades_demo_data.gd`, а не чтение
  `ResearchUpgradeManager` и не `status()` устройства.
- XP на бейдже HUD и панели — демонстрационное число; `ResearchSystem.xp_gained`
  к нему не подключён.
- Кнопка улучшения только испускает `upgrade_requested(device_id, upgrade_id)`.
  `spend_xp()` не вызывается, уровень не покупается, сейв не пишется.
- Панель не вставлена ни в `InterfaceShell`, ни в игровую сцену: открывается
  только как самостоятельная сцена.

## 5. Проверка

| Проверка | Результат |
|---|---|
| `tests/upgrades_ui_test.gd` | ALL PASS, 68 проверок |
| `tests/ui_architecture_test.gd` (все сцены × 6 разрешений) | ALL PASS, 86 проверок |
| `tests/research_ui_test.gd` (регресс) | ALL PASS, 60 проверок |
| `tests/hud_visual_test.gd` (HUD с бейджем) | ALL PASS, 19 проверок |
| `tests/upgrades_ui_visual.gd` (окно 960×540, 1280×720, полный экран, закрытая панель) | ALL PASS, 6 проверок |

Разрешения 640×360, 960×540, 1280×720, 1920×1080, 2560×1080 и 1024×768:
ни один видимый элемент не выходит за границы вьюпорта; длинные списки
прокручиваются, а не обрезаются. Чёрных полос нет — проект использует
`canvas_items` + `expand`.

Найдено и исправлено в ходе проверки:

1. Ячейки `GridContainer` характеристик получали ширину 1 px (`clip_text`
   обнулял минимальную ширину) — текст был невидим. Проверка добавлена в сьют.
2. Значение вида `×1.20` печаталось как `×1.2` — формат переведён на
   фиксированное число знаков после запятой.
3. Статус в карточке устройства был невидим по той же причине, что и (1).
4. Роль «DECOY LAUNCHER / COUNTERMEASURE» обрезалась — сокращена.

## 6. Что остаётся на следующий этап

1. Контроллер, который строит `UpgradeVisual` из `ResearchUpgradeManager` и
   `ShipComponent.status()`, подписывается на `upgrade_purchased` и
   `xp_gained`, и передаёт панели живые данные.
2. Подключение `upgrade_requested` к `purchase()` с обработкой отказов
   (`insufficient_xp`, `max_level`, `device_not_found`, `wrong_device_type`).
3. Вставка панели в `InterfaceShell` (`ScreenLayer`), пауза игры на время
   открытия, миграция игрового HUD на `scenes/ui/screens/HUD.tscn`.
4. Бейдж Research XP на игровом HUD (`scenes/hud/HUD.tscn`) — после миграции.
5. Реальные иконки устройств вместо типографских глифов, когда появится арт.