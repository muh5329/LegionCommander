class_name Enemy
extends CharacterBody3D



	


const MAX_SPEED = 4.0  # Faster to keep up (was 3.0)
const simple_attacks = {
	'slice' : "CharacterArmature|SwordSlash",
	'spin' : "2H_Melee_Attack_Spin",
	'range' : "1H_Melee_Attack_Stab",
}

@export var notice_radius := 5.0
@export var attack_radius := 1.0
@export var walk_speed := 2.0
@export var speed := walk_speed
@export var target_desired_distance := 0.1

@export var jump_height : float = 2.25
@export var jump_time_to_peak : float = 0.4
@export var jump_time_to_descent : float = 0.3

@onready var jump_velocity : float = ((2.0 * jump_height) / jump_time_to_peak) * -1.0
@onready var jump_gravity : float = ((-2.0 * jump_height) / (jump_time_to_peak * jump_time_to_peak)) * -1.0
@onready var fall_gravity : float = ((-2.0 * jump_height) / (jump_time_to_descent * jump_time_to_descent)) * -1.0


@onready var nav_agent: NavigationAgent3D = $NavigationAgent3D
@onready var animation_tree: AnimationTree = $AnimationTree
@onready var move_state_machine = $AnimationTree.get("parameters/MoveStateMachine/playback")
@onready var target = get_tree().get_first_node_in_group('player')
@onready var attack_animation  = $AnimationTree.get_tree_root().get_node('AttackAnimation')

var _gravity = ProjectSettings.get_setting("physics/3d/default_gravity")
var health = 5: 
	set(value):
		health = value
		if health <= 0:
			queue_free()
var speed_modifier := 1.0
var can_damage_toggle := false
var rng = RandomNumberGenerator.new()

func _ready() -> void:
	
	animation_tree.active = true
	
	# Fix collision shape alignment
	var collision = get_node_or_null("CollisionShape3D")
	if collision and collision.shape is CapsuleShape3D:
		collision.position.y = collision.shape.height / 2.0
	
	# Set proper collision layers
	collision_layer = 2  # Followers
	collision_mask = 1   # Ground only
	
	# Initialize
	velocity = Vector3.ZERO
	add_to_group("enemies")
	
	# Setup NavigationAgent
	if nav_agent:
		nav_agent.path_desired_distance = target_desired_distance
		nav_agent.target_desired_distance = target_desired_distance
		nav_agent.max_speed = MAX_SPEED
		nav_agent.radius = 0.5  # Match capsule radius
		nav_agent.height = 2.0  # Match capsule height
		nav_agent.avoidance_enabled = true  # Enable dynamic obstacle avoidance
		
		# Wait for navigation to be ready
		#call_deferred("_setup_navigation")
func _process(_delta: float) -> void:
	attack_logic()
	
func _physics_process(delta: float) -> void:
	jump_logic(delta)
	move_to_target(delta)

func move_to_target(delta) -> void:

	if position.distance_to(target.position) < notice_radius:
		var target_dir = (target.position - position).normalized()
		var target_vec2 = Vector2(target_dir.x, target_dir.z)
		var target_angle = -target_vec2.angle() + PI/2
		rotation.y = rotate_toward(rotation.y,target_angle, delta * 6.0) 
		
		if position.distance_to(target.position) > attack_radius:
			velocity = Vector3(target_vec2.x,0,target_vec2.y) * speed * speed_modifier
			move_state_machine.travel('Run')
		else:
			velocity = Vector3.ZERO
			move_state_machine.travel('Idle')
		move_and_slide()

func jump_logic(delta : float) -> void:
	
	if is_on_floor():
		#velocity.y =  -jump_velocity
		pass
	else:
		pass
	var gravity = jump_gravity if velocity.y  > 0.0 else fall_gravity 
	velocity.y -= gravity * delta
	
	
func stop_movement(start_duration: float, end_duration: float):
	var tween = create_tween()
	tween.tween_property(self, "speed_modifier", 0.0, start_duration)
	tween.tween_property(self, "speed_modifier", 1.0, end_duration)


func set_movement_anim() -> void:
	if velocity.length() > 0.0:
		set_move_state("Run")
	else:
		set_move_state("Idle")


func set_move_state(state_name: String) -> void:
	move_state_machine.travel(state_name)

	
func hit() -> void :
	if not $Timers/InvulTimer.time_left:
		$Timers/InvulTimer.start()
		health -= 1


func attack_logic() -> void:
	if can_damage_toggle:
		var collider = $Goblin_Male/CharacterArmature/Skeleton3D/RightHandSlot/Axe/RayCast3D.get_collider()
		if collider and 'hit' in collider:
			collider.hit()

func melee_attack_animation() -> void:
	attack_animation.animation = simple_attacks['slice' if rng.randi() % 2 else 'spin' ]
	$AnimationTree.set("parameters/AttackOneShot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
	
	
func _on_attack_timer_timeout() -> void:
	$Timers/AttackTimer.wait_time = rng.randf_range(4.0, 5.5)
	if position.distance_to(target.position) < 5.0: 
		melee_attack_animation()
	else:
		if rng.randi() % 2:
			pass
		else:
			pass
