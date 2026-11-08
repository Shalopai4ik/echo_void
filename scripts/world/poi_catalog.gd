class_name POICatalog

## Every kind of research object the survey can find, as data.
##
## A kind says what it looks like (textures, scale, glow), what the scanner
## and the desk call it, what studying it gives back (`reward`) and how much it
## disturbs the thing in the dark (`disturbance`, attention points). Field
## kinds are rolled by `POIField`; story kinds are placed by the mission.
##
## Rewards the `ResearchRewards` node understands:
##   repair  - hull fraction restored         energy - reserve units
##   decoy   - decoys back in the launcher    flare  - flares back in the rack

const RELICS := "res://assets/relics/"

const KINDS := {
	"wreck_fragment": {
		"title": "ОБЛОМОК",
		"textures": ["wreck_fragment_1", "wreck_fragment_2", "wreck_fragment_3",
			"wreck_fragment_4", "wreck_fragment_5", "wreck_fragment_6",
			"wreck_fragment_7", "wreck_fragment_8", "wreck_fragment_9"],
		"scale": 1.1, "glow": Color(0.35, 0.75, 0.95),
		"reward": {"repair": 0.08}, "disturbance": 0.0, "weight": 30.0,
		"descriptions": [
			"Фрагмент обшивки. Края оплавлены изнутри наружу.",
			"Деталь силового набора. Маркировка стёрта.",
			"Кусок теплозащиты. Пригоден для ремонта корпуса.",
		],
		"notes": [
			"Сплав совпадает с обшивкой кораблей класса «Пелагия».",
			"Следы удара не механические: металл вытянут, как воск.",
			"Пригодный материал отправлен в ремонтный контур.",
		],
	},
	"hull_section": {
		"title": "СЕКЦИЯ КОРПУСА",
		"textures": ["hull_section_1", "hull_section_2", "hull_section_3", "hull_section_4",
			"hull_section_5", "hull_section_6", "hull_section_7", "hull_section_8",
			"hull_section_10"],
		"scale": 1.5, "glow": Color(0.4, 0.8, 1.0),
		"reward": {"decoy": 1, "repair": 0.04}, "disturbance": 2.0, "weight": 18.0,
		"descriptions": [
			"Отсек неизвестного судна. Внутри - остаточное питание.",
			"Секция грузового модуля. Шлюз открыт.",
			"Носовая часть. Обзорные окна целы, за ними темно.",
		],
		"notes": [
			"Найден исправный пусковой контейнер. Ложная цель снаряжена.",
			"Бортовой журнал обрывается на слове «тишина».",
			"Экипажа нет. Скафандры на месте.",
		],
	},
	"ring_segment": {
		"title": "СЕГМЕНТ КОЛЬЦА",
		"textures": ["ring_segment_1", "ring_segment_2", "ring_segment_3",
			"ring_segment_4", "ring_segment_5"],
		"scale": 1.45, "glow": Color(0.3, 0.9, 0.9),
		"reward": {"energy": 300.0}, "disturbance": 3.0, "weight": 12.0,
		"descriptions": [
			"Часть кольцевой конструкции. Радиус кривизны - сотни километров.",
			"Фрагмент кольца. Внутри - накопительные ячейки.",
		],
		"notes": [
			"Ячейки ещё держат заряд. Энергия передана в резерв.",
			"Кольцо собрано не людьми. Стыки не имеют крепежа.",
		],
	},
	"crystal": {
		"title": "КРИСТАЛЛИЧЕСКОЕ ТЕЛО",
		"textures": ["crystal_1", "crystal_2", "crystal_3"],
		"scale": 1.1, "glow": Color(0.45, 0.55, 1.0),
		"reward": {"energy": 450.0}, "disturbance": 0.0, "weight": 14.0,
		"descriptions": [
			"Порода с кристаллическими жилами. Слабое свечение.",
			"Голубые кристаллы. Пьезоэффект в вакууме.",
		],
		"notes": [
			"Кристаллы разряжены в резерв корабля.",
			"Решётка кристалла повторяет узор на кольцах.",
		],
	},
	"signal_buoy": {
		"title": "СИГНАЛЬНЫЙ БУЙ",
		"textures": ["signal_buoy_1", "signal_buoy_2"],
		"scale": 1.15, "glow": Color(1.0, 0.65, 0.3),
		"reward": {"flare": 1}, "disturbance": 1.0, "weight": 10.0,
		"descriptions": [
			"Навигационный буй. Передатчик молчит.",
			"Антенная мачта. Аккумулятор жив.",
		],
		"notes": [
			"Сигнальная шашка буя переставлена на стойку корабля.",
			"Буй передавал одно слово на всех частотах: «ТИХО».",
		],
	},
	"alien_orb": {
		"title": "СФЕРА",
		"textures": ["alien_orb"],
		"scale": 1.25, "glow": Color(1.0, 0.55, 0.2),
		"reward": {"energy": 200.0}, "disturbance": 14.0, "weight": 5.0,
		"descriptions": [
			"Сфера из сегментов. Внутри - два тёплых пятна.",
		],
		"notes": [
			"Сфера отозвалась на импульс. Что-то внизу ответило ей.",
			"Сегменты сферы растут. Это не конструкция - это оболочка.",
		],
	},
	"monolith": {
		"title": "ПОРОДА С ВКЛЮЧЕНИЯМИ",
		"textures": ["monolith_rock"],
		"scale": 1.5, "glow": Color(0.4, 0.6, 1.0),
		"reward": {"flare": 1, "decoy": 1}, "disturbance": 6.0, "weight": 5.0,
		"descriptions": [
			"Астероид, прошитый металлическими структурами.",
		],
		"notes": [
			"В породе - тайник экспедиции: огонь и ложная цель.",
			"Металл в породе вырос, а не был вбит.",
		],
	},
	"husk": {
		"title": "ОРГАНИЧЕСКИЕ ОСТАНКИ",
		"textures": ["@brood/death_3"],
		"scale": 1.2, "glow": Color(1.0, 0.25, 0.2),
		"reward": {}, "disturbance": 10.0, "weight": 6.0,
		"descriptions": [
			"Хитиновые фрагменты. Тёплые.",
		],
		"notes": [
			"Это сброшенная оболочка. Малые особи растут быстро.",
			"Ткань реагирует на свет: сжимается и темнеет.",
		],
	},
	# ------------------------------------------------------------- story kinds ---
	"story_beacon": {
		"title": "МАЯК «ПЕЛАГИИ»",
		"textures": ["signal_buoy_1"],
		"scale": 1.6, "glow": Color(1.0, 0.7, 0.3),
		"reward": {"flare": 1}, "disturbance": 4.0, "weight": 0.0,
		"descriptions": ["Аварийный маяк экспедиции. Передаёт запись."],
		"notes": [],
	},
	"pelagia": {
		"title": "«ПЕЛАГИЯ»",
		"textures": ["hull_section_9"],
		"scale": 3.2, "glow": Color(0.6, 0.85, 1.0),
		"reward": {"decoy": 2, "repair": 0.25}, "disturbance": 12.0, "weight": 0.0,
		"descriptions": ["Исследовательское судно «Пелагия». Пропало три года назад."],
		"notes": [],
	},
	"resonance_node": {
		"title": "РЕЗОНАНСНЫЙ УЗЕЛ",
		"textures": ["alien_orb"],
		"scale": 2.0, "glow": Color(1.0, 0.4, 0.25),
		"reward": {"energy": 300.0}, "disturbance": 12.0, "weight": 0.0,
		"descriptions": ["Узел, через который проходит низкочастотный сигнал из облаков."],
		"notes": [],
	},
	"source": {
		"title": "ИСТОЧНИК",
		"textures": ["ring_segment_4"],
		"scale": 5.5, "glow": Color(1.0, 0.3, 0.2),
		"reward": {}, "disturbance": 20.0, "weight": 0.0,
		"descriptions": ["Кольцо размером с крейсер. В центре - тьма, которая отражает сканер."],
		"notes": [],
	},
}

## Kinds the procedural field rolls.
const FIELD_KINDS := ["wreck_fragment", "hull_section", "ring_segment", "crystal",
	"signal_buoy", "alien_orb", "monolith", "husk"]
## Kinds that grow more common the deeper the ship is.
const DEEP_KINDS := ["alien_orb", "monolith", "husk"]


static func kind(kind_id: String) -> Dictionary:
	return KINDS.get(kind_id, {})


static func texture_path(name: String) -> String:
	if name.begins_with("@brood/"):
		return "res://assets/threats/brood/%s.png" % name.substr(7)
	return "%s%s.png" % [RELICS, name]
