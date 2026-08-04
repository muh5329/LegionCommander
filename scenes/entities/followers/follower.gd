## A single soldier in a legion - yours or the enemy's.
##
## This is the Pikmin unit: it marches in formation behind its leader, can be
## picked up and hurled across the field, holds whatever ground it lands on, and
## fights anything hostile that wanders into its reach. The same script drives
## enemy legionaries; only `faction` and who it calls `leader` differ.
class_name Follower
extends Combatant

signal state_changed(unit: Follower, new_state: int)
signal recruited(unit: Follower)
signal landed(unit: Follower, at: Vector3)

enum UnitState {
	FOLLOW,   ## Marching in formation behind the leader.
	LOOSE,    ## Unaligned or abandoned - idles until whistled up.
	HELD,     ## Plucked, sitting in the commander's hand.
	THROWN,   ## Mid-flight.
	ENGAGE,   ## Closing on a target.
	ATTACK,   ## In reach, swinging.
	DEAD,
}

# ---------------------------------------------------------------------------
# Tuning
# ---------------------------------------------------------------------------
@export_group("Formation")
@export var follow_distance: float = 1.6
@export var ring_capacity: int = 8
@export var ring_spacing: float = 0.85
@export var arrival_threshold: float = 0.35

@export_group("Squad behaviour")
## Enemies inside this radius get attacked even while marching in formation.
@export var march_engage_radius: float = 5.0
## How far a unit will chase before giving up and returning to its post.
@export var pursue_leash: float = 14.0
## After landing, look this far for something to stab.
@export var landing_engage_radius: float = 4.5
## Loose units drift this far from their post while idling.
@export var idle_wander_radius: float = 2.0

@export_group("Throw")
@export var throw_spin_speed: float = 14.0
@export var landing_damage: float = 8.0
@export var landing_radius: float = 1.3

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
var state: int = UnitState.LOOSE
var leader: Node3D = null
var formation_index: int = 0
## Ground a thrown / posted unit is defending.
var hold_position: Vector3 = Vector3.ZERO
var has_hold_position: bool = false

var _scan_timer: float = 0.0
var _airtime: float = 0.0
var _wander_target: Vector3 = Vector3.ZERO
var _wander_timer: float = 0.0
var _ready_done: bool = false


# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

## Convenience spawner used by squads, camps and recruit pods.
static func create(
	scene: PackedScene,
	unit_faction: int,
	unit_role: int,
	tier: float = 1.0
) -> Follower:
	var unit := scene.instantiate() as Follower
	if unit == null:
		return null
	unit.faction = unit_faction
	unit.role = unit_role
	unit.set_meta("tier", tier)
	return unit


func _ready() -> void:
	# Stagger every unit's think timers so 200 soldiers never scan on one frame.
	_scan_timer = randf() * 0.25
	_wander_timer = randf() * 3.0

	if has_meta("tier"):
		use_role_stats = false
		apply_role_stats(role, float(get_meta("tier")))

	super._ready()

	setup_navigation()

	died.connect(_on_died)
	_ready_done = true

	if leader != null:
		_set_state(UnitState.FOLLOW)
	else:
		post_at(global_position)


# ---------------------------------------------------------------------------
# Squad membership
# ---------------------------------------------------------------------------

## Kept for compatibility with the original API.
func set_leader(new_leader: Node3D, index: int) -> void:
	join_squad(new_leader, index)


func join_squad(new_leader: Node3D, index: int = -1) -> void:
	leader = new_leader
	if index >= 0:
		formation_index = index
	has_hold_position = false
	if _ready_done and not state in [UnitState.HELD, UnitState.THROWN, UnitState.DEAD]:
		_set_state(UnitState.FOLLOW)


func leave_squad() -> void:
	leader = null
	if state == UnitState.FOLLOW:
		post_at(global_position)


## Turn into an unaligned recruit standing on the field.
func become_loose() -> void:
	leader = null
	set_faction(CombatTypes.Faction.NEUTRAL)
	post_at(global_position)


## Hold this patch of ground: idle here, fight anything that comes close.
func post_at(pos: Vector3) -> void:
	hold_position = pos
	has_hold_position = true
	_wander_target = pos
	if not state in [UnitState.HELD, UnitState.THROWN, UnitState.DEAD]:
		_set_state(UnitState.LOOSE)


## The commander blew the whistle. Returns true if this unit fell in.
func respond_to_whistle(commander: Node3D) -> bool:
	if is_dead or state in [UnitState.HELD, UnitState.THROWN]:
		return false
	if commander == null or not commander.has_method("add_follower"):
		return false
	if faction == CombatTypes.Faction.ENEMY:
		return false   # enemies don't answer your horn

	var was_neutral := faction == CombatTypes.Faction.NEUTRAL
	if was_neutral:
		set_faction(CombatTypes.Faction.PLAYER)
		recruited.emit(self)
		_spawn_floating_text("+%s" % CombatTypes.role_short(role), Color(0.6, 0.95, 0.7), 1.0)
	if leader == commander:
		return was_neutral
	commander.add_follower(self)
	current_target = null
	return true


# ---------------------------------------------------------------------------
# Pick up / throw
# ---------------------------------------------------------------------------

## Plucked out of the ranks and held overhead.
func pick_up(holder: Node3D) -> void:
	if is_dead:
		return
	_set_state(UnitState.HELD)
	current_target = null
	velocity = Vector3.ZERO
	has_hold_position = false
	set_collision_layer_value(CombatTypes.layer_for(faction), false)
	if holder:
		# Sit above the holder's head without reparenting (keeps navigation sane).
		global_position = holder.global_position + Vector3.UP * 1.5
	play_named_animation(["Jump_Idle", "Jump", "Idle"])


## Set a held unit back on its feet without throwing it.
func put_down() -> void:
	if state != UnitState.HELD:
		return
	set_collision_layer_value(CombatTypes.layer_for(faction), true)
	state = UnitState.LOOSE
	post_at(global_position)


## Called every frame while held so the unit tracks the commander's hands.
func track_holder(holder: Node3D, delta: float) -> void:
	if state != UnitState.HELD or holder == null:
		return
	var want := holder.global_position + Vector3.UP * 1.5
	global_position = global_position.lerp(want, clampf(delta * 22.0, 0.0, 1.0))
	rotation.y = holder.rotation.y


## Let fly. `launch_velocity` is a full 3D impulse in m/s.
func launch(launch_velocity: Vector3) -> void:
	if is_dead:
		return
	_set_state(UnitState.THROWN)
	set_collision_layer_value(CombatTypes.layer_for(faction), true)
	velocity = launch_velocity
	_airtime = 0.0
	play_named_animation(["Jump", "Jump_Idle", "Run"])


func _finish_throw() -> void:
	var here := global_position
	_airtime = 0.0
	landed.emit(self, here)
	_scale_punch(1.25, 0.18)

	# A soldier dropped from height hurts whatever he lands on.
	if landing_damage > 0.0:
		for unit: Node3D in Battle.query(here, landing_radius, CombatTypes.opposing(faction), self):
			if unit.has_method("take_damage"):
				var knock: Vector3 = (unit.global_position - here).normalized() * 3.0
				unit.take_damage(landing_damage, self, knock)

	# Thrown onto someone? Latch on immediately. Otherwise hold this ground.
	var prey := Battle.nearest_hostile(here, faction, landing_engage_radius, self)
	post_at(here)
	if prey:
		current_target = prey
		_set_state(UnitState.ENGAGE)


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if is_dead:
		return

	tick_combat(delta)
	Battle.notify_moved(self)

	match state:
		UnitState.HELD:
			return   # the commander drives us
		UnitState.THROWN:
			_process_thrown(delta)
		UnitState.FOLLOW:
			_process_follow(delta)
		UnitState.LOOSE:
			_process_loose(delta)
		UnitState.ENGAGE:
			_process_engage(delta)
		UnitState.ATTACK:
			_process_attack(delta)

	update_locomotion_anim(0.35)


func _process_thrown(delta: float) -> void:
	_airtime += delta
	apply_gravity(delta)
	move_and_slide()
	# Tumble through the air.
	rotate_object_local(Vector3.RIGHT, throw_spin_speed * delta)
	# Terrain dips below y = 0 in places, so only treat a genuinely long fall
	# as "missed the world"; otherwise wait for an honest floor contact.
	if _airtime > 0.12 and (is_on_floor() or global_position.y < VOID_Y * 0.5):
		rotation.x = 0.0
		rotation.z = 0.0
		if not is_on_floor():
			snap_to_ground()
		_finish_throw()


func _process_follow(delta: float) -> void:
	if not is_instance_valid(leader):
		leave_squad()
		return

	# Something worth stabbing right beside the column?
	if _scan(delta, march_engage_radius):
		return

	var slot := formation_slot()
	var to_slot := slot - global_position
	to_slot.y = 0.0
	var dist := to_slot.length()

	if dist <= arrival_threshold:
		# Face the same way the commander does so the block looks disciplined.
		var forward: Vector3 = leader.global_transform.basis.z
		face_towards(global_position + forward, delta)
		move_and_track(separation() * 0.6, move_speed * 0.25, delta, 14.0)
	else:
		var dir := navigate_towards(slot, delta)
		# Sprint a little when badly out of position so the tail keeps up.
		var speed := move_speed * (1.35 if dist > follow_distance * 3.0 else 1.0)
		face_towards(global_position + dir, delta)
		move_and_track(dir, speed, delta, 14.0)


func _process_loose(delta: float) -> void:
	if _scan(delta, aggro_radius):
		return

	_wander_timer -= delta
	if _wander_timer <= 0.0:
		_wander_timer = randf_range(2.5, 5.0)
		var origin := hold_position if has_hold_position else global_position
		var angle := randf() * TAU
		var r := randf() * idle_wander_radius
		_wander_target = origin + Vector3(cos(angle) * r, 0.0, sin(angle) * r)

	var to_target := _wander_target - global_position
	to_target.y = 0.0
	if to_target.length() > 0.4:
		var dir := navigate_towards(_wander_target, delta)
		face_towards(global_position + dir, delta)
		move_and_track(dir, move_speed * 0.45, delta, 8.0)
	else:
		move_and_track(separation() * 0.6, move_speed * 0.25, delta, 10.0)


func _process_engage(delta: float) -> void:
	if not is_instance_valid(current_target) or current_target.get("is_dead"):
		current_target = null
		_return_to_duty()
		return

	# Don't chase halfway across the map.
	var anchor := global_position
	if has_hold_position:
		anchor = hold_position
	elif is_instance_valid(leader):
		anchor = leader.global_position
	if anchor.distance_to(current_target.global_position) > pursue_leash:
		current_target = null
		_return_to_duty()
		return

	var target_pos := current_target.global_position
	var dist := distance_to_unit(current_target)

	if dist <= attack_range:
		_set_state(UnitState.ATTACK)
		return

	var dir := navigate_towards(target_pos, delta)
	face_towards(target_pos, delta)
	move_and_track(dir, move_speed, delta, 14.0)


func _process_attack(delta: float) -> void:
	if not is_instance_valid(current_target) or current_target.get("is_dead"):
		current_target = null
		_return_to_duty()
		return

	var dist := distance_to_unit(current_target)
	if dist > attack_range * 1.15:
		_set_state(UnitState.ENGAGE)
		return

	var dir := separation() * 0.6
	var speed := move_speed * 0.3
	# Archers back-pedal when something closes on them.
	if ranged and dist < attack_range * 0.35:
		dir = (global_position - current_target.global_position).normalized()
		speed = move_speed * 0.8

	face_towards(current_target.global_position, delta)
	try_attack(current_target)
	move_and_track(dir, speed, delta, 12.0)


# ---------------------------------------------------------------------------
# Perception & steering
# ---------------------------------------------------------------------------

## Throttled hostile scan. Returns true when it switched us into a fight.
func _scan(delta: float, radius: float) -> bool:
	_scan_timer -= delta
	if _scan_timer > 0.0:
		return false
	_scan_timer = randf_range(0.2, 0.35)

	if faction == CombatTypes.Faction.NEUTRAL:
		return false   # unrecruited soldiers stay out of it

	var prey := Battle.nearest_hostile(global_position, faction, radius, self)
	if prey == null:
		return false
	current_target = prey
	_set_state(UnitState.ENGAGE)
	return true


## Where this unit belongs in the leader's block: concentric arcs, trailing.
func formation_slot() -> Vector3:
	if not is_instance_valid(leader):
		return global_position

	@warning_ignore("integer_division")
	var ring := formation_index / ring_capacity
	var slot_in_ring := formation_index % ring_capacity

	# The innermost ring is a short arc; outer rings fan wider.
	var arc := deg_to_rad(150.0 + ring * 25.0)
	var step := arc / float(maxi(ring_capacity - 1, 1))
	var angle := -arc * 0.5 + step * slot_in_ring

	var radius := follow_distance + ring * ring_spacing
	# face_towards() aims +Z at the target, so +Z is forward and -Z trails.
	var back: Vector3 = -leader.global_transform.basis.z
	var right: Vector3 = leader.global_transform.basis.x

	var offset := (back * cos(angle) + right * sin(angle)) * radius
	var slot := leader.global_position + offset
	slot.y = leader.global_position.y
	return slot


func _return_to_duty() -> void:
	if is_instance_valid(leader):
		_set_state(UnitState.FOLLOW)
	else:
		_set_state(UnitState.LOOSE)


func _set_state(new_state: int) -> void:
	if state == new_state:
		return
	state = new_state
	state_changed.emit(self, new_state)


func _on_died(_unit: Combatant, _killer: Node) -> void:
	state = UnitState.DEAD
	if is_instance_valid(leader) and leader.has_method("remove_follower"):
		leader.remove_follower(self)
	leader = null


## Human-readable state, handy for debug overlays.
func state_name() -> String:
	return UnitState.keys()[state]
