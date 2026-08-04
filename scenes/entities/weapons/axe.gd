## Weapon hitbox. Damage is normally driven by Combatant.try_attack(), so this
## stays inert unless something deliberately opens the damage window during an
## animation (via an AnimationPlayer call track, for example).
extends Node3D

@export var can_damage: bool = false
@export var damage: float = 10.0
## Seconds a target is immune to this specific weapon after being hit.
@export var retrigger_delay: float = 0.4

var _recent: Dictionary = {}

@onready var _ray: RayCast3D = get_node_or_null("RayCast3D")


func open_window(duration: float = 0.2) -> void:
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


## Walk up to the body holding this weapon so kills are credited correctly.
func _find_wielder() -> Node:
	var node: Node = get_parent()
	while node != null:
		if node is Combatant:
			return node
		node = node.get_parent()
	return null
