## Root of the Battlefield level.
##
## Generates the world, drops the commander and camera into it, seeds the map
## with enemy camps and recruit pods, and translates raw input into commands.
class_name BattleManager
extends Node3D

signal battle_won()
signal battle_lost()

@export_group("Scenes")
@export var commander_scene: PackedScene = preload("res://scenes/entities/character/soldier.tscn")
@export var camera_scene: PackedScene = preload("res://scenes/entities/camera/battle_camera.tscn")

@export_group("World")
@export var world_seed: int = 0        ## 0 picks a random seed each run.
@export var map_size: float = 200.0
@export var pods_per_region: int = 2

@export_group("Lighting")
@export var sun_angle: float = 48.0
@export var sky_horizon: Color = Color(0.62, 0.68, 0.75)
@export var sky_top: Color = Color(0.30, 0.44, 0.66)

var generator: WorldGenerator = null
var commander: Character = null
var camera: BattleCamera = null
var gizmos: CommandGizmos = null
var world_info: Dictionary = {}
var camps: Array[EnemyCamp] = []

var _throw_held: bool = false
var _finished: bool = false


func _ready() -> void:
	Battle.reset()
	randomize()
	_build_environment()
	_build_world()
	_spawn_commander()
	_spawn_camera()
	_populate_objectives()
	_connect_ui()


# ---------------------------------------------------------------------------
# Assembly
# ---------------------------------------------------------------------------

func _build_world() -> void:
	generator = WorldGenerator.new()
	generator.name = "World"
	generator.map_size = map_size
	generator.world_seed = world_seed if world_seed != 0 else randi()
	add_child(generator)
	world_info = generator.generate()


func _spawn_commander() -> void:
	commander = commander_scene.instantiate() as Character
	if commander == null:
		push_error("BattleManager: commander scene has no Character script")
		return
	var home: Vector3 = world_info.get("home", Vector3.ZERO)
	add_child(commander)
	commander.global_position = generator.ground_point(home.x, home.z) + Vector3.UP * 0.6
	commander.respawn_point = commander.global_position
	commander.downed.connect(_on_commander_downed)

	gizmos = CommandGizmos.new()
	gizmos.name = "CommandGizmos"
	gizmos.commander = commander
	add_child(gizmos)


func _spawn_camera() -> void:
	if camera_scene != null:
		camera = camera_scene.instantiate() as BattleCamera
	if camera == null:
		# Build one from scratch so the level still runs without the scene file.
		camera = BattleCamera.new()
		camera.name = "BattleCamera"
		var cam := Camera3D.new()
		cam.name = "Camera3D"
		cam.current = true
		camera.add_child(cam)
	add_child(camera)
	camera.bounds_radius = map_size * 0.42
	camera.set_target(commander)
	if camera.camera:
		camera.camera.current = true


## Camps sit on every region except home; recruit pods fill the gaps between.
func _populate_objectives() -> void:
	var regions: Array = world_info.get("regions", [])
	var kinds := [
		EnemyCamp.CampKind.OUTPOST,
		EnemyCamp.CampKind.WARBAND,
		EnemyCamp.CampKind.RIVAL_LEGION,
		EnemyCamp.CampKind.WARBAND,
		EnemyCamp.CampKind.STRONGHOLD,
	]
	var camp_index := 0

	for i in range(regions.size()):
		var region: Dictionary = regions[i]
		if int(region["kind"]) == WorldGenerator.RegionKind.HOME:
			_seed_pods_near(region, pods_per_region + 1)
			continue

		var camp := EnemyCamp.new()
		camp.name = "Camp_%d" % i
		camp.camp_name = String(region["name"])
		camp.kind = kinds[camp_index % kinds.size()]
		camp.radius = minf(float(region["radius"]) * 0.45, 16.0)
		# Camps get harder the further they sit from home.
		camp.tier = 0.85 + float(region["dist"]) * 0.9
		camp.garrison_size = 6 + camp_index * 2
		add_child(camp)
		var centre: Vector3 = region["position"]
		camp.global_position = generator.ground_point(centre.x, centre.z)
		camp.captured.connect(_on_camp_captured)
		camps.append(camp)
		camp_index += 1

		_seed_pods_near(region, pods_per_region)


func _seed_pods_near(region: Dictionary, count: int) -> void:
	var centre: Vector3 = region["position"]
	var radius := float(region["radius"])
	var roles := CombatTypes.PLAYER_ROLES
	for i in range(count):
		var pod := LegionPod.new()
		pod.name = "Pod_%s_%d" % [String(region["name"]).replace(" ", ""), i]
		pod.role = roles[randi() % roles.size()]
		pod.unit_count = randi_range(4, 8)
		add_child(pod)

		# Push pods to the edge of a region so you have to go looking.
		var angle := randf() * TAU
		var r := radius * randf_range(0.55, 0.95)
		var x := centre.x + cos(angle) * r
		var z := centre.z + sin(angle) * r
		pod.global_position = generator.ground_point(x, z)


func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY

	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = sky_top
	sky_mat.sky_horizon_color = sky_horizon
	sky_mat.ground_bottom_color = Color(0.20, 0.22, 0.19)
	sky_mat.ground_horizon_color = sky_horizon
	sky_mat.sun_angle_max = 12.0
	sky.sky_material = sky_mat
	env.sky = sky

	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 0.75
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_white = 1.4
	env.ssao_enabled = false
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = sky_horizon
	env.fog_density = 0.0018
	env.fog_depth_begin = 60.0
	env.fog_depth_end = 320.0
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.22
	env.adjustment_contrast = 1.05

	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-sun_angle, -38.0, 0.0)
	sun.light_energy = 1.15
	sun.light_color = Color(1.0, 0.96, 0.88)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 120.0
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	add_child(sun)


func _connect_ui() -> void:
	for node in find_children("*", "Control", true, false):
		if node.has_method("bind"):
			node.bind(commander)
			return


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if commander == null or commander.is_dead:
		return

	if event.is_action_pressed(&"cmd_throw"):
		_throw_held = true
		commander.begin_throw()
		get_viewport().set_input_as_handled()
	elif event.is_action_released(&"cmd_throw"):
		_throw_held = false
		if commander.can_release():
			commander.release_throw()
		get_viewport().set_input_as_handled()

	elif event.is_action_pressed(&"cmd_whistle"):
		commander.begin_whistle()
	elif event.is_action_released(&"cmd_whistle"):
		commander.end_whistle()

	elif event.is_action_pressed(&"cmd_cycle_role"):
		commander.cycle_selected_role(1)
	elif event.is_action_pressed(&"cmd_charge"):
		commander.order_charge(_cursor_ground_point())
	elif event.is_action_pressed(&"cmd_dismiss"):
		commander.dismiss_squad()


func _process(delta: float) -> void:
	if commander == null:
		return
	_drive_commander(delta)
	if commander.is_holding():
		commander.update_throw_aim(_cursor_ground_point())


## Camera-relative WASD so "up" always means "up the screen".
func _drive_commander(_delta: float) -> void:
	if commander.is_dead:
		commander.movement_direction = Vector3.ZERO
		return

	var axis := Vector2.ZERO
	if Input.is_action_pressed(&"move_forward"):
		axis.y -= 1.0
	if Input.is_action_pressed(&"move_back"):
		axis.y += 1.0
	if Input.is_action_pressed(&"move_left"):
		axis.x -= 1.0
	if Input.is_action_pressed(&"move_right"):
		axis.x += 1.0

	if axis == Vector2.ZERO:
		commander.movement_direction = Vector3.ZERO
		return

	axis = axis.normalized()
	var yaw := camera.rotation.y if camera else 0.0
	commander.movement_direction = Basis(Vector3.UP, yaw) * Vector3(axis.x, 0.0, axis.y)


func _cursor_ground_point() -> Vector3:
	if camera:
		return camera.cursor_world_point(commander.global_position.y)
	return commander.global_position


# ---------------------------------------------------------------------------
# Objectives
# ---------------------------------------------------------------------------

func _on_camp_captured(_camp: EnemyCamp) -> void:
	if _finished:
		return
	for camp in camps:
		if is_instance_valid(camp) and not camp.is_captured:
			return
	_finished = true
	Battle.announce("The field is yours. Roma victrix!", Color(1.0, 0.9, 0.4))
	battle_won.emit()


func _on_commander_downed(_commander: Character) -> void:
	if Battle.count(CombatTypes.Faction.PLAYER) <= 1:
		Battle.announce("Legion broken - regroup at camp", Color(0.95, 0.45, 0.4))
		battle_lost.emit()
