## An enemy camp: the map's objectives.
##
## Each camp spawns a captain plus a mixed garrison, trickles in reinforcements
## while it stands, and flips to yours once the garrison is wiped. Capturing a
## camp turns its banner and gives you a forward respawn for recruits.
class_name EnemyCamp
extends Node3D

signal captured(camp: EnemyCamp)
signal garrison_changed(camp: EnemyCamp, remaining: int)

enum CampKind {
	OUTPOST,      ## Small, a warm-up.
	WARBAND,      ## Goblin raiders, aggressive, no discipline.
	RIVAL_LEGION, ## Drilled soldiers in formation behind a captain.
	STRONGHOLD,   ## The big one.
}

@export var camp_name: String = "Outpost"
@export var kind: CampKind = CampKind.OUTPOST
@export var radius: float = 12.0
## Difficulty multiplier applied to every unit's stats.
@export var tier: float = 1.0

@export_group("Garrison")
@export var garrison_size: int = 8
@export var spawn_captain: bool = true
## Extra soldiers trickle in while the camp stands, up to garrison_size.
@export var reinforce_interval: float = 14.0
@export var reinforce_batch: int = 2

@export_group("Scenes")
@export var legionary_scene: PackedScene = preload("res://scenes/entities/followers/follower.tscn")
@export var raider_scene: PackedScene = preload("res://scenes/entities/enemies/enemy.tscn")
@export var legion_captain_scene: PackedScene = preload("res://scenes/entities/enemies/legion_captain.tscn")
@export var chieftain_scene: PackedScene = preload("res://scenes/entities/enemies/raider_chieftain.tscn")

var garrison: Array[Combatant] = []
var captain: EnemyCaptain = null
var is_captured: bool = false

var _reinforce_timer: float = 0.0
var _spawned_total: int = 0
var _banner: Node3D = null


func _ready() -> void:
	add_to_group(CombatTypes.GROUP_CAMPS)
	_reinforce_timer = reinforce_interval
	Battle.register_camp()
	_build_banner()
	call_deferred("_populate")


# ---------------------------------------------------------------------------
# Population
# ---------------------------------------------------------------------------

func _populate() -> void:
	if spawn_captain:
		_spawn_captain()
	for i in range(garrison_size):
		_spawn_soldier(i)
	garrison_changed.emit(self, garrison.size())


func _spawn_captain() -> void:
	# Drilled legions get a knight officer; warbands get a goblin chieftain.
	var scene := chieftain_scene
	if kind == CampKind.RIVAL_LEGION or kind == CampKind.STRONGHOLD:
		scene = legion_captain_scene
	if scene == null:
		return

	captain = scene.instantiate() as EnemyCaptain
	if captain == null:
		return
	captain.faction = CombatTypes.Faction.ENEMY
	captain.role = CombatTypes.UnitRole.CENTURION
	captain.set_meta("tier", tier)
	captain.camp = self
	captain.territory_radius = radius * 2.4
	captain.awareness_radius = radius * 2.8
	captain.scale = Vector3(0.42, 0.42, 0.42)

	add_child(captain)
	captain.global_position = global_position + Vector3(0.0, 0.0, -1.5)
	captain.home_position = captain.global_position
	captain.squad_wiped.connect(_on_squad_wiped)
	captain.died.connect(_on_captain_died_signal)


func _spawn_soldier(index: int) -> void:
	var mix := _role_mix()
	var unit_role: int = mix[index % mix.size()]
	var use_legionary := unit_role != CombatTypes.UnitRole.BARBARIAN
	var scene := legionary_scene if use_legionary else raider_scene
	if scene == null:
		return

	var unit: Combatant = null
	if use_legionary:
		var f := Follower.create(scene, CombatTypes.Faction.ENEMY, unit_role, tier)
		if f:
			f.scale = Vector3(0.34, 0.34, 0.34)
			# Enemy legionaries hold their camp rather than trailing the player.
			f.march_engage_radius = 7.0
			f.pursue_leash = radius * 2.0
		unit = f
	else:
		var e := Enemy.create(scene, unit_role, tier)
		if e:
			e.scale = Vector3(0.39, 0.39, 0.39)
			e.notice_radius = radius * 1.1
			e.leash_radius = radius * 2.2
			e.patrol_radius = radius * 0.55
		unit = e

	if unit == null:
		return

	var angle := TAU * float(_spawned_total) * 0.618   # golden-angle scatter
	var r := radius * sqrt(randf()) * 0.75
	add_child(unit)
	unit.global_position = global_position + Vector3(cos(angle) * r, 0.5, sin(angle) * r)
	_spawned_total += 1

	garrison.append(unit)
	unit.died.connect(_on_garrison_died.bind(unit), CONNECT_ONE_SHOT)
	if captain != null:
		captain.enlist(unit)


func _role_mix() -> Array:
	match kind:
		CampKind.WARBAND:
			return [
				CombatTypes.UnitRole.BARBARIAN,
				CombatTypes.UnitRole.BARBARIAN,
				CombatTypes.UnitRole.BARBARIAN,
				CombatTypes.UnitRole.VELES,
			]
		CampKind.RIVAL_LEGION:
			return [
				CombatTypes.UnitRole.LEGIONARY,
				CombatTypes.UnitRole.LEGIONARY,
				CombatTypes.UnitRole.HASTATUS,
				CombatTypes.UnitRole.SAGITTARIUS,
			]
		CampKind.STRONGHOLD:
			return [
				CombatTypes.UnitRole.LEGIONARY,
				CombatTypes.UnitRole.HASTATUS,
				CombatTypes.UnitRole.BARBARIAN,
				CombatTypes.UnitRole.SAGITTARIUS,
				CombatTypes.UnitRole.LEGIONARY,
				CombatTypes.UnitRole.VELES,
			]
		_:
			return [
				CombatTypes.UnitRole.BARBARIAN,
				CombatTypes.UnitRole.LEGIONARY,
			]


# ---------------------------------------------------------------------------
# Reinforcement & capture
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	if is_captured:
		return
	if reinforce_interval <= 0.0:
		return
	_reinforce_timer -= delta
	if _reinforce_timer > 0.0:
		return
	_reinforce_timer = reinforce_interval
	# Only reinforce when nobody friendly to the player is standing in the camp.
	if Battle.query(global_position, radius, CombatTypes.Faction.PLAYER).size() > 0:
		return
	var deficit := garrison_size - _living_garrison()
	for i in range(mini(reinforce_batch, deficit)):
		_spawn_soldier(_spawned_total)
	if deficit > 0:
		garrison_changed.emit(self, _living_garrison())


func _living_garrison() -> int:
	var n := 0
	for unit in garrison:
		if is_instance_valid(unit) and not unit.is_dead:
			n += 1
	return n


func _on_garrison_died(_u: Combatant, _k: Node, unit: Combatant) -> void:
	garrison.erase(unit)
	garrison_changed.emit(self, _living_garrison())
	_check_capture()


func _on_squad_wiped(_captain: EnemyCaptain) -> void:
	_check_capture()


func _on_captain_died_signal(_u: Combatant, _k: Node) -> void:
	_check_capture()


func on_captain_died() -> void:
	_check_capture()


func _check_capture() -> void:
	if is_captured:
		return
	if _living_garrison() > 0:
		return
	if is_instance_valid(captain) and not captain.is_dead:
		return
	_capture()


func _capture() -> void:
	is_captured = true
	Battle.report_camp_captured(camp_name)
	FloatingText.announce(
		get_tree().current_scene,
		global_position + Vector3.UP * 3.0,
		"%s CAPTURED" % camp_name.to_upper(),
		Color(1.0, 0.88, 0.4)
	)
	_recolor_banner(CombatTypes.FACTION_COLORS[CombatTypes.Faction.PLAYER])
	captured.emit(self)


# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------

## A tall coloured pole so you can pick camps out from across the field.
func _build_banner() -> void:
	_banner = Node3D.new()
	add_child(_banner)

	var pole := MeshInstance3D.new()
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = 0.07
	pole_mesh.bottom_radius = 0.09
	pole_mesh.height = 5.0
	pole_mesh.radial_segments = 6
	pole.mesh = pole_mesh
	pole.position.y = 2.5
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.29, 0.21, 0.14)
	pole.material_override = wood
	_banner.add_child(pole)

	var flag := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(1.8, 1.2)
	flag.mesh = quad
	flag.position = Vector3(0.9, 4.2, 0.0)
	var cloth := StandardMaterial3D.new()
	cloth.albedo_color = CombatTypes.FACTION_COLORS[CombatTypes.Faction.ENEMY]
	cloth.cull_mode = BaseMaterial3D.CULL_DISABLED
	cloth.emission_enabled = true
	cloth.emission = cloth.albedo_color
	cloth.emission_energy_multiplier = 0.35
	flag.material_override = cloth
	flag.set_meta("cloth", true)
	_banner.add_child(flag)

	var label := Label3D.new()
	label.text = camp_name
	label.font_size = 44
	label.pixel_size = 0.006
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = false
	label.outline_size = 8
	label.modulate = Color(0.95, 0.95, 0.92)
	label.position = Vector3(0.0, 5.6, 0.0)
	_banner.add_child(label)


func _recolor_banner(color: Color) -> void:
	if _banner == null:
		return
	for child in _banner.get_children():
		if child is MeshInstance3D and child.has_meta("cloth"):
			var mat := (child as MeshInstance3D).material_override
			if mat is StandardMaterial3D:
				(mat as StandardMaterial3D).albedo_color = color
				(mat as StandardMaterial3D).emission = color
