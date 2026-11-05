# Подэтап 3.4 — астероиды, обломки и декор

Дата: 04.11.2026  
Проект: `D:\programming\ideas\echo_void`  
Срез: `scenes/world/SpaceMap.tscn` (текущий), без изменений легаси-среза.

## 1. Аудит до правок

| Область | Статус до подэтапа | Вывод |
|---|---|---|
| Бесконечный мир и чанки | реализовано | `EchoWorldField`, отдельная решётка и salt каждой population, выгрузка/повторная загрузка по seed |
| Астероиды | реализовано | 20 форм, три класса размера, физическая коллизия по силуэту, масса и tint |
| Декоративный контент | частично | `fragments`, `wrecks`, `structures`, `beacons` уже existed, но отдельной категории металлических обломков не было |
| Коллизии корабля | реализовано | единый `body_shape_entered`, `LIGHT/MEDIUM/HEAVY`, cooldown и `WorldObjects.describe()` |
| Уникальные ID и состояние | реализовано | `chunk_id` + стабильный `item_id` (`cell:slot`), `ChunkStateStore` |
| Debug | частично | были общие числа populations, но не семантические категории |

## 2. Реализация

- Добавлена population `debris`: независимый salt `617`, собственная решётка чанков, patch-поля, редкие кластеры и собственные лимиты.
- Добавлена `SpaceObjectKind.object_kind`: `asteroid`, `debris`, `decorative`; декоративные спрайты получают тот же интерфейс через группу и metadata.
- Добавлены шесть тёмных металлических спрайтов `assets/world/debris/debris_01..06.png` и воспроизводимый генератор `tools/asset_pipeline/world/make_stage3_4_debris.py`.
- Добавлен `scenes/world/Debris.tscn` + `scripts/world/debris.gd`: статический мировой `RigidBody2D`, collision layer 1, круглый консервативный hull, масса, tint и `WorldObjects.KIND_DEBRIS`.
- Обломки используют штатный контакт корабля; новый обработчик столкновений не создавался.
- `EchoWorldField.stats()` и `debug_lines()` расширены категориями `asteroid/debris/decorative`; HUD показывает их количества.
- Твёрдая debris population планируется перед поясом, чтобы общий покадровый бюджет не вытеснял редкий поток; `gameplay_plane()` по-прежнему явно возвращает `asteroids`.
- Легаси-срез `scenes/main.tscn` и `scripts/asteroid_field.gd` не изменялся.

## 3. Проверка A–J

| # | Проверка | Результат |
|---|---|---|
| A | три категории, независимые salt и диагностика | PASS |
| B | формы/размеры астероидов и совпадение collision hull с артом | PASS |
| C | редкость debris, несколько вариантов, наличие декора | PASS (8 debris против 428 asteroids в 8 окнах) |
| D | штатная коллизия корабля и классификация скорости | PASS (`MEDIUM`, kind=`debris`) |
| E | независимость debris от asteroid seed/planning | PASS |
| F | детерминизм по seed и координатам | PASS |
| G | выгрузка старых чанков и возврат без дублей | PASS |
| H | бюджет генерации, лимиты populations, bounded scene tree | PASS (worst 2353 us; 115 live; tree 5→5) |
| I | интеграция с HUD, gameplay plane и `WorldObjects` | PASS |
| J | debug/statistics показывают категории и счётчики | PASS |

Новый сьют: `tests/stage3_4_space_objects_test.gd` — **ALL PASS, 36 assertions** (точное число может измениться при правках сьюта).

## 4. Регрессия

- `tests/stage3_4_space_objects_test.gd` — ALL PASS.
- `tests/stage3_3_world_chunks_test.gd` — ALL PASS, 106 assertions.
- `tests/stage2_world_test.gd` — ALL PASS.
- `tests/hud_test.gd` — ALL PASS, 19 assertions.
- `tools/validation/asset_check.py` — OK; единственное предупреждение — отсутствие аудиофайлов, не связанное с подэтапом.
- Визуальный сьют `tests/stage3_4_space_screens.gd` — успешно; кадры в `test-output/stage34/`.
- Полный прогон всех headless-съютов: **13/14 suites PASS, 1066/1067 assertions PASS**. Единственный сбой — известный timing-sensitive `stage1_5_audio_test` (`letting go does not cut the spin`); отдельный повторный прогон этого сьюта дал **ALL PASS**. Сбой не затрагивает world/debris и соответствует уже описанной в `docs/testing.md` чувствительности audio-теста.
- Логи полного прогона: `test-output/logs/all_logic_final.out`, `test-output/logs/summary.csv`; повтор audio: `test-output/logs/stage1_5_retry.out`.

## 5. Ограничения

- Разрушение, добыча, взаимодействие с обломками, урон и аномалии не реализовывались — они относятся к следующим подэтапам.
- Круглый collision hull обломка консервативен и не повторяет каждый выступ металлического силуэта; визуальная форма читается отдельно от коллизии.
- Сообщения Godot о RID/ObjectDB на выходе — известные teardown-artefacts проекта, описанные в `docs/testing.md`; новый тест не создаёт дополнительных живых узлов после завершения.
