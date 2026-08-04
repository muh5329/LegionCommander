## Arrows and javelins. Built in code (mesh + Area3D) so archers work without
## any extra scene files, and homes gently towards where the target *was* when
## it was loosed, so volleys arc across the field instead of snapping to hits.
class_name Projectile
extends Area3D

const SPEED := 26.0
const LIFETIME := 3.5
const ARC := 0.16   ## Fraction of travel time spent above the straight line.

var damage: float = 12.0
var owner_faction: int = CombatTypes.Faction.NEUTRAL
var shooter: Node = null

var _velocity: Vector3 = Vector3.ZERO
var _life: float = 0.0
var _spent: bool = false


static func spawn(
	host: Node,
	from: Vector3,
	target: Node3D,
	damage_amount: float,
	faction: int,
	shooter_unit: Node = null
) -> Projectile:
	if host == null or not is_instance_valid(target):
		return null

	# Configure before entering the tree - _ready() derives its collision mask
	# from owner_faction.
	var p := Projectile.new()
	p.damage = damage_amount
	p.owner_faction = faction
	p.shooter = shooter_unit
	p.position = from
	host.add_child(p)

	# Lead the target a little so moving units are not free hits.
	var aim := target.global_position + Vector3.UP * 0.9
	if target is CharacterBody3D:
		var flight := from.distance_to(aim) / SPEED
		aim += (target as CharacterBody3D).velocity * flight * 0.55

	var to_target := aim - from
	var flat_dist := Vector2(to_target.x, to_target.z).length()
	var dir := to_target.normalized()
	p._velocity = dir * SPEED
	# Add a touch of loft proportional to range.
	p._velocity.y += flat_dist * ARC
	p.look_at_direction()
	return p


func _ready() -> void:
	monitoring = true
	monitorable = false
	collision_layer = 0
	collision_mask = 0
	set_collision_layer_value(CombatTypes.LAYER_PROJECTILE, true)
	# Only look for the other army; friendly fire would wreck a 40-unit charge.
	var target_layer := CombatTypes.layer_for(CombatTypes.opposing(owner_faction))
	set_collision_mask_value(target_layer, true)
	set_collision_mask_value(CombatTypes.LAYER_WORLD, true)

	_build_visual()
	body_entered.connect(_on_body_entered)


func _build_visual() -> void:
	var shaft := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.018
	cyl.bottom_radius = 0.018
	cyl.height = 0.62
	cyl.radial_segments = 5
	shaft.mesh = cyl
	shaft.rotation_degrees.x = 90.0

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.38, 0.27, 0.16)
	mat.emission_enabled = true
	mat.emission = CombatTypes.FACTION_COLORS.get(owner_faction, Color.WHITE)
	mat.emission_energy_multiplier = 0.4
	shaft.material_override = mat
	add_child(shaft)

	var head := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.05
	cone.height = 0.16
	cone.radial_segments = 5
	head.mesh = cone
	head.material_override = mat
	head.rotation_degrees.x = 90.0
	head.position.z = -0.36
	add_child(head)

	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.28
	shape.shape = sphere
	add_child(shape)


func _physics_process(delta: float) -> void:
	if _spent:
		return
	_life += delta
	if _life > LIFETIME:
		_expire()
		return

	_velocity.y -= 9.8 * delta * 0.55
	global_position += _velocity * delta
	look_at_direction()

	# Bury it when it hits the dirt.
	if global_position.y < -2.0:
		_expire()


func look_at_direction() -> void:
	if _velocity.length_squared() < 0.01:
		return
	var forward := _velocity.normalized()
	if absf(forward.dot(Vector3.UP)) > 0.985:
		return
	look_at(global_position + forward, Vector3.UP)


func _on_body_entered(body: Node3D) -> void:
	if _spent:
		return
	if body == shooter:
		return
	var target_faction = body.get("faction")
	var is_valid_target := body.has_method("take_damage") and target_faction != null
	if is_valid_target and CombatTypes.is_hostile(owner_faction, int(target_faction)):
		var knock := _velocity.normalized() * 1.6
		body.take_damage(damage, shooter, knock)
		_expire()
	elif not (body is CharacterBody3D):
		# Terrain / props: stick briefly, then fade.
		_expire()


func _expire() -> void:
	if _spent:
		return
	_spent = true
	set_physics_process(false)
	monitoring = false
	var tween := create_tween()
	tween.tween_interval(0.25)
	tween.tween_callback(queue_free)
