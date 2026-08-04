## Barbarian raider - the goblin warband unit.
##
## Rebuilt on top of Combatant so it shares damage, blocking, knockback and
## death with every other soldier on the field. Behaviour is a small state
## machine: hold a post, notice trouble, chase it, hit it, then drift home.
class_name Enemy
extends Combatant

signal state_changed(unit: Enemy, new_state: int)

enum EnemyState {
	GUARD,    ## Standing at its post, scanning.
	PATROL,   ## Walking a short beat around the post.
	PURSUE,   ## Closing on a target.
	ATTACK,   ## In reach.
	RALLY,    ## Following a captain's advance order.
	DEAD,
}

## Kept so any old scene data referencing these still resolves.
const simple_attacks := {
	"slice": "CharacterArmature|SwordSlash",
	"spin": "2H_Melee_Attack_Spin",
	"range": "1H_Melee_Attack_Stab",
}

# ---------------------------------------------------------------------------
# Tuning
# ---------------------------------------------------------------------------
@export_group("Behaviour")
@export var notice_radius: float = 11.0
## Won't chase further than this from its post / captain.
@export var leash_radius: float = 22.0
@export var patrol_radius: float = 5.0
@export var patrol_pause: Vector2 = Vector2(1.5, 4.0)
## Raiders that see a friend die nearby pile in.
@export var help_call_radius: float = 9.0

@export_group("Legacy")
@export var walk_speed: float = 2.0
@export var attack_radius: float = 1.0
@export var target_desired_distance: float = 0.1

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
var state: int = EnemyState.GUARD
var post_position: Vector3 = Vector3.ZERO
var captain: Node3D = null
var rally_point: Vector3 = Vector3.ZERO
var has_rally_point: bool = false
var target_position: Vector3 = Vector3.ZERO

var _nav: NavigationAgent3D = null
var _scan_timer: float = 0.0
var _nav_timer: float = 0.0
var _patrol_target: Vector3 = Vector3.ZERO
var _patrol_timer: float = 0.0


static func create(scene: PackedScene, unit_role: int, tier: float = 1.0) -> Enemy:
	var unit := scene.instantiate() as Enemy
	if unit == null:
		return null
	unit.faction = CombatTypes.Faction.ENEMY
	unit.role = unit_role
	unit.set_meta("tier", tier)
	return unit


func _ready() -> void:
	_scan_timer = randf() * 0.3
	_nav_timer = randf() * 0.35
	_patrol_timer = randf_range(patrol_pause.x, patrol_pause.y)

	faction = CombatTypes.Faction.ENEMY
	if has_meta("tier"):
		use_role_stats = false
		apply_role_stats(role, float(get_meta("tier")))

	super._ready()

	_nav = get_node_or_null("NavigationAgent3D") as NavigationAgent3D
	if _nav:
		_nav.path_desired_distance = 0.7
		_nav.target_desired_distance = 0.7
		_nav.max_speed = move_speed
		_nav.radius = 0.4
		_nav.height = 1.8
		_nav.avoidance_enabled = false
		_nav.path_max_distance = 8.0

	post_position = global_position
	_patrol_target = post_position
	died.connect(_on_died)
	damaged.connect(_on_damaged)

	# The original scene autostarts an attack timer; the state machine owns
	# attack pacing now, so silence it.
	var timer := get_node_or_null("Timers/AttackTimer")
	if timer is Timer:
		(timer as Timer).stop()


# ---------------------------------------------------------------------------
# Orders from a captain
# ---------------------------------------------------------------------------

func assign_captain(new_captain: Node3D) -> void:
	captain = new_captain


func order_rally(point: Vector3) -> void:
	rally_point = point
	has_rally_point = true
	post_position = point
	if state in [EnemyState.GUARD, EnemyState.PATROL]:
		_set_state(EnemyState.RALLY)


func clear_rally() -> void:
	has_rally_point = false
	_set_state(EnemyState.GUARD)


## Old API, still referenced by enemy.tscn's Area3D signal.
func set_target(pos: Vector3) -> void:
	target_position = pos


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if is_dead:
		return

	tick_combat(delta)
	Battle.notify_moved(self)

	match state:
		EnemyState.GUARD:
			_process_guard(delta)
		EnemyState.PATROL:
			_process_patrol(delta)
		EnemyState.PURSUE:
			_process_pursue(delta)
		EnemyState.ATTACK:
			_process_attack(delta)
		EnemyState.RALLY:
			_process_rally(delta)

	update_locomotion_anim(0.3)


func _process_guard(delta: float) -> void:
	if _scan(delta, notice_radius):
		return
	_patrol_timer -= delta
	if _patrol_timer <= 0.0 and patrol_radius > 0.1:
		var angle := randf() * TAU
		var r := randf_range(patrol_radius * 0.3, patrol_radius)
		_patrol_target = post_position + Vector3(cos(angle) * r, 0.0, sin(angle) * r)
		_set_state(EnemyState.PATROL)
	steer(Vector3.ZERO, 0.0, delta, 10.0)
	apply_gravity(delta)
	move_and_slide()


func _process_patrol(delta: float) -> void:
	if _scan(delta, notice_radius):
		return
	var to := _patrol_target - global_position
	to.y = 0.0
	if to.length() < 0.6:
		_patrol_timer = randf_range(patrol_pause.x, patrol_pause.y)
		_set_state(EnemyState.GUARD)
		return
	var dir := _steering_direction(_patrol_target, to.length())
	steer(dir, move_speed * 0.5, delta, 9.0)
	face_towards(global_position + dir, delta)
	apply_gravity(delta)
	move_and_slide()


func _process_pursue(delta: float) -> void:
	if not is_instance_valid(current_target) or current_target.get("is_dead"):
		current_target = null
		_stand_down()
		return

	var anchor := post_position
	if is_instance_valid(captain):
		anchor = captain.global_position
	if anchor.distance_to(current_target.global_position) > leash_radius:
		current_target = null
		_stand_down()
		return

	var dist := distance_to_unit(current_target)
	if dist <= attack_range:
		_set_state(EnemyState.ATTACK)
		return

	var dir := _steering_direction(current_target.global_position, dist)
	steer(dir, move_speed, delta, 13.0)
	face_towards(current_target.global_position, delta)
	apply_gravity(delta)
	move_and_slide()


func _process_attack(delta: float) -> void:
	if not is_instance_valid(current_target) or current_target.get("is_dead"):
		current_target = null
		_stand_down()
		return

	var dist := distance_to_unit(current_target)
	if dist > attack_range * 1.2:
		_set_state(EnemyState.PURSUE)
		return

	if ranged and dist < attack_range * 0.3:
		var away := (global_position - current_target.global_position).normalized()
		steer(away, move_speed * 0.75, delta, 12.0)
	else:
		steer(_separation() * 0.5, move_speed * 0.25, delta, 10.0)

	face_towards(current_target.global_position, delta)
	try_attack(current_target)
	apply_gravity(delta)
	move_and_slide()


func _process_rally(delta: float) -> void:
	if _scan(delta, notice_radius):
		return
	var goal := rally_point
	if is_instance_valid(captain):
		goal = captain.global_position
	var to := goal - global_position
	to.y = 0.0
	if to.length() < 2.5:
		post_position = global_position
		_set_state(EnemyState.GUARD)
		return
	var dir := _steering_direction(goal, to.length())
	steer(dir, move_speed, delta, 12.0)
	face_towards(global_position + dir, delta)
	apply_gravity(delta)
	move_and_slide()


# ---------------------------------------------------------------------------
# Perception
# ---------------------------------------------------------------------------

func _scan(delta: float, radius: float) -> bool:
	_scan_timer -= delta
	if _scan_timer > 0.0:
		return false
	_scan_timer = randf_range(0.25, 0.4)
	var prey := Battle.nearest_hostile(global_position, faction, radius, self)
	if prey == null:
		return false
	current_target = prey
	_set_state(EnemyState.PURSUE)
	return true


## Shout for help so a lone scout doesn't die quietly.
func call_for_help(threat: Node3D) -> void:
	if not is_instance_valid(threat):
		return
	for ally: Node3D in Battle.query(global_position, help_call_radius, faction, self):
		if ally is Enemy and (ally as Enemy).current_target == null:
			(ally as Enemy).alert_to(threat)


## Public entry point so captains and allies can point this unit at a threat.
func alert_to(threat: Node3D) -> void:
	if is_dead or not is_instance_valid(threat):
		return
	current_target = threat
	_set_state(EnemyState.PURSUE)


func _steering_direction(target_pos: Vector3, dist: float) -> Vector3:
	var dir: Vector3
	if _nav and dist > 4.0:
		_nav_timer -= get_physics_process_delta_time()
		if _nav_timer <= 0.0:
			_nav_timer = randf_range(0.3, 0.45)
			_nav.target_position = target_pos
		if not _nav.is_navigation_finished():
			dir = _nav.get_next_path_position() - global_position
		else:
			dir = target_pos - global_position
	else:
		dir = target_pos - global_position
	dir.y = 0.0
	if dir.length_squared() > 0.0001:
		dir = dir.normalized()
	var blended := dir + _separation() * 0.5
	if blended.length_squared() < 0.0001:
		return dir
	return blended.normalized()


func _separation() -> Vector3:
	var push := Vector3.ZERO
	var neighbours := Battle.query(global_position, 0.9, -1, self)
	if neighbours.is_empty():
		return push
	for other: Node3D in neighbours:
		var diff: Vector3 = global_position - other.global_position
		diff.y = 0.0
		var d := diff.length()
		if d > 0.001:
			push += diff / d * (1.0 - d / 0.9)
	return push / float(neighbours.size())


func _stand_down() -> void:
	if has_rally_point or is_instance_valid(captain):
		_set_state(EnemyState.RALLY)
	else:
		_set_state(EnemyState.GUARD)


func _set_state(new_state: int) -> void:
	if state == new_state:
		return
	state = new_state
	state_changed.emit(self, new_state)


func _on_damaged(_unit: Combatant, _amount: float, source: Node) -> void:
	if source is Node3D:
		call_for_help(source as Node3D)


func _on_died(_unit: Combatant, killer: Node) -> void:
	state = EnemyState.DEAD
	if is_instance_valid(captain) and captain.has_method("report_casualty"):
		captain.report_casualty(self)
	# Dying is a signal to everyone nearby that there is a fight on.
	if killer is Node3D:
		call_for_help(killer as Node3D)


# ---------------------------------------------------------------------------
# Compatibility shims for the signals wired inside enemy.tscn
# ---------------------------------------------------------------------------

func _on_attack_timer_timeout() -> void:
	pass


func _on_area_3d_body_entered(body: Node3D) -> void:
	if body is Combatant and CombatTypes.is_hostile(faction, int(body.get("faction"))):
		if current_target == null:
			alert_to(body)


func _on_area_3d_body_exited(_body: Node3D) -> void:
	pass


func attack_logic() -> void:
	pass


func melee_attack_animation() -> void:
	play_attack_animation()


func update_hp(value: int) -> void:
	health = float(value)


func stop_movement(start_duration: float, end_duration: float) -> void:
	var restore: float = float(CombatTypes.stats_for(role)["speed"])
	var tween := create_tween()
	tween.tween_property(self, "move_speed", 0.0, start_duration)
	tween.tween_property(self, "move_speed", restore, end_duration)


func state_name() -> String:
	return EnemyState.keys()[state]
