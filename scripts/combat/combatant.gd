## Base class for anything that can hit or be hit.
##
## Handles health, damage, blocking, knockback, death, faction bookkeeping and
## the animation plumbing shared by legionaries, raiders, captains and the
## commander. Subclasses supply the *behaviour*; this supplies the *rules*.
class_name Combatant
extends CharacterBody3D

signal died(unit: Combatant, killer: Node)
signal damaged(unit: Combatant, amount: float, source: Node)
signal health_changed(current: float, maximum: float)
signal attack_landed(unit: Combatant, target: Node, amount: float)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
@export_enum("Player", "Enemy", "Neutral") var faction: int = CombatTypes.Faction.NEUTRAL
@export_enum("Legionary", "Hastatus", "Sagittarius", "Veles", "Centurion", "Barbarian")
var role: int = CombatTypes.UnitRole.LEGIONARY

@export_group("Stats")
## When true, _ready() overwrites the stats below with the role's stat block.
## Turn off for hand-tuned one-offs like the commander.
@export var use_role_stats: bool = true
@export var max_health: float = 100.0
@export var attack_damage: float = 12.0
@export var attack_range: float = 1.6
@export var attack_interval: float = 1.2
@export var aggro_radius: float = 8.0
@export var move_speed: float = 4.2
@export var turn_speed: float = 9.0
@export var block_chance: float = 0.0
@export var ranged: bool = false
@export var damage_multiplier: float = 1.0

@export_group("Feel")
## Imported rigs disagree about which way is forward. face_towards() aims the
## body's +Z at its target; if a unit visibly runs backwards, set this to 180
## on that unit's scene rather than changing the steering maths.
@export var facing_offset_degrees: float = 0.0
@export var knockback_resist: float = 0.0
@export var invulnerable_time: float = 0.12
@export var corpse_linger: float = 1.15
@export var show_damage_numbers: bool = true

# ---------------------------------------------------------------------------
# Runtime state
# ---------------------------------------------------------------------------
var health: float = 100.0:
	set(value):
		var clamped: float = clampf(value, 0.0, max_health)
		if is_equal_approx(clamped, health):
			return
		health = clamped
		_refresh_health_bar()
		health_changed.emit(health, max_health)

var is_dead: bool = false
var current_target: Node3D = null
var last_attacker: Node = null

var _attack_cooldown: float = 0.0
var _invuln: float = 0.0
var _knockback: Vector3 = Vector3.ZERO
var _model_root: Node3D = null
var _anim_player: AnimationPlayer = null
var _anim_tree: AnimationTree = null
var _move_playback = null
var _has_attack_oneshot: bool = false
var _base_model_scale: Vector3 = Vector3.ONE
var _flash_timer: float = 0.0
var _tinted_materials: Array[StandardMaterial3D] = []
var _needs_ground_snap: bool = true

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)

@onready var health_bar: ProgressBar = get_node_or_null("Sprite3D/SubViewport/HealthBar3D")
@onready var health_billboard: Node3D = get_node_or_null("Sprite3D")
@onready var health_viewport: SubViewport = get_node_or_null("Sprite3D/SubViewport")


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	if use_role_stats:
		apply_role_stats(role)
	health = max_health
	_discover_animation_nodes()
	_apply_collision_layers()
	_join_groups()
	_apply_faction_tint()
	if health_billboard:
		health_billboard.visible = false
	if health_viewport:
		health_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	Battle.register(self)


func _exit_tree() -> void:
	Battle.unregister(self)


## Pulls the canonical numbers for a role out of CombatTypes.
## Call before `health` is first set, or follow up with `health = max_health`.
func apply_role_stats(new_role: int, tier: float = 1.0) -> void:
	role = new_role
	var stats := CombatTypes.stats_for(new_role)
	max_health = float(stats["health"]) * tier
	attack_damage = float(stats["damage"]) * tier
	attack_range = float(stats["attack_range"])
	attack_interval = float(stats["attack_interval"])
	move_speed = float(stats["speed"])
	aggro_radius = float(stats["aggro"])
	block_chance = float(stats["block_chance"])
	ranged = bool(stats["ranged"])


## Move a unit between armies at runtime (recruiting a loose legionary).
func set_faction(new_faction: int) -> void:
	if new_faction == faction:
		return
	var old := faction
	remove_from_group(CombatTypes.group_for(old))
	faction = new_faction
	add_to_group(CombatTypes.group_for(faction))
	_apply_collision_layers()
	_apply_faction_tint()
	Battle.notify_faction_changed(self, old)


# ---------------------------------------------------------------------------
# Per-frame bookkeeping - subclasses call this from _physics_process
# ---------------------------------------------------------------------------

## Anything below this has escaped the map and gets rescued.
const VOID_Y := -60.0


func tick_combat(delta: float) -> void:
	if _needs_ground_snap:
		_needs_ground_snap = false
		snap_to_ground()
	elif global_position.y < VOID_Y:
		_recover_from_void()
	if _attack_cooldown > 0.0:
		_attack_cooldown -= delta
	if _invuln > 0.0:
		_invuln -= delta
	if _flash_timer > 0.0:
		_flash_timer -= delta
		if _flash_timer <= 0.0:
			_set_flash(0.0)
		else:
			_set_flash(clampf(_flash_timer / 0.14, 0.0, 1.0))
	# Knockback decays fast so it reads as a shove, not a slide.
	if _knockback.length_squared() > 0.01:
		_knockback = _knockback.lerp(Vector3.ZERO, clampf(delta * 8.0, 0.0, 1.0))
	else:
		_knockback = Vector3.ZERO
	if is_instance_valid(current_target) and current_target.get("is_dead"):
		current_target = null


## Drops the unit onto whatever solid ground is beneath it.
##
## Spawners place units by (x, z) and guess a height; on rolling terrain that
## guess can land them inside a hill, and a concave collision shape lets
## anything that starts underneath it fall through. Casting once on the first
## physics tick removes that whole class of bug.
func snap_to_ground(search_up: float = 25.0, search_down: float = 60.0) -> void:
	var space := get_world_3d().direct_space_state
	if space == null:
		return
	var query := PhysicsRayQueryParameters3D.create(
		global_position + Vector3.UP * search_up,
		global_position + Vector3.DOWN * search_down
	)
	query.collision_mask = 1 << (CombatTypes.LAYER_WORLD - 1)
	query.exclude = [get_rid()]
	var hit := space.intersect_ray(query)
	if hit.has("position"):
		var point: Vector3 = hit["position"]
		global_position = Vector3(global_position.x, point.y + 0.1, global_position.z)
		velocity.y = 0.0


## Last-resort rescue for a unit that has fallen out of the world: put it back
## on solid ground near whoever it was following, or at the origin.
func _recover_from_void() -> void:
	var anchor := Vector3.ZERO
	var leader_node = get("leader")
	if leader_node is Node3D and is_instance_valid(leader_node):
		anchor = (leader_node as Node3D).global_position
	elif is_instance_valid(Global.player):
		anchor = Global.player.global_position
	global_position = Vector3(anchor.x + randf_range(-2.0, 2.0), anchor.y + 3.0, anchor.z + randf_range(-2.0, 2.0))
	velocity = Vector3.ZERO
	snap_to_ground()


func apply_gravity(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta
	elif velocity.y < 0.0:
		velocity.y = 0.0


## Smoothly yaw towards a world position without the look_at() gimbal traps.
func face_towards(target_pos: Vector3, delta: float) -> void:
	var flat := Vector3(target_pos.x - global_position.x, 0.0, target_pos.z - global_position.z)
	if flat.length_squared() < 0.0004:
		return
	var desired := atan2(flat.x, flat.z) + deg_to_rad(facing_offset_degrees)
	rotation.y = rotate_toward(rotation.y, desired, turn_speed * delta)


func distance_to_unit(other: Node3D) -> float:
	if not is_instance_valid(other):
		return INF
	var a := global_position
	var b := other.global_position
	return Vector2(a.x - b.x, a.z - b.z).length()


# ---------------------------------------------------------------------------
# Attacking
# ---------------------------------------------------------------------------

func can_attack() -> bool:
	return not is_dead and _attack_cooldown <= 0.0


func target_in_range(target: Node3D) -> bool:
	return is_instance_valid(target) and distance_to_unit(target) <= attack_range


## Fires the swing. Returns true when the attack actually started.
func try_attack(target: Node3D) -> bool:
	if not can_attack() or not is_instance_valid(target):
		return false
	if not target_in_range(target):
		return false
	_attack_cooldown = attack_interval * randf_range(0.9, 1.15)
	play_attack_animation()
	if ranged:
		_fire_projectile(target)
	else:
		# Small windup so the hit lands with the animation instead of on frame 0.
		var windup := minf(0.28, attack_interval * 0.3)
		get_tree().create_timer(windup, false).timeout.connect(
			_deliver_melee.bind(target), CONNECT_ONE_SHOT
		)
	return true


func _deliver_melee(target: Node3D) -> void:
	if is_dead or not is_instance_valid(target):
		return
	# Generous slack: the target may have shuffled during the windup.
	if distance_to_unit(target) > attack_range * 1.6:
		return
	var dealt: float = attack_damage * damage_multiplier * randf_range(0.9, 1.1)
	var knock := (target.global_position - global_position).normalized() * 2.2
	if target.has_method("take_damage"):
		target.take_damage(dealt, self, knock)
	attack_landed.emit(self, target, dealt)


func _fire_projectile(target: Node3D) -> void:
	var muzzle := global_position + Vector3.UP * 1.1 + global_transform.basis.z * 0.4
	Projectile.spawn(
		get_tree().current_scene,
		muzzle,
		target,
		attack_damage * damage_multiplier,
		faction,
		self
	)


# ---------------------------------------------------------------------------
# Taking damage
# ---------------------------------------------------------------------------

func take_damage(amount: float, source: Node = null, knockback: Vector3 = Vector3.ZERO) -> void:
	if is_dead or _invuln > 0.0:
		return
	# Shields: legionaries and centurions turn some blows aside outright.
	if block_chance > 0.0 and randf() < block_chance:
		_invuln = invulnerable_time
		_spawn_floating_text("block", Color(0.75, 0.82, 0.95), 0.75)
		_flash_timer = 0.10
		return

	_invuln = invulnerable_time
	last_attacker = source
	health -= amount
	damaged.emit(self, amount, source)
	_flash_timer = 0.14
	if health_billboard:
		health_billboard.visible = true

	if knockback != Vector3.ZERO:
		_knockback += knockback * (1.0 - clampf(knockback_resist, 0.0, 1.0))

	if show_damage_numbers:
		_spawn_floating_text(str(int(round(amount))), Color(1.0, 0.87, 0.55), 1.0)

	# Getting hit from out of nowhere makes a unit turn and fight back.
	if current_target == null and source is Node3D and is_instance_valid(source):
		var source_faction = source.get("faction")
		if source_faction != null and CombatTypes.is_hostile(faction, int(source_faction)):
			current_target = source

	if health <= 0.0:
		die(source)


## Legacy hook kept so the original weapon RayCast scripts keep working.
func hit() -> void:
	take_damage(10.0, null)


func heal(amount: float) -> void:
	if is_dead:
		return
	health += amount
	_spawn_floating_text("+%d" % int(round(amount)), Color(0.5, 0.95, 0.55), 0.9)


func die(killer: Node = null) -> void:
	if is_dead:
		return
	is_dead = true
	current_target = null
	velocity = Vector3.ZERO
	set_collision_layer_value(CombatTypes.LAYER_ALLY, false)
	set_collision_layer_value(CombatTypes.LAYER_ENEMY, false)
	remove_from_group(CombatTypes.group_for(faction))
	Battle.unregister(self)
	if is_instance_valid(killer):
		var killer_faction = killer.get("faction")
		if killer_faction != null:
			Battle.report_kill(int(killer_faction), self)
	if health_billboard:
		health_billboard.visible = false
	died.emit(self, killer)
	_play_death()


func _play_death() -> void:
	# Death is the one case that overrides the blend tree outright.
	if _anim_tree:
		_anim_tree.active = false
	play_named_animation(["Death", "Death_A", "HitRecieve", "Idle"], 0.15, true)
	# Sink through the floor, then clean up.
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(self, "rotation:x", deg_to_rad(-78.0), 0.35)
	tween.tween_property(self, "position:y", position.y - 0.9, corpse_linger).set_delay(corpse_linger * 0.4)
	tween.chain().tween_callback(queue_free)


# ---------------------------------------------------------------------------
# Movement helper shared by every AI
# ---------------------------------------------------------------------------

## Applies horizontal steering plus the current knockback impulse.
func steer(direction: Vector3, speed: float, delta: float, accel: float = 12.0) -> void:
	var desired := Vector3(direction.x, 0.0, direction.z)
	if desired.length_squared() > 1.0:
		desired = desired.normalized()
	desired *= speed
	velocity.x = lerpf(velocity.x, desired.x + _knockback.x, clampf(accel * delta, 0.0, 1.0))
	velocity.z = lerpf(velocity.z, desired.z + _knockback.z, clampf(accel * delta, 0.0, 1.0))


func horizontal_speed() -> float:
	return Vector2(velocity.x, velocity.z).length()


# ---------------------------------------------------------------------------
# Animation
# ---------------------------------------------------------------------------

func _discover_animation_nodes() -> void:
	_anim_tree = get_node_or_null("AnimationTree") as AnimationTree
	if _anim_tree:
		_anim_tree.active = true
		var pb = _anim_tree.get("parameters/MoveStateMachine/playback")
		if pb != null:
			_move_playback = pb
		_has_attack_oneshot = _anim_tree.has_method("set") and \
			_anim_tree.get("parameters/AttackOneShot/request") != null
	for child in get_children():
		if child is Node3D and child.get_child_count() > 0:
			var ap := child.get_node_or_null("AnimationPlayer") as AnimationPlayer
			if ap:
				_anim_player = ap
				_model_root = child
				_base_model_scale = child.scale
				break
	if _model_root == null:
		for child in get_children():
			if child is Node3D and not (child is CollisionShape3D):
				_model_root = child
				_base_model_scale = child.scale
				break


## Resolve the first animation name that actually exists on this rig.
## Rigs from different packs use different naming, so we probe instead of assume.
func resolve_animation(candidates: Array) -> String:
	if _anim_player == null:
		return ""
	for raw in candidates:
		var anim_name := String(raw)
		if _anim_player.has_animation(anim_name):
			return anim_name
		var prefixed := "CharacterArmature|" + anim_name
		if _anim_player.has_animation(prefixed):
			return prefixed
	return ""


func set_move_state(state_name: String) -> void:
	if _move_playback == null:
		return
	if _move_playback.get_current_node() != state_name:
		_move_playback.travel(state_name)


func update_locomotion_anim(threshold: float = 0.25) -> void:
	if is_dead:
		return
	set_move_state("Run" if horizontal_speed() > threshold else "Idle")


func play_attack_animation() -> void:
	if _anim_tree and _has_attack_oneshot:
		var anim_node = _anim_tree.get_tree_root().get_node("AttackAnimation") if _anim_tree.get_tree_root() else null
		if anim_node:
			var picked := resolve_animation(_attack_animation_candidates())
			if picked != "":
				anim_node.animation = picked
		_anim_tree.set("parameters/AttackOneShot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
	else:
		# No blend-tree slot: punch the scale so the swing still reads.
		_scale_punch(1.18, 0.12)


func _attack_animation_candidates() -> Array:
	if ranged:
		return ["Shoot_Bow", "Bow_Shoot", "Interact", "SwordSlash", "Punch"]
	match role:
		CombatTypes.UnitRole.HASTATUS:
			return ["Spear_Stab", "1H_Melee_Attack_Stab", "SwordSlash", "Punch"]
		CombatTypes.UnitRole.VELES:
			return ["Punch", "SwordSlash", "Interact"]
		_:
			return ["SwordSlash", "Sword_Slash", "2H_Melee_Attack_Spin", "Punch", "Interact"]


## Plays a one-off clip straight on the AnimationPlayer.
##
## A rig driven by an AnimationTree ignores this unless `force` is set, because
## taking the player over would silence the blend tree for good - that is only
## acceptable on death.
func play_named_animation(candidates: Array, blend: float = 0.15, force: bool = false) -> void:
	if _anim_player == null:
		return
	if _anim_tree and _anim_tree.active and not force:
		return
	var picked := resolve_animation(candidates)
	if picked == "":
		return
	_anim_player.play(picked, blend)


func _scale_punch(amount: float, duration: float) -> void:
	if _model_root == null:
		return
	var tween := create_tween()
	tween.tween_property(_model_root, "scale", _base_model_scale * amount, duration * 0.35)
	tween.tween_property(_model_root, "scale", _base_model_scale, duration * 0.65)


# ---------------------------------------------------------------------------
# Presentation
# ---------------------------------------------------------------------------

## Health bars live in a SubViewport each. With 150 soldiers on the field
## that's 150 viewports, so they only render the frame their value changes.
func _refresh_health_bar() -> void:
	if health_bar:
		health_bar.max_value = max_health
		health_bar.value = health
	if health_viewport:
		health_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	if health_billboard and not is_dead:
		health_billboard.visible = health < max_health


## Recolours the unit's armour so the two armies never blur together.
func _apply_faction_tint() -> void:
	var tint := CombatTypes.tint_for(faction, role)
	_tinted_materials.clear()
	_tint_recursive(self, tint)


func _tint_recursive(node: Node, tint: Color) -> void:
	if node is MeshInstance3D:
		var mesh_node := node as MeshInstance3D
		var mat := StandardMaterial3D.new()
		var src := mesh_node.get_active_material(0)
		if src is StandardMaterial3D:
			var std := src as StandardMaterial3D
			mat.albedo_texture = std.albedo_texture
			mat.albedo_color = std.albedo_color.lerp(tint, 0.55)
			mat.roughness = std.roughness
			mat.metallic = std.metallic
		else:
			mat.albedo_color = tint
		mat.emission_enabled = true
		mat.emission = Color.WHITE
		mat.emission_energy_multiplier = 0.0
		mesh_node.material_overlay = null
		mesh_node.material_override = mat
		_tinted_materials.append(mat)
	for child in node.get_children():
		_tint_recursive(child, tint)


func _set_flash(strength: float) -> void:
	for mat in _tinted_materials:
		if is_instance_valid(mat):
			mat.emission_energy_multiplier = strength * 1.6


func _spawn_floating_text(text: String, color: Color, scale_mult: float) -> void:
	var host := get_tree().current_scene
	if host == null:
		return
	FloatingText.spawn(host, global_position + Vector3.UP * 1.9, text, color, scale_mult)


# ---------------------------------------------------------------------------
# Collision / groups
# ---------------------------------------------------------------------------

func _apply_collision_layers() -> void:
	collision_layer = 0
	collision_mask = 0
	set_collision_layer_value(CombatTypes.layer_for(faction), true)
	# Units collide with the world only - never with each other. Making a
	# hundred soldiers mutually solid turns a tight formation into a shoving
	# match that flings people off the map. Spacing is steering's job
	# (see _separation()), not the physics solver's.
	set_collision_mask_value(CombatTypes.LAYER_WORLD, true)


func _join_groups() -> void:
	add_to_group(CombatTypes.GROUP_COMBATANTS)
	add_to_group(CombatTypes.group_for(faction))
