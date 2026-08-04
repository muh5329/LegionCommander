## Spear hitbox. Same contract as axe.gd - inert until an animation opens the
## damage window. Longer reach, slightly higher damage.
extends Node3D

@export var can_damage: bool = false
@export var damage: float = 14.0
@export var retrigger_delay: float = 0.5

var _recent: Dictionary = {}

@onready var _ray: RayCast3D = get_node_or_null("RayCast3D")


func open_window(duration: float = 0.22) -> void:
	can_damage = true
	get_tree().create_timer(duration, false).timeout.connect(close_window, CONNECT_ONE_SHOT)


func close_window() -> void:
	can_damage = false
	_recent.clear()


func _physics_process(delta: float) -> void:
	for key in _recent.keys():
		_recent[key] -= delta
		if _recent[key] <= 0.0:
			_recent.erase(key)

	if not can_damage or _ray == null:
		return

	var collider := _ray.get_collider()
	if collider == null or _recent.has(collider):
		return
	if collider.has_method("take_damage"):
		collider.take_damage(damage, _find_wielder())
		_recent[collider] = retrigger_delay


func _find_wielder() -> Node:
	var node: Node = get_parent()
	while node != null:
		if node is Combatant:
			return node
		node = node.get_parent()
	return null
