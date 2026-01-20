class_name Follower

extends CharacterBody3D


# Exports
@export var  move_speed = 600
@export var perception_radius = 50
@export var centralization_force_radius = 10
@export var steer_force = 50.0
@export var alignment_force = 1.2
@export var cohesion_force = 0.5
@export var seperation_force = 1.0
@export var avoidance_force = 30.0
@export var centralization_force = 0.5
@export var target_position: Vector3 = Vector3.ZERO

# Variables
var boids = []
var acceleration = Vector3()

func _ready() -> void:
	pass
	

func _process(delta: float) -> void:
	var neighbors = get_neighbors(perception_radius)
	
	acceleration += process_alignments(neighbors) * alignment_force
	acceleration += process_cohesion(neighbors) * cohesion_force
	acceleration += process_seperation(neighbors) * seperation_force
	acceleration += process_centralization(target_position) * centralization_force
		
	velocity += acceleration * delta
	velocity = velocity.limit_length(move_speed)
	if velocity.length() > 0.01:
		look_at(position + velocity, Vector3.UP)
	
	print(velocity)
	translate(velocity * delta)	

# pub func

func set_target_position(position: Vector3):
	target_position = position
	
# Navigation toward Target	
func process_centralization(center: Vector3):
	if position.distance_to(center) < centralization_force_radius:
		return Vector3()
		
	return steer((center - position).normalized() * move_speed)	

# Cohesion is the force pulling the boid toward the center of its neighbors
func process_cohesion(neighbors):
	var vector = Vector3()
	if neighbors.is_empty():
		return vector
	for boid in neighbors:
		vector += boid.position
	vector /= neighbors.size()
	
	return steer((vector - position).normalized() * move_speed)
		

# Alignment is the tendency to align movement direction with nearby boids.
func process_alignments(neighbors):
	var vector = Vector3()
	if neighbors.is_empty():
		return vector
	
	# Align boids towards the general direction of ther boids	
	for boid in neighbors:
		vector += boid.velocity
	vector /= neighbors.size()
	
	return steer(vector.normalized() * move_speed)

# Separation is the force that prevents boids from getting too close to each other.
func process_seperation(neighbors) -> Vector3 :
	var vector := Vector3()
	var close_neighbors := []
	
	for boid in neighbors:
		# Gather close neighors
		if position.distance_to(boid.position) < perception_radius / 2:
			close_neighbors.push_back(boid)
		if close_neighbors.is_empty():
			return vector
		
		# Calculte cumaltive / avergage vector
	
	for boid in close_neighbors:
		var difference = position - boid.position
		vector += difference.normalized() / difference.length
			
	vector /= close_neighbors.size()
	return steer(vector.normalized() * move_speed)
	
	
	
func steer( target) -> Vector3:
	var steer = target - velocity
	steer = steer.normalized() * steer_force
	
	return steer
	
func get_neighbors(view_radius):
	var neighbors = []

	for boid in boids:
		if position.distance_to(boid.position) <= view_radius and not boid == self:
			neighbors.push_back(boid)
			
	return neighbors
