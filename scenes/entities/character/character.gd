class_name Character


extends CharacterBody3D

# const
const MOVE_SPEED = 1.5

# Exports
@export var _speed: float = 2.0
@export var _jump_velocity: float = 4.5
@export var _rotation_velocity: float = 3.5
@export var _velocity: Vector3 = Vector3.ZERO

# Private vars
var _path: PackedVector3Array 

# On ready
@onready var _anim: AnimationTree = $AnimationTree
#@onready var _agent: NavigationAgent3D = $NavigationAgent3D

var _gravity = ProjectSettings.get_setting("physics/3d/default_gravity")


var _rotation : int


func _ready() -> void:
	_anim.active = true
	
	
func _physics_process(delta: float) -> void:
	
	if !is_on_floor():
		velocity.y -= _gravity * delta

	if _path != null and !_path.is_empty():
		var target_pos = _path[0]
		var diff = target_pos - global_position
		if diff.length() > 0.1:
			var next : Vector3 = target_pos
			look_at(Vector3(next.x, global_position.y, next.z), Vector3.UP)
			var dir : Vector3 = ( next - global_position ).normalized()
			velocity.x = dir.x * _speed
			velocity.z = dir.z * _speed
		else:
			_path.remove_at(0)
			if _path.is_empty: 
				velocity.x = 0
				velocity.z = 0

	
		
		
		
	move_and_slide()
	
# public func
func move(path: PackedVector3Array) -> void :
	_path = path
	
	

# Private func
