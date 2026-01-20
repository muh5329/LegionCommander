extends Node3D


#on Ready
@onready var target: Node3D = $Target

@onready var player = get_tree().get_first_node_in_group("player")

# pub vars
var followers: Array[CharacterBody3D] = []
var map : RID 




# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	map = get_world_3d().get_navigation_map()
	
	for child in get_children():
		if child is CharacterBody3D:
			followers.append(child)
	
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(_delta: float) -> void:
	move_target() 
	if player.global_position.distance_to(target.global_position) > 0.1:
		move_followers()


func move_target() -> void:
	# Define the offset in LOCAL space (Z+ is back in Godot)
	var local_offset : Vector3 = Vector3(0, 0, 0.5)
	# Apply player's global transform to the local offset
	target.global_transform.origin = player.global_transform * local_offset
	# Sync the rotation to match the player
	target.global_transform.basis = player.global_transform.basis
	

# public func
func move_followers() -> void:
	var target_pos : Vector3 = target.global_position
	var offset : Vector3  = Vector3.ZERO
	

	for follower   in followers:
		var f := follower as Follower
		if f.position + offset >= target_pos:
			f.set_target_position(target_pos)
		f.set_target_position(target_pos)
		# Pathfinding approach
		#if f:
			#var start_position = f.global_position
			#var path: PackedVector3Array = NavigationServer3D.map_get_path(
				#map,
				#start_position,
				#target_pos,
				#true
			#)
			#if path.is_empty():
				#print("No path found")
				#continue
			#if f._path.is_empty():
				#f.move(path)
