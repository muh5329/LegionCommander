## Rival legion officer.
##
## A captain is the mirror of your commander: it owns a squad, keeps them in
## formation, and makes the decisions its soldiers can't - when to hold the
## camp, when to advance on your legion, and when the losses are bad enough to
## fall back and regroup.
class_name EnemyCaptain
extends Combatant

signal squad_wiped(captain: EnemyCaptain)
signal posture_changed(captain: EnemyCaptain, posture: int)

enum Posture {
	HOLD,     ## Sit on the camp, let them come to us.
	ADVANCE,  ## March the squad at the player's legion.
	FIGHT,    ## Personally engaged.
	REGROUP,  ## Pull back to the camp and re-form.
}

# ---------------------------------------------------------------------------
# Tuning
# ---------------------------------------------------------------------------
@export_group("Command")
## Distance at which the captain notices the player's legion and considers moving.
@export var awareness_radius: float = 34.0
## Never wander further than this from home.
@export var territory_radius: float = 30.0
## Below this fraction of the original squad, fall back.
@export var regroup_threshold: float = 0.34
## Seconds between command re-evaluations.
@export var think_interval: float = 1.1

@export_group("Formation")
@export var follow_distance: float = 2.4
@export var ring_capacity: int = 7
@export var ring_spacing: float = 1.1

@export_group("Aura")
## Friendlies in this radius hit harder while the captain lives.
@export var inspire_radius: float = 9.0
@export var inspire_bonus: float = 0.25

var squad: Array[Combatant] = []
var home_position: Vector3 = Vector3.ZERO
var posture: int = Posture.HOLD
var camp: Node3D = null

var _initial_squad_size: int = 0
var _think_timer: float = 0.0
var _aura_timer: float = 0.0
var _march_goal: Vector3 = Vector3.ZERO


func _ready() -> void:
	faction = CombatTypes.Faction.ENEMY
	if not has_meta("tier"):
		set_meta("tier", 1.0)
	use_role_stats = false
	apply_role_stats(role, float(get_meta("tier")))
	knockback_resist = 0.85
	turn_speed = 6.0

	super._ready()

	setup_navigation()

	home_position = global_position
	_march_goal = home_position
	_think_timer = randf() * think_interval
	died.connect(_on_died)

	# Officers are visibly bigger than the rank and file.
	scale *= 1.25


# ---------------------------------------------------------------------------
# Squad management
# ---------------------------------------------------------------------------

func enlist(unit: Combatant) -> void:
	if unit == null or unit in squad:
		return
	squad.append(unit)
	if unit is Enemy:
		(unit as Enemy).assign_captain(self)
	elif unit is Follower:
		(unit as Follower).join_squad(self, squad.size() - 1)
	unit.died.connect(_on_squad_member_died.bind(unit), CONNECT_ONE_SHOT)
	_initial_squad_size = maxi(_initial_squad_size, squad.size())


func report_casualty(unit: Combatant) -> void:
	squad.erase(unit)


func _on_squad_member_died(_u: Combatant, _k: Node, unit: Combatant) -> void:
	squad.erase(unit)
	if squad.is_empty():
		squad_wiped.emit(self)


func living_squad() -> int:
	var n := 0
	for unit in squad:
		if is_instance_valid(unit) and not unit.is_dead:
			n += 1
	return n


## Slot behind the captain, same arc formation your legion uses.
func formation_slot_for(index: int) -> Vector3:
	@warning_ignore("integer_division")
	var ring := index / ring_capacity
	var slot_in_ring := index % ring_capacity
	var arc := deg_to_rad(160.0 + ring * 20.0)
	var step := arc / float(maxi(ring_capacity - 1, 1))
	var angle := -arc * 0.5 + step * slot_in_ring
	var radius := follow_distance + ring * ring_spacing
	# face_towards() aims +Z at the target, so -Z is what trails behind.
	var back: Vector3 = -global_transform.basis.z
	var right: Vector3 = global_transform.basis.x
	var slot := global_position + (back * cos(angle) + right * sin(angle)) * radius
	slot.y = global_position.y
	return slot


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if is_dead:
		return

	tick_combat(delta)
	Battle.notify_moved(self)

	_think_timer -= delta
	if _think_timer <= 0.0:
		_think_timer = think_interval * randf_range(0.85, 1.2)
		_reconsider()

	_tick_aura(delta)

	match posture:
		Posture.FIGHT:
			_process_fight(delta)
		Posture.ADVANCE:
			_process_march(delta, _march_goal)
		Posture.REGROUP:
			_process_march(delta, home_position)
		_:
			_process_hold(delta)

	update_locomotion_anim(0.3)


## The captain's one real decision each beat.
func _reconsider() -> void:
	var alive := living_squad()

	# Bloodied? Pull back to the camp and let the survivors re-form on us.
	if _initial_squad_size > 0 and float(alive) / float(_initial_squad_size) < regroup_threshold:
		if home_position.distance_to(global_position) > 4.0:
			_set_posture(Posture.REGROUP)
			_broadcast_rally(home_position)
			return

	var threat := Battle.nearest_hostile(global_position, faction, awareness_radius, self)

	if threat == null:
		if posture != Posture.HOLD and home_position.distance_to(global_position) > 6.0:
			_set_posture(Posture.REGROUP)
			_broadcast_rally(home_position)
		else:
			_set_posture(Posture.HOLD)
			current_target = null
		return

	var threat_pos: Vector3 = threat.global_position
	var dist_from_home := home_position.distance_to(threat_pos)

	if distance_to_unit(threat) <= attack_range * 1.4:
		current_target = threat
		_set_posture(Posture.FIGHT)
	elif dist_from_home <= territory_radius:
		# They're in our ground. Push the whole squad onto them.
		current_target = threat
		_march_goal = threat_pos
		_set_posture(Posture.ADVANCE)
		_broadcast_rally(threat_pos)
		_alert_squad(threat)
	else:
		_set_posture(Posture.HOLD)


func _broadcast_rally(point: Vector3) -> void:
	for unit in squad:
		if is_instance_valid(unit) and not unit.is_dead and unit.has_method("order_rally"):
			var jitter := Vector3(randf_range(-2.5, 2.5), 0.0, randf_range(-2.5, 2.5))
			unit.order_rally(point + jitter)


func _alert_squad(threat: Node3D) -> void:
	for unit in squad:
		if is_instance_valid(unit) and not unit.is_dead and unit.has_method("alert_to"):
			unit.alert_to(threat)


func _set_posture(new_posture: int) -> void:
	if posture == new_posture:
		return
	posture = new_posture
	posture_changed.emit(self, new_posture)


# ---------------------------------------------------------------------------
# Behaviours
# ---------------------------------------------------------------------------

func _process_hold(delta: float) -> void:
	var to_home := home_position - global_position
	to_home.y = 0.0
	if to_home.length() > 2.0:
		var dir := navigate_towards(home_position, delta)
		face_towards(global_position + dir, delta)
		move_and_track(dir, move_speed * 0.7, delta, 10.0)
	else:
		move_and_track(separation() * 0.6, move_speed * 0.2, delta, 10.0)


func _process_march(delta: float, goal: Vector3) -> void:
	var to := goal - global_position
	to.y = 0.0
	if to.length() < 2.0:
		move_and_track(separation() * 0.6, move_speed * 0.2, delta, 10.0)
	else:
		var dir := navigate_towards(goal, delta)
		face_towards(global_position + dir, delta)
		move_and_track(dir, move_speed, delta, 11.0)


func _process_fight(delta: float) -> void:
	if not is_instance_valid(current_target) or current_target.get("is_dead"):
		current_target = null
		_set_posture(Posture.HOLD)
		return
	var dist := distance_to_unit(current_target)
	face_towards(current_target.global_position, delta)
	if dist > attack_range * 1.2:
		var dir := navigate_towards(current_target.global_position, delta)
		move_and_track(dir, move_speed, delta, 12.0)
	else:
		try_attack(current_target)
		move_and_track(separation() * 0.6, move_speed * 0.2, delta, 12.0)


# ---------------------------------------------------------------------------
# Inspiration aura
# ---------------------------------------------------------------------------

## Nearby friendlies hit harder while the officer is on his feet - which makes
## "kill the captain" a real tactic instead of a formality.
func _tick_aura(delta: float) -> void:
	_aura_timer -= delta
	if _aura_timer > 0.0:
		return
	_aura_timer = 0.6
	for unit: Node3D in Battle.query(global_position, inspire_radius, faction, self):
		if unit is Combatant:
			(unit as Combatant).damage_multiplier = 1.0 + inspire_bonus


func _clear_aura() -> void:
	for unit: Node3D in Battle.query(global_position, inspire_radius * 1.5, faction, self):
		if unit is Combatant:
			(unit as Combatant).damage_multiplier = 1.0


# ---------------------------------------------------------------------------
# Movement helper
# ---------------------------------------------------------------------------

func _on_died(_unit: Combatant, _killer: Node) -> void:
	_clear_aura()
	Battle.announce(
		"Enemy captain has fallen!",
		CombatTypes.FACTION_COLORS[CombatTypes.Faction.PLAYER]
	)
	# Leaderless soldiers lose their nerve and scatter to guard duty.
	for unit in squad:
		if is_instance_valid(unit) and unit.has_method("clear_rally"):
			unit.clear_rally()
	if is_instance_valid(camp) and camp.has_method("on_captain_died"):
		camp.on_captain_died()


func posture_name() -> String:
	return Posture.keys()[posture]
