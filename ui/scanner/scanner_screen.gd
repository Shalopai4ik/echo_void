extends UiViewportPolicy
class_name ScannerScreen

## Visual-only scanner interface. All values come from local demonstration
## snapshots. No gameplay system or scanner implementation is referenced here.

enum DemoState { READY, SCANNING, CONTACTS_FOUND, NO_CONTACTS, LOW_ENERGY, MALFUNCTION }
signal scan_requested

const CONTACT_CARD_SCENE := preload("res://scenes/ui/components/ScannerContactCard.tscn")

@export var initial_state := DemoState.SCANNING

@onready var _state_label: Label = %State
@onready var _readiness: Label = %Readiness
@onready var _scan_status: Label = %ScanStatus
@onready var _progress: ProgressBar = %Progress
@onready var _progress_text: Label = %ProgressText
@onready var _remaining: Label = %Remaining
@onready var _scope: ScannerScope = %Scope
@onready var _scope_caption: Label = %ScopeCaption
@onready var _contact_count: Label = %ContactCount
@onready var _contact_list: VBoxContainer = %ContactList
@onready var _empty: Label = %Empty
@onready var _detail: PanelContainer = %Detail
@onready var _detail_type: Label = %DetailType
@onready var _detail_title: Label = %DetailTitle
@onready var _detail_description: Label = %DetailDescription
@onready var _detail_research: Label = %DetailResearch
@onready var _detail_analysis: Label = %DetailAnalysis
@onready var _action: Button = %Action
@onready var _demo: Button = %DemoState
@onready var _safe_area: MarginContainer = %SafeArea

var _demo_state := DemoState.READY
var _contacts: Array[ScannerContact] = []
var _cards: Dictionary = {}


func _ready() -> void:
	super._ready()
	_action.pressed.connect(func() -> void: scan_requested.emit())
	_demo.pressed.connect(_cycle_demo_state)
	get_viewport().size_changed.connect(_apply_safe_insets)
	_apply_safe_insets()
	set_demo_state(initial_state, ScannerDemoData.contacts())
	if not _contacts.is_empty():
		select_contact(_contacts[0].id)


func set_demo_state(state: DemoState, contacts: Array[ScannerContact] = []) -> void:
	_demo_state = state
	_contacts = contacts
	_cards.clear()
	for child in _contact_list.get_children():
		child.queue_free()
	for contact in _contacts:
		var card := CONTACT_CARD_SCENE.instantiate() as ScannerContactCard
		_contact_list.add_child(card)
		card.configure(contact)
		card.selected.connect(select_contact)
		_cards[contact.id] = card
	_scope.set_contacts(_contacts)
	_scope.selected_contact_id = ""
	_apply_state_presentation()
	_apply_safe_insets()


func select_contact(contact_id: String) -> void:
	for id in _cards:
		(_cards[id] as ScannerContactCard).set_selected(id == contact_id)
	_scope.selected_contact_id = contact_id
	var contact := _find_contact(contact_id)
	if contact == null:
		_detail.visible = false
		return
	_detail.visible = true
	_detail_type.text = contact.type_label
	_detail_title.text = contact.title
	_detail_description.text = contact.description
	_detail_research.text = contact.research_status
	_detail_analysis.text = "АНАЛИЗ ДОСТУПЕН" if contact.analysis_available else "АНАЛИЗ НЕДОСТУПЕН"
	_detail_analysis.add_theme_color_override("font_color",
		Color(0.48, 0.9, 0.84, 1.0) if contact.analysis_available else Color(0.62, 0.7, 0.72, 1.0))


func set_demo_contacts(contacts: Array[ScannerContact]) -> void:
	set_demo_state(_demo_state, contacts)


func _apply_state_presentation() -> void:
	var accent := Color(0.36, 0.86, 0.9, 1.0)
	var warning := Color(1.0, 0.68, 0.3, 1.0)
	var critical := Color(1.0, 0.4, 0.34, 1.0)
	_progress.value = 0.0
	_progress_text.text = "ПРОГРЕСС 000%"
	_remaining.text = "ОСТАЛОСЬ --:--"
	_scope.scanning = false
	_scope.progress = 0.0
	_scope_caption.text = "РАДАР / ОЖИДАНИЕ"
	_action.disabled = false
	_action.text = "НАЧАТЬ ОБХОД"
	_empty.visible = _contacts.is_empty()
	_detail.visible = false
	match _demo_state:
		DemoState.READY:
			_state_label.text = "● ГОТОВ"
			_readiness.text = "ГОТОВНОСТЬ 100%"
			_scan_status.text = "РЕЖИМ: ПАССИВНЫЙ"
		DemoState.SCANNING:
			_state_label.text = "◉ СКАНИРОВАНИЕ"
			_readiness.text = "ГОТОВНОСТЬ 100%"
			_scan_status.text = "РЕЖИМ: АКТИВНЫЙ ОБХОД"
			_progress.value = 63.0
			_progress_text.text = "ПРОГРЕСС 063%"
			_remaining.text = "ОСТАЛОСЬ 00:37"
			_scope.scanning = true
			_scope.progress = 0.63
			_scope_caption.text = "РАДАР / ВОЛНА ОБХОДА"
			_action.disabled = true
			_action.text = "ОБХОД ВЫПОЛНЯЕТСЯ"
		DemoState.CONTACTS_FOUND:
			_state_label.text = "◆ КОНТАКТЫ ОБНАРУЖЕНЫ"
			_readiness.text = "ГОТОВНОСТЬ 100%"
			_scan_status.text = "РЕЖИМ: РЕЗУЛЬТАТЫ ОБХОДА"
			_progress.value = 100.0
			_progress_text.text = "ПРОГРЕСС 100%"
			_remaining.text = "ОСТАЛОСЬ 00:00"
			_scope_caption.text = "РАДАР / КОНТАКТЫ"
			_action.text = "ПОВТОРИТЬ ОБХОД"
		DemoState.NO_CONTACTS:
			_state_label.text = "○ КОНТАКТОВ НЕТ"
			_readiness.text = "ГОТОВНОСТЬ 100%"
			_scan_status.text = "РЕЖИМ: ОБХОД ЗАВЕРШЁН"
			_progress.value = 100.0
			_progress_text.text = "ПРОГРЕСС 100%"
			_remaining.text = "ОСТАЛОСЬ 00:00"
			_scope_caption.text = "РАДАР / ПУСТО"
		DemoState.LOW_ENERGY:
			_state_label.text = "⚠ НЕДОСТАТОЧНО ЭНЕРГИИ"
			_readiness.text = "ГОТОВНОСТЬ 34%"
			_scan_status.text = "ТРЕБУЕТСЯ РЕЗЕРВ ЭНЕРГИИ 12%"
			_progress_text.text = "ПРОГРЕСС ———"
			_scope_caption.text = "РАДАР / ПИТАНИЕ ОГРАНИЧЕНО"
			_action.disabled = true
			_action.text = "НЕДОСТАТОЧНО ЭНЕРГИИ"
			accent = warning
		DemoState.MALFUNCTION:
			_state_label.text = "× НЕИСПРАВНОСТЬ"
			_readiness.text = "ГОТОВНОСТЬ 00%"
			_scan_status.text = "СБОЙ МОДУЛЯ 4B / КАЛИБРОВКА НЕВОЗМОЖНА"
			_progress_text.text = "ПРОГРЕСС ———"
			_scope_caption.text = "РАДАР / СИГНАЛ ПОТЕРЯН"
			_action.disabled = true
			_action.text = "СКАНЕР НЕИСПРАВЕН"
			accent = critical
	_state_label.add_theme_color_override("font_color", accent)
	_contact_count.text = "РЕЕСТР КОНТАКТОВ / %02d" % _contacts.size()


func _apply_safe_insets() -> void:
	var inset := safe_inset()
	_safe_area.add_theme_constant_override("margin_left", roundi(inset))
	_safe_area.add_theme_constant_override("margin_right", roundi(inset))
	_safe_area.add_theme_constant_override("margin_top", roundi(inset * 0.75))
	_safe_area.add_theme_constant_override("margin_bottom", roundi(inset * 0.75))


func _cycle_demo_state() -> void:
	var next_state := (int(_demo_state) + 1) % DemoState.size()
	var contacts: Array[ScannerContact] = []
	if next_state == DemoState.CONTACTS_FOUND or next_state == DemoState.SCANNING:
		contacts = ScannerDemoData.contacts()
	set_demo_state(next_state as DemoState, contacts)


func _find_contact(contact_id: String) -> ScannerContact:
	for contact in _contacts:
		if contact.id == contact_id:
			return contact
	return null
