class_name Character


extends CharacterBody3D

# const
const MOVE_SPEED = 1.5

# Exports
@export var _speed: float = 2.0
@export var _jump_velocity: float = 4.5
@export var _rotation_velocity: float = 3.5
@export var _velocity: Vector3 = Vector3.ZERO
@export var formation_offset: float = 2.0  # Distance behind player where followers gather

# Public Vars
var followers: Array[CharacterBody3D] = []
var movement_direction: Vector3 = Vector3.ZERO
\

# Private vars
var _path: PackedVector3Array 

# On ready
@onready var _anim: AnimationTree = $AnimationTree
@onready var swarm: Node3D = $"../../Swarm"

var _gravity = ProjectSettings.get_setting("physics/3d/default_gravity")


var _rotation : int


func _ready() -> void:
	_anim.active = true
	add_to_group("player")
	for _i in range(10):
		spawn_follower(global_position)
	

	
# public func
func move(path: PackedVector3Array) -> void :
	_path = path

# Add this method to add a follower
func add_follower(follower: Follower) -> void:
	if follower not in followers:
		followers.append(follower)
		follower.set_leader(self, followers.size() - 1)
		print("Follower added! Total: ", followers.size())

# Add this method to remove a follower
func remove_follower(follower: Follower) -> void:
	var index = followers.find(follower)
	if index != -1:
		followers.remove_at(index)
		follower.leader = null
		# Reassign indices for remaining followers
		for i in range(followers.size()):
			followers[i].formation_index = i

# Optional: Call this when you collect a follower (e.g., on collision)
func _on_area_entered(area: Area3D) -> void:
	if area.is_in_group("collectible_follower"):
		var follower = area.get_parent() as Follower
		if follower:
			add_follower(follower)
			# Remove the collectible area if you don't want to collect twice
			area.queue_free()
			
func spawn_follower(position: Vector3) -> void:
	var follower_scene = preload("res://scenes/entities/followers/follower.tscn")
	var follower = follower_scene.instantiate()
	
	# Set scale and position BEFORE adding to tree
	follower.scale = Vector3(0.3, 0.3, 0.3)
	follower.position = position
	follower.position.y = global_position.y  # Match player height to ensure on floor
	
	# Add to tree
	get_parent().add_child.call_deferred(follower)
	
	# Wait for it to be in tree, then add as follower
	await get_tree().process_frame
	add_follower(follower)
	
# Private func
