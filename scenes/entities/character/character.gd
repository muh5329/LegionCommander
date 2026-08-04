## The Commander - the one soldier you drive directly.
##
## Pikmin's whole loop lives here: pluck a legionary out of the ranks, aim with
## the mouse, hurl him across the field, and blow the horn to gather everyone
## back in. Everything else (marching, fighting, holding ground) is the units'
## own business.
class_name Character
extends Combatant

signal squad_changed(size: int)
signal held_unit_changed(unit: Follower)
signal whistle_blown(centre: Vector3, radius: float)
signal throw_released(unit: Follower, to: Vector3)
signal downed(commander: Character)
signal revived(commander: Character)

# ---------------------------------------------------------------------------
# Legacy exports (the original state-machine scripts still read these)
# ---------------------------------------------------------------------------
@export var _speed: float = 5.4
@export var _velocity: Vector3 = Vector3.ZERO

# ---------------------------------------------------------------------------
# Command tuning
# ---------------------------------------------------------------------------
@export_group("Whistle")
## How far the horn reaches at full expansion.
@export var whistle_max_radius: float = 11.0
## Seconds for the ring to grow from nothing to max.
@export var whistle_grow_time: float = 0.75

@export_group("Throw")
@export var throw_min_range: float = 2.0
@export var throw_max_range: float = 16.0
## Peak height of the arc, as a fraction of throw distance.
@export var throw_arc_height: float = 0.42
## Seconds between throws while the button is held down.
@export var throw_repeat_delay: float = 0.28
## How long the unit sits in your hand before it can be released.
@export var pluck_time: float = 0.08

@export_group("Squad")
@export var max_squad_size: int = 100
@export var starting_squad: int = 12
## Seconds spent out of the fight after being downed.
@export var respawn_delay: float = 4.0
## Where revival puts you. The battle manager sets this to the home camp.
@export var respawn_point: Vector3 = Vector3.ZERO
@export var follower_scene: PackedScene = preload("res://scenes/entities/followers/follower.tscn")

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
var followers: Array[Follower] = []
var movement_direction: Vector3 = Vector3.ZERO
## Which role the next throw pulls from. -1 means "whoever is nearest".
var selected_role: int = -1

var held_unit: Follower = null
var is_charging_throw: bool = false
var throw_target: Vector3 = Vector3.ZERO
var throw_valid: bool = false

var whistle_active: bool = false
var whistle_radius: float = 0.0

var _path: PackedVector3Array = PackedVector3Array()
var _throw_cooldown: float = 0.0
var _pluck_timer: float = 0.0
var _whistled: Dictionary = {}

@onready var _anim: AnimationTree = get_node_or_null("AnimationTree")


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	# The commander is hand-tuned, not role-driven.
	use_role_stats = false
	faction = CombatTypes.Faction.PLAYER
	role = CombatTypes.UnitRole.CENTURION
	max_health = 500.0
	attack_damage = 24.0
	attack_range = 2.1
	attack_interval = 0.85
	block_chance = 0.2
	knockback_resist = 0.8
	move_speed = _speed

	super._ready()

	if _anim:
		_anim.active = true
	add_to_group("player")
	add_to_group("commander")
	Global.player = self

	if starting_squad > 0:
		call_deferred("_spawn_starting_squad")


func _spawn_starting_squad() -> void:
	var mix := [
		CombatTypes.UnitRole.LEGIONARY,
		CombatTypes.UnitRole.LEGIONARY,
		CombatTypes.UnitRole.LEGIONARY,
		CombatTypes.UnitRole.HASTATUS,
		CombatTypes.UnitRole.SAGITTARIUS,
		CombatTypes.UnitRole.VELES,
	]
	for i in range(starting_squad):
		var angle := TAU * float(i) / float(starting_squad)
		var spot := global_position + Vector3(cos(angle), 0.0, sin(angle)) * randf_range(1.2, 2.6)
		spawn_follower(spot, mix[i % mix.size()])


# ---------------------------------------------------------------------------
# Squad roster
# ---------------------------------------------------------------------------

func add_follower(unit: Follower) -> void:
	if unit == null or unit.is_dead or unit in followers:
		return
	if followers.size() >= max_squad_size:
		return
	followers.append(unit)
	unit.join_squad(self, followers.size() - 1)
	squad_changed.emit(followers.size())


func remove_follower(unit: Follower) -> void:
	var index := followers.find(unit)
	if index == -1:
		return
	followers.remove_at(index)
	if is_instance_valid(unit) and unit.leader == self:
		unit.leader = null
	_reindex()
	squad_changed.emit(followers.size())


func _reindex() -> void:
	for i in range(followers.size()):
		if is_instance_valid(followers[i]):
			followers[i].formation_index = i


## Drop the whole squad where they stand. They'll hold ground until whistled.
func dismiss_squad() -> void:
	var dropped := 0
	for unit in followers.duplicate():
		if is_instance_valid(unit):
			unit.leader = null
			unit.post_at(unit.global_position)
			dropped += 1
	followers.clear()
	squad_changed.emit(0)
	if dropped > 0:
		Battle.announce("Legion dismissed - hold the line!", Color(0.95, 0.8, 0.4))


func spawn_follower(at: Vector3, unit_role: int = CombatTypes.UnitRole.LEGIONARY) -> Follower:
	if follower_scene == null:
		return null
	var unit := Follower.create(follower_scene, CombatTypes.Faction.PLAYER, unit_role)
	if unit == null:
		return null
	unit.scale = Vector3(0.34, 0.34, 0.34)
	get_parent().add_child(unit)
	unit.global_position = Vector3(at.x, global_position.y, at.z)
	add_follower(unit)
	return unit


## Roster grouped by role, for the HUD.
func squad_breakdown() -> Dictionary:
	var out := {}
	for unit in followers:
		if is_instance_valid(unit) and not unit.is_dead:
			out[unit.role] = int(out.get(unit.role, 0)) + 1
	return out


func squad_size() -> int:
	return followers.size()


# ---------------------------------------------------------------------------
# Whistle
# ---------------------------------------------------------------------------

func begin_whistle() -> void:
	if whistle_active:
		return
	whistle_active = true
	whistle_radius = 1.0
	_whistled.clear()


func end_whistle() -> void:
	whistle_active = false
	whistle_radius = 0.0
	_whistled.clear()


func _tick_whistle(delta: float) -> void:
	if not whistle_active:
		return
	var growth := whistle_max_radius / maxf(whistle_grow_time, 0.05)
	whistle_radius = minf(whistle_radius + growth * delta, whistle_max_radius)
	whistle_blown.emit(global_position, whistle_radius)

	# Sweep everything inside the ring once - loose recruits and stragglers both.
	for unit: Node3D in Battle.query(global_position, whistle_radius, -1, self):
		if _whistled.has(unit) or not (unit is Follower):
			continue
		_whistled[unit] = true
		if followers.size() >= max_squad_size:
			continue
		(unit as Follower).respond_to_whistle(self)


# ---------------------------------------------------------------------------
# Pick up / aim / throw
# ---------------------------------------------------------------------------

## Pluck the best candidate for the currently selected role.
func begin_throw() -> void:
	if is_charging_throw or held_unit != null:
		return
	var candidate := _pick_throw_candidate()
	if candidate == null:
		return
	is_charging_throw = true
	held_unit = candidate
	_pluck_timer = pluck_time
	remove_follower(candidate)
	candidate.pick_up(self)
	held_unit_changed.emit(candidate)


## Aim point in world space, clamped to throw range. Call each frame while held.
func update_throw_aim(world_point: Vector3) -> void:
	var flat := Vector3(world_point.x - global_position.x, 0.0, world_point.z - global_position.z)
	var dist := flat.length()
	throw_valid = dist > 0.2
	if dist > throw_max_range:
		flat = flat.normalized() * throw_max_range
	elif dist < throw_min_range and dist > 0.01:
		flat = flat.normalized() * throw_min_range
	throw_target = global_position + flat
	throw_target.y = world_point.y


## Release. Returns the unit that was thrown, or null.
func release_throw() -> Follower:
	if held_unit == null:
		is_charging_throw = false
		return null
	var unit := held_unit
	held_unit = null
	is_charging_throw = false
	held_unit_changed.emit(null)

	if not throw_valid:
		# Fumbled the aim: set him back on his feet and into the ranks.
		unit.put_down()
		add_follower(unit)
		return unit

	unit.launch(_ballistic_velocity(unit.global_position, throw_target))
	_throw_cooldown = throw_repeat_delay
	face_towards(throw_target, 1.0)
	play_named_animation(["Interact", "Wave", "idle"])
	throw_released.emit(unit, throw_target)
	return unit


## Solve for the launch velocity that lands a unit on `to` with a pleasing arc.
func _ballistic_velocity(from: Vector3, to: Vector3) -> Vector3:
	var g: float = maxf(gravity, 0.1)
	var delta := to - from
	var flat := Vector3(delta.x, 0.0, delta.z)
	var dist: float = maxf(flat.length(), 0.001)

	# Apex scales with distance so short lobs stay low and snappy.
	var peak: float = maxf(dist * throw_arc_height, 1.4) + maxf(delta.y, 0.0)
	var up_speed: float = sqrt(2.0 * g * peak)
	var time_up: float = up_speed / g
	var time_down: float = sqrt(2.0 * maxf(peak - delta.y, 0.05) / g)
	var flight: float = maxf(time_up + time_down, 0.15)

	var out := flat / flight
	out.y = up_speed
	return out


## Sampled preview of the aiming arc, in world space.
func throw_arc_points(samples: int = 18) -> PackedVector3Array:
	var pts := PackedVector3Array()
	if held_unit == null:
		return pts
	var origin := global_position + Vector3.UP * 1.5
	var v := _ballistic_velocity(origin, throw_target)
	var g: float = maxf(gravity, 0.1)
	var disc: float = maxf(v.y * v.y + 2.0 * g * (origin.y - throw_target.y), 0.0)
	var total: float = maxf((v.y + sqrt(disc)) / g, 0.1)
	for i in range(samples + 1):
		var t := total * float(i) / float(samples)
		pts.append(origin + v * t + Vector3.DOWN * (0.5 * g * t * t))
	return pts


## Chooses who gets thrown: matching role first, then anyone, nearest wins.
func _pick_throw_candidate() -> Follower:
	var best: Follower = null
	var best_d := INF
	var fallback: Follower = null
	var fallback_d := INF
	for unit in followers:
		if not is_instance_valid(unit) or unit.is_dead:
			continue
		if unit.state == Follower.UnitState.HELD or unit.state == Follower.UnitState.THROWN:
			continue
		var d := global_position.distance_squared_to(unit.global_position)
		if selected_role >= 0 and unit.role == selected_role:
			if d < best_d:
				best_d = d
				best = unit
		elif d < fallback_d:
			fallback_d = d
			fallback = unit
	return best if best != null else fallback


func cycle_selected_role(step: int = 1) -> void:
	if selected_role < 0:
		selected_role = CombatTypes.PLAYER_ROLES[0]
	else:
		selected_role = CombatTypes.next_player_role(selected_role, step)


# ---------------------------------------------------------------------------
# Orders
# ---------------------------------------------------------------------------

## Send everyone at a point. They fight whatever they meet on the way.
func order_charge(target_point: Vector3) -> void:
	var count := 0
	for unit in followers:
		if not is_instance_valid(unit) or unit.is_dead:
			continue
		var spread := Vector3(randf_range(-2.0, 2.0), 0.0, randf_range(-2.0, 2.0))
		unit.leader = null
		unit.post_at(target_point + spread)
		count += 1
	if count > 0:
		followers.clear()
		squad_changed.emit(0)
		Battle.announce("Charge! %d advance" % count, CombatTypes.FACTION_COLORS[CombatTypes.Faction.PLAYER])


## Old click-to-move API - a nav path the legacy state machine walks.
func move(path: PackedVector3Array) -> void:
	_path = path


# ---------------------------------------------------------------------------
# Movement
# ---------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	tick_combat(delta)
	Battle.notify_moved(self)

	if _throw_cooldown > 0.0:
		_throw_cooldown -= delta
	if _pluck_timer > 0.0:
		_pluck_timer -= delta

	_tick_whistle(delta)

	if is_instance_valid(held_unit):
		held_unit.track_holder(self, delta)

	if is_dead:
		return

	if movement_direction.length_squared() > 0.001:
		steer(movement_direction, move_speed, delta, 16.0)
		face_towards(global_position + movement_direction, delta)
	elif _path.size() > 0:
		_follow_path(delta)
	else:
		steer(Vector3.ZERO, 0.0, delta, 14.0)

	apply_gravity(delta)
	move_and_slide()
	_velocity = velocity


func _follow_path(delta: float) -> void:
	var target: Vector3 = _path[0]
	var to := Vector3(target.x - global_position.x, 0.0, target.z - global_position.z)
	if to.length() < 0.35:
		_path.remove_at(0)
		return
	var dir := to.normalized()
	steer(dir, move_speed, delta, 16.0)
	face_towards(global_position + dir, delta)


# ---------------------------------------------------------------------------
# Death & revival
# ---------------------------------------------------------------------------

## The commander never actually dies - he's carried back to camp. Losing him
## costs you your whole squad, which is punishment enough.
func die(killer: Node = null) -> void:
	if is_dead:
		return
	is_dead = true
	current_target = null
	velocity = Vector3.ZERO
	movement_direction = Vector3.ZERO
	end_whistle()

	if is_instance_valid(held_unit):
		held_unit.set_collision_layer_value(CombatTypes.layer_for(held_unit.faction), true)
		held_unit.post_at(held_unit.global_position)
		held_unit = null
		held_unit_changed.emit(null)

	dismiss_squad()
	set_collision_layer_value(CombatTypes.LAYER_ALLY, false)
	visible = false
	Battle.announce("The commander has fallen back!", Color(0.95, 0.4, 0.35))
	died.emit(self, killer)
	downed.emit(self)
	get_tree().create_timer(respawn_delay, false).timeout.connect(revive, CONNECT_ONE_SHOT)


func revive() -> void:
	if not is_dead:
		return
	is_dead = false
	health = max_health
	visible = true
	set_collision_layer_value(CombatTypes.LAYER_ALLY, true)
	global_position = respawn_point + Vector3.UP * 0.5
	velocity = Vector3.ZERO
	Battle.announce("Commander back in the field", Color(0.6, 0.95, 0.7))
	revived.emit(self)


# ---------------------------------------------------------------------------
# HUD queries
# ---------------------------------------------------------------------------

func can_throw() -> bool:
	return _throw_cooldown <= 0.0 and not followers.is_empty()


func is_holding() -> bool:
	return held_unit != null


func can_release() -> bool:
	return held_unit != null and _pluck_timer <= 0.0
