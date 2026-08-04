## A recruit pod - the Pikmin onion, Roman edition.
##
## A dormant shield-stack in the field. Walk near it and it cracks open,
## releasing a handful of unaligned legionaries who stand around until you
## whistle them into your ranks.
class_name LegionPod
extends Node3D

signal opened(pod: LegionPod, units: Array)

@export var role: int = CombatTypes.UnitRole.LEGIONARY
@export var unit_count: int = 5
## Commander has to get this close before the pod cracks.
@export var trigger_radius: float = 6.0
@export var scatter_radius: float = 2.6
@export var follower_scene: PackedScene = preload("res://scenes/entities/followers/follower.tscn")

var is_open: bool = false

var _check_timer: float = 0.0
var _marker: Node3D = null


func _ready() -> void:
	add_to_group("legion_pods")
	_check_timer = randf() * 0.5
	_build_marker()


func _process(delta: float) -> void:
	if is_open:
		return
	_check_timer -= delta
	if _check_timer > 0.0:
		return
	_check_timer = 0.35

	# Cheap proximity test against the commander only.
	var commander: Node3D = Global.player
	if not is_instance_valid(commander):
		return
	if global_position.distance_to(commander.global_position) <= trigger_radius:
		open()


func open() -> void:
	if is_open:
		return
	is_open = true

	var spawned: Array = []
	var host := get_parent()
	for i in range(unit_count):
		var unit := Follower.create(follower_scene, CombatTypes.Faction.NEUTRAL, role)
		if unit == null:
			continue
		unit.scale = Vector3(0.34, 0.34, 0.34)
		host.add_child(unit)
		var angle := TAU * float(i) / float(unit_count) + randf() * 0.4
		var r := randf_range(scatter_radius * 0.4, scatter_radius)
		unit.global_position = global_position + Vector3(cos(angle) * r, 0.6, sin(angle) * r)
		unit.post_at(unit.global_position)
		spawned.append(unit)

	FloatingText.spawn(
		get_tree().current_scene,
		global_position + Vector3.UP * 2.2,
		"%d %s available" % [unit_count, CombatTypes.role_name(role)],
		Color(0.7, 0.95, 0.75),
		1.5,
		1.6
	)
	Battle.announce(
		"%d %s found - whistle them in" % [unit_count, CombatTypes.role_name(role)],
		Color(0.7, 0.95, 0.75)
	)
	_collapse_marker()
	opened.emit(self, spawned)


# ---------------------------------------------------------------------------
# Visual
# ---------------------------------------------------------------------------

## A short stack of shields with a glowing rim in the role's colour.
func _build_marker() -> void:
	_marker = Node3D.new()
	add_child(_marker)

	var tint: Color = CombatTypes.stats_for(role)["tint"]

	for i in range(3):
		var disc := MeshInstance3D.new()
		var mesh := CylinderMesh.new()
		mesh.top_radius = 0.62 - i * 0.08
		mesh.bottom_radius = 0.66 - i * 0.08
		mesh.height = 0.14
		mesh.radial_segments = 14
		disc.mesh = mesh
		disc.position.y = 0.1 + i * 0.16
		disc.rotation.y = randf() * TAU

		var mat := StandardMaterial3D.new()
		mat.albedo_color = tint.lerp(Color(0.45, 0.36, 0.26), 0.35)
		mat.emission_enabled = true
		mat.emission = tint
		mat.emission_energy_multiplier = 0.55
		disc.material_override = mat
		_marker.add_child(disc)

	var glow := OmniLight3D.new()
	glow.light_color = tint
	glow.light_energy = 1.4
	glow.omni_range = 5.0
	glow.position.y = 1.0
	glow.shadow_enabled = false
	_marker.add_child(glow)

	var label := Label3D.new()
	label.text = CombatTypes.role_short(role)
	label.font_size = 40
	label.pixel_size = 0.005
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.outline_size = 8
	label.modulate = tint.lightened(0.35)
	label.position.y = 1.6
	_marker.add_child(label)

	# Idle bob so the pods read as "interactable" from across the field.
	var tween := create_tween().set_loops()
	tween.tween_property(_marker, "position:y", 0.22, 1.4) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(_marker, "position:y", 0.0, 1.4) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func _collapse_marker() -> void:
	if _marker == null:
		return
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(_marker, "scale", Vector3(1.6, 0.15, 1.6), 0.35)
	tween.chain().tween_callback(_marker.queue_free)
