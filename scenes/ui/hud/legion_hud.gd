## Battle HUD.
##
## Everything is built in code so the layout can react to how many roles you
## actually have - an empty legion shows nothing, a mixed one shows a chip per
## role with the currently-selected throw role highlighted.
class_name LegionHUD
extends Control

const CHIP_MIN_WIDTH := 78

var commander: Character = null

var _roster_box: HBoxContainer
var _health_bar: ProgressBar
var _health_label: Label
var _objective_label: Label
var _score_label: Label
var _held_label: Label
var _feed: VBoxContainer
var _hint_label: Label
var _chips: Dictionary = {}   # role -> {panel, label}
var _refresh_timer: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build()
	Battle.battle_event.connect(_on_battle_event)
	Battle.objectives_changed.connect(_on_objectives_changed)


func bind(new_commander: Character) -> void:
	commander = new_commander
	if commander == null:
		return
	commander.squad_changed.connect(func(_n): _refresh_roster())
	commander.health_changed.connect(func(_c, _m): _refresh_health())
	commander.held_unit_changed.connect(_on_held_changed)
	_refresh_roster()
	_refresh_health()


func _process(delta: float) -> void:
	_refresh_timer -= delta
	if _refresh_timer > 0.0:
		return
	_refresh_timer = 0.25
	_refresh_roster()
	_refresh_score()


# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

func _build() -> void:
	# --- bottom-left: squad roster -----------------------------------------
	var bottom := MarginContainer.new()
	bottom.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	bottom.anchor_top = 1.0
	bottom.anchor_bottom = 1.0
	bottom.offset_top = -104.0
	bottom.offset_left = 18.0
	bottom.offset_right = 780.0
	bottom.offset_bottom = -18.0
	bottom.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bottom)

	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 6)
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bottom.add_child(stack)

	_roster_box = HBoxContainer.new()
	_roster_box.add_theme_constant_override("separation", 6)
	_roster_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.add_child(_roster_box)

	var health_row := HBoxContainer.new()
	health_row.add_theme_constant_override("separation", 8)
	health_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.add_child(health_row)

	_health_label = _make_label("COMMANDER", 13, Color(0.85, 0.85, 0.82))
	health_row.add_child(_health_label)

	_health_bar = ProgressBar.new()
	_health_bar.custom_minimum_size = Vector2(220, 14)
	_health_bar.show_percentage = false
	_health_bar.max_value = 100.0
	_health_bar.value = 100.0
	_health_bar.add_theme_stylebox_override("background", _flat(Color(0.08, 0.08, 0.10, 0.85)))
	_health_bar.add_theme_stylebox_override("fill", _flat(Color(0.85, 0.24, 0.26, 0.95)))
	health_row.add_child(_health_bar)

	_held_label = _make_label("", 13, Color(1.0, 0.85, 0.45))
	health_row.add_child(_held_label)

	# --- top-right: objectives & score -------------------------------------
	var top_right := VBoxContainer.new()
	top_right.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	top_right.anchor_left = 1.0
	top_right.anchor_right = 1.0
	top_right.offset_left = -280.0
	top_right.offset_top = 18.0
	top_right.offset_right = -18.0
	top_right.alignment = BoxContainer.ALIGNMENT_END
	top_right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(top_right)

	_objective_label = _make_label("Camps 0 / 0", 17, Color(1.0, 0.88, 0.45))
	_objective_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	top_right.add_child(_objective_label)

	_score_label = _make_label("", 13, Color(0.80, 0.82, 0.85))
	_score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	top_right.add_child(_score_label)

	# --- right: killfeed ----------------------------------------------------
	_feed = VBoxContainer.new()
	_feed.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	_feed.anchor_left = 1.0
	_feed.anchor_right = 1.0
	_feed.offset_left = -300.0
	_feed.offset_right = -18.0
	_feed.offset_top = -120.0
	_feed.alignment = BoxContainer.ALIGNMENT_END
	_feed.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_feed)

	# --- top-left: controls -------------------------------------------------
	_hint_label = _make_label(
		"WASD move   LMB throw   RMB whistle   TAB role   SPACE charge   X dismiss   Q/E orbit   wheel zoom",
		12, Color(0.72, 0.74, 0.78, 0.85)
	)
	_hint_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_hint_label.offset_left = 20.0
	_hint_label.offset_top = 16.0
	_hint_label.offset_right = 900.0
	_hint_label.offset_bottom = 40.0
	add_child(_hint_label)


# ---------------------------------------------------------------------------
# Roster chips
# ---------------------------------------------------------------------------

func _refresh_roster() -> void:
	if not is_instance_valid(commander):
		return
	var breakdown := commander.squad_breakdown()
	for role in CombatTypes.PLAYER_ROLES:
		var count := int(breakdown.get(role, 0))
		var chip = _chips.get(role)
		if chip == null:
			chip = _make_chip(role)
			_chips[role] = chip
		var selected: bool = commander.selected_role == role
		chip["panel"].visible = count > 0 or selected
		chip["label"].text = "%s  %d" % [CombatTypes.role_short(role), count]
		var tint: Color = CombatTypes.stats_for(role)["tint"]
		chip["panel"].add_theme_stylebox_override(
			"panel",
			_flat(tint.darkened(0.55) if not selected else tint.darkened(0.15), selected)
		)


func _make_chip(_role: int) -> Dictionary:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(CHIP_MIN_WIDTH, 30)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_roster_box.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(margin)

	var label := _make_label("", 14, Color(1, 1, 1))
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	margin.add_child(label)

	return {"panel": panel, "label": label}


# ---------------------------------------------------------------------------
# Readouts
# ---------------------------------------------------------------------------

func _refresh_health() -> void:
	if not is_instance_valid(commander) or _health_bar == null:
		return
	_health_bar.max_value = commander.max_health
	_health_bar.value = commander.health


func _refresh_score() -> void:
	if _score_label == null:
		return
	_score_label.text = "Legion %d    Slain %d    Lost %d" % [
		Battle.count(CombatTypes.Faction.PLAYER),
		Battle.player_kills,
		Battle.losses,
	]


func _on_objectives_changed(captured: int, total: int) -> void:
	if _objective_label:
		_objective_label.text = "Camps %d / %d" % [captured, total]


func _on_held_changed(unit: Follower) -> void:
	if _held_label == null:
		return
	if unit == null:
		_held_label.text = ""
	else:
		_held_label.text = "holding %s" % CombatTypes.role_name(unit.role)


# ---------------------------------------------------------------------------
# Killfeed
# ---------------------------------------------------------------------------

func _on_battle_event(text: String, color: Color) -> void:
	if _feed == null:
		return
	var line := _make_label(text, 14, color)
	line.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_feed.add_child(line)
	while _feed.get_child_count() > 6:
		var oldest := _feed.get_child(0)
		_feed.remove_child(oldest)
		oldest.queue_free()

	var tween := create_tween()
	tween.tween_interval(2.6)
	tween.tween_property(line, "modulate:a", 0.0, 0.7)
	tween.tween_callback(line.queue_free)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _make_label(body: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = body
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func _flat(color: Color, outlined: bool = false) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.corner_radius_top_left = 4
	sb.corner_radius_top_right = 4
	sb.corner_radius_bottom_left = 4
	sb.corner_radius_bottom_right = 4
	if outlined:
		sb.border_width_bottom = 2
		sb.border_width_top = 2
		sb.border_width_left = 2
		sb.border_width_right = 2
		sb.border_color = Color(1, 1, 1, 0.85)
	return sb
