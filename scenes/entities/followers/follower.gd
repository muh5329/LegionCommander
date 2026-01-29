class_name Follower
extends CharacterBody3D

const FOLLOW_DISTANCE = 0.9
const ARRIVAL_THRESHOLD = 0.2  # Tighter arrival (was 0.3)
const MAX_SPEED = 4.0  # Faster to keep up (was 3.0)
const ACCELERATION = 12.0  # Quicker response (was 8.0)
const SEPARATION_DISTANCE = 0.3  # Less separation (was 0.5)

var leader: CharacterBody3D = null
var formation_index: int = 0


@onready var nav_agent: NavigationAgent3D = $NavigationAgent3D
@onready var animation_tree: AnimationTree = $AnimationTree
@onready var move_state_machine = $AnimationTree.get("parameters/MoveStateMachine/playback")

var _gravity = ProjectSettings.get_setting("physics/3d/default_gravity")

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
	add_to_group("followers")
	

	
	# Setup NavigationAgent
	if nav_agent:
		nav_agent.path_desired_distance = 0.5
		nav_agent.target_desired_distance = 0.5
		nav_agent.max_speed = MAX_SPEED
		nav_agent.radius = 0.5  # Match capsule radius
		nav_agent.height = 2.0  # Match capsule height
		nav_agent.avoidance_enabled = true  # Enable dynamic obstacle avoidance
		
		# Wait for navigation to be ready
		call_deferred("_setup_navigation")

func _setup_navigation() -> void:
	# Navigation needs one frame to initialize
	await get_tree().physics_frame
	if leader:
		var target = calculate_circle_formation_position()
		nav_agent.target_position = target

func _physics_process(delta: float) -> void:
	# Apply gravity
	if not is_on_floor():
		velocity.y -= _gravity * delta
	else:
		velocity.y = 0
	
	if leader and nav_agent:
		# Update navigation target
		var target_pos = calculate_circle_formation_position()
		nav_agent.target_position = target_pos
		
		# Check if we're close enough
		if nav_agent.is_navigation_finished():
			velocity.x = lerp(velocity.x, 0.0, 50.0 * delta)
			velocity.z = lerp(velocity.z, 0.0, 50.0 * delta)
		else:
			# Get next position from navigation
			var next_path_position = nav_agent.get_next_path_position()
			var direction = (next_path_position - global_position).normalized()
			direction.y = 0  # Keep movement horizontal
			
			# Apply separation (still useful even with nav agent)
			var separation = calculate_separation()
			direction = (direction + separation * 0.3).normalized()  # Reduce separation influence
			
			# Move towards navigation target
			var desired_velocity = direction * MAX_SPEED
			velocity.x = lerp(velocity.x, desired_velocity.x, ACCELERATION * delta)
			velocity.z = lerp(velocity.z, desired_velocity.z, ACCELERATION * delta)
			
			# Face movement direction
			if direction.length() > 0.1:
				look_at(Vector3(next_path_position.x, global_position.y, next_path_position.z), Vector3.UP)
	
	move_and_slide()
	set_movement_anim()
	
func set_movement_anim() -> void:
	if velocity.length() > 0.0:
		set_move_state("Run")
	else:
		set_move_state("Idle")


func calculate_circle_formation_position() -> Vector3:
	if !leader:
		return global_position
	
	var followers_in_group = leader.followers
	var total_followers = followers_in_group.size()
	
	if total_followers == 0:
		return leader.global_position
	
	# Tight concentric rings formation (Pikmin/RTS style)
	var followers_per_ring = 20  # More followers per ring = tighter
	var ring_number = formation_index / followers_per_ring
	var position_in_ring = formation_index % followers_per_ring
	
	# Much tighter radius values
	var base_radius = 0.2  # Very close first ring
	var ring_spacing = 0.3  # Smaller gaps between rings
	var ring_radius = base_radius + (ring_number * ring_spacing)
	
	# Calculate angle for this position in the ring
	var angle_step = TAU / max(followers_per_ring, 1)
	var angle = angle_step * position_in_ring
	
	# Position BEHIND the leader
	var leader_forward = -leader.global_transform.basis.z
	var behind_distance = FOLLOW_DISTANCE + (ring_number * 0.2)  # Each ring is slightly further back
	var formation_center = leader.global_position - leader_forward * behind_distance
	
	# Create circular offset
	var offset = Vector3(
		cos(angle) * ring_radius,
		0,
		sin(angle) * ring_radius
	)
	
	var target = formation_center + offset
	target.y = leader.global_position.y
	return target
	
	

func calculate_separation() -> Vector3:
	var separation = Vector3.ZERO
	var nearby_count = 0
	
	for follower in get_tree().get_nodes_in_group("followers"):
		if follower == self or not is_instance_valid(follower):
			continue
		
		var diff = global_position - follower.global_position
		diff.y = 0
		var distance = diff.length()
		
		if distance < SEPARATION_DISTANCE and distance > 0:
			separation += diff.normalized() / distance
			nearby_count += 1
	
	if nearby_count > 0:
		separation = separation / nearby_count
		separation.y = 0
	
	return separation

func set_leader(new_leader: CharacterBody3D, index: int) -> void:
	leader = new_leader
	formation_index = index
	
	# Update navigation target
	if nav_agent:
		call_deferred("_update_nav_target")

func _update_nav_target() -> void:
	await get_tree().physics_frame
	if leader:
		nav_agent.target_position = calculate_circle_formation_position()


func set_move_state(state_name: String) -> void:
	move_state_machine.travel(state_name)
