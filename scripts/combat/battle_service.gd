## Autoloaded battlefield registry (singleton name: `Battle`).
##
## Hundreds of units all asking `get_tree().get_nodes_in_group()` every frame is
## the fastest way to kill a Pikmin-scale battle. Instead every combatant
## registers here once and reports its cell when it crosses a grid boundary, so
## "who is near me?" becomes a handful of dictionary lookups.
extends Node

## Width of one spatial hash cell in world units.
const CELL_SIZE := 8.0

## Emitted whenever units join or leave a faction (HUD listens to this).
signal roster_changed(faction: int)
## Emitted on kills, camp captures, recruitment - anything worth a killfeed line.
signal battle_event(text: String, color: Color)
## Emitted when a camp changes hands.
signal objectives_changed(captured: int, total: int)

var _cells: Dictionary = {}                  # Vector2i -> Array[Combatant]
var _unit_cell: Dictionary = {}              # Combatant -> Vector2i
var _by_faction: Dictionary = {}             # int -> Array[Combatant]

var player_kills: int = 0
var losses: int = 0
var camps_total: int = 0
var camps_captured: int = 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	reset()


## Wipes all state. Call when loading a fresh level.
func reset() -> void:
	_cells.clear()
	_unit_cell.clear()
	_by_faction = {
		CombatTypes.Faction.PLAYER: [],
		CombatTypes.Faction.ENEMY: [],
		CombatTypes.Faction.NEUTRAL: [],
	}
	player_kills = 0
	losses = 0
	camps_total = 0
	camps_captured = 0


# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------

func register(unit: Node3D) -> void:
	if unit == null or _unit_cell.has(unit):
		return
	var faction := int(unit.get("faction"))
	var cell := _cell_of(unit.global_position)
	_unit_cell[unit] = cell
	_bucket(cell).append(unit)
	_faction_list(faction).append(unit)
	roster_changed.emit(faction)


func unregister(unit: Node3D) -> void:
	if unit == null or not _unit_cell.has(unit):
		return
	var cell: Vector2i = _unit_cell[unit]
	if _cells.has(cell):
		var arr: Array = _cells[cell]
		arr.erase(unit)
		if arr.is_empty():
			_cells.erase(cell)
	_unit_cell.erase(unit)
	var faction := int(unit.get("faction"))
	_faction_list(faction).erase(unit)
	roster_changed.emit(faction)


## Cheap: only touches the hash when the unit actually crossed a cell border.
func notify_moved(unit: Node3D) -> void:
	if unit == null or not _unit_cell.has(unit):
		return
	var new_cell := _cell_of(unit.global_position)
	var old_cell: Vector2i = _unit_cell[unit]
	if new_cell == old_cell:
		return
	if _cells.has(old_cell):
		var arr: Array = _cells[old_cell]
		arr.erase(unit)
		if arr.is_empty():
			_cells.erase(old_cell)
	_unit_cell[unit] = new_cell
	_bucket(new_cell).append(unit)


## A unit switched sides (recruited, or converted on capture).
func notify_faction_changed(unit: Node3D, old_faction: int) -> void:
	_faction_list(old_faction).erase(unit)
	_faction_list(int(unit.get("faction"))).append(unit)
	roster_changed.emit(old_faction)
	roster_changed.emit(int(unit.get("faction")))


# ---------------------------------------------------------------------------
# Queries
# ---------------------------------------------------------------------------

## All registered units within `radius` of `origin`.
## `faction_filter` of -1 means "any faction".
func query(origin: Vector3, radius: float, faction_filter: int = -1, exclude: Node = null) -> Array[Node3D]:
	var found: Array[Node3D] = []
	var r2 := radius * radius
	var span := int(ceil(radius / CELL_SIZE))
	var centre := _cell_of(origin)
	for dx in range(-span, span + 1):
		for dz in range(-span, span + 1):
			var key := Vector2i(centre.x + dx, centre.y + dz)
			var bucket: Array = _cells.get(key, [])
			for unit: Node3D in bucket:
				if unit == exclude or not is_instance_valid(unit):
					continue
				if faction_filter >= 0 and int(unit.get("faction")) != faction_filter:
					continue
				if unit.get("is_dead"):
					continue
				if origin.distance_squared_to(unit.global_position) <= r2:
					found.append(unit)
	return found


## Closest unit of `faction_filter` within `radius`, or null.
func nearest(origin: Vector3, radius: float, faction_filter: int = -1, exclude: Node = null) -> Node3D:
	var best: Node3D = null
	var best_d := radius * radius
	var span := int(ceil(radius / CELL_SIZE))
	var centre := _cell_of(origin)
	for dx in range(-span, span + 1):
		for dz in range(-span, span + 1):
			var key := Vector2i(centre.x + dx, centre.y + dz)
			var bucket: Array = _cells.get(key, [])
			for unit: Node3D in bucket:
				if unit == exclude or not is_instance_valid(unit):
					continue
				if faction_filter >= 0 and int(unit.get("faction")) != faction_filter:
					continue
				if unit.get("is_dead"):
					continue
				var d := origin.distance_squared_to(unit.global_position)
				if d < best_d:
					best_d = d
					best = unit
	return best


## Closest unit that `faction` considers an enemy.
func nearest_hostile(origin: Vector3, faction: int, radius: float, exclude: Node = null) -> Node3D:
	var target_faction := CombatTypes.opposing(faction)
	if target_faction < 0:
		return null
	return nearest(origin, radius, target_faction, exclude)


func units_of(faction: int) -> Array:
	return _faction_list(faction)


func count(faction: int) -> int:
	return _faction_list(faction).size()


func count_role(faction: int, role: int) -> int:
	var n := 0
	for unit in _faction_list(faction):
		if is_instance_valid(unit) and int(unit.get("role")) == role:
			n += 1
	return n


## Breakdown of a faction's army: {role -> count}.
func role_breakdown(faction: int) -> Dictionary:
	var out := {}
	for unit in _faction_list(faction):
		if not is_instance_valid(unit):
			continue
		var r := int(unit.get("role"))
		out[r] = int(out.get(r, 0)) + 1
	return out


# ---------------------------------------------------------------------------
# Scoreboard
# ---------------------------------------------------------------------------

func report_kill(killer_faction: int, victim: Node3D) -> void:
	var victim_name := "unit"
	if victim != null:
		victim_name = CombatTypes.role_name(int(victim.get("role")))
	if killer_faction == CombatTypes.Faction.PLAYER:
		player_kills += 1
		battle_event.emit("%s slain" % victim_name, CombatTypes.FACTION_COLORS[CombatTypes.Faction.PLAYER])
	elif killer_faction == CombatTypes.Faction.ENEMY:
		losses += 1
		battle_event.emit("%s lost" % victim_name, Color(0.9, 0.5, 0.3))


func register_camp() -> void:
	camps_total += 1
	objectives_changed.emit(camps_captured, camps_total)


func report_camp_captured(camp_name: String) -> void:
	camps_captured += 1
	battle_event.emit("%s captured!" % camp_name, Color(1.0, 0.86, 0.35))
	objectives_changed.emit(camps_captured, camps_total)


func announce(text: String, color: Color = Color.WHITE) -> void:
	battle_event.emit(text, color)


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------

func _cell_of(pos: Vector3) -> Vector2i:
	return Vector2i(int(floor(pos.x / CELL_SIZE)), int(floor(pos.z / CELL_SIZE)))


func _bucket(cell: Vector2i) -> Array:
	if not _cells.has(cell):
		_cells[cell] = []
	return _cells[cell]


func _faction_list(faction: int) -> Array:
	if not _by_faction.has(faction):
		_by_faction[faction] = []
	return _by_faction[faction]
