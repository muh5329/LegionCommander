## Shared combat vocabulary for Legion Commander.
##
## Everything that needs to know about factions, unit roles, collision layers or
## group names pulls it from here so the rules live in exactly one place.
class_name CombatTypes
extends RefCounted

# ---------------------------------------------------------------------------
# Factions
# ---------------------------------------------------------------------------
enum Faction {
	PLAYER = 0,   ## Your legion.
	ENEMY = 1,    ## Rival legions and barbarian warbands.
	NEUTRAL = 2,  ## Loose units waiting to be whistled up, critters, props.
}

# ---------------------------------------------------------------------------
# Unit roles
# ---------------------------------------------------------------------------
enum UnitRole {
	LEGIONARY = 0,    ## Gladius + scutum. Tanky bread-and-butter melee.
	HASTATUS = 1,     ## Spear. Longer reach, hits from the second rank.
	SAGITTARIUS = 2,  ## Archer. Ranged, fragile, deadly at a distance.
	VELES = 3,        ## Skirmisher. Fast, light, good for flanking.
	CENTURION = 4,    ## Officer. Buffs nearby friendlies, high health.
	BARBARIAN = 5,    ## Goblin raider. Enemy-only brawler.
}

# ---------------------------------------------------------------------------
# Collision layers (1-indexed, matching project.godot layer_names)
# ---------------------------------------------------------------------------
const LAYER_WORLD := 1
const LAYER_COMMANDER := 2
const LAYER_ALLY := 3
const LAYER_ENEMY := 4
const LAYER_PROJECTILE := 5
const LAYER_ITEM := 6

# ---------------------------------------------------------------------------
# Scene tree groups
# ---------------------------------------------------------------------------
const GROUP_COMBATANTS := "combatants"
const GROUP_PLAYER_UNITS := "player_units"
const GROUP_ENEMY_UNITS := "enemy_units"
const GROUP_LOOSE_UNITS := "loose_units"
const GROUP_WORLD := "world_group"
const GROUP_CAMPS := "enemy_camps"

# ---------------------------------------------------------------------------
# Role stat block
# ---------------------------------------------------------------------------
## Every field is a base value; spawners apply faction/tier multipliers on top.
const ROLE_STATS := {
	UnitRole.LEGIONARY: {
		"name": "Legionary",
		"short": "LEG",
		"health": 120.0,
		"damage": 14.0,
		"attack_range": 1.6,
		"attack_interval": 1.15,
		"speed": 4.2,
		"aggro": 7.0,
		"ranged": false,
		"block_chance": 0.25,
		"tint": Color(0.85, 0.16, 0.18),
	},
	UnitRole.HASTATUS: {
		"name": "Hastatus",
		"short": "HAS",
		"health": 95.0,
		"damage": 18.0,
		"attack_range": 2.6,
		"attack_interval": 1.45,
		"speed": 4.0,
		"aggro": 8.0,
		"ranged": false,
		"block_chance": 0.10,
		"tint": Color(0.95, 0.72, 0.22),
	},
	UnitRole.SAGITTARIUS: {
		"name": "Sagittarius",
		"short": "SAG",
		"health": 65.0,
		"damage": 16.0,
		"attack_range": 12.0,
		"attack_interval": 1.7,
		"speed": 4.4,
		"aggro": 13.0,
		"ranged": true,
		"block_chance": 0.0,
		"tint": Color(0.30, 0.72, 0.45),
	},
	UnitRole.VELES: {
		"name": "Veles",
		"short": "VEL",
		"health": 70.0,
		"damage": 11.0,
		"attack_range": 1.5,
		"attack_interval": 0.7,
		"speed": 5.6,
		"aggro": 9.0,
		"ranged": false,
		"block_chance": 0.05,
		"tint": Color(0.36, 0.55, 0.95),
	},
	UnitRole.CENTURION: {
		"name": "Centurion",
		"short": "CEN",
		"health": 420.0,
		"damage": 26.0,
		"attack_range": 2.0,
		"attack_interval": 1.3,
		"speed": 4.0,
		"aggro": 16.0,
		"ranged": false,
		"block_chance": 0.35,
		"tint": Color(0.95, 0.85, 0.35),
	},
	UnitRole.BARBARIAN: {
		"name": "Raider",
		"short": "RAI",
		"health": 110.0,
		"damage": 15.0,
		"attack_range": 1.8,
		"attack_interval": 1.25,
		"speed": 4.6,
		"aggro": 10.0,
		"ranged": false,
		"block_chance": 0.0,
		"tint": Color(0.55, 0.75, 0.32),
	},
}

## Roles the player is allowed to recruit and throw.
const PLAYER_ROLES: Array[int] = [
	UnitRole.LEGIONARY,
	UnitRole.HASTATUS,
	UnitRole.SAGITTARIUS,
	UnitRole.VELES,
]

## Banner / UI colour per faction.
const FACTION_COLORS := {
	Faction.PLAYER: Color(0.87, 0.20, 0.22),
	Faction.ENEMY: Color(0.24, 0.36, 0.78),
	Faction.NEUTRAL: Color(0.75, 0.75, 0.72),
}

const FACTION_NAMES := {
	Faction.PLAYER: "Legio I",
	Faction.ENEMY: "Hostiles",
	Faction.NEUTRAL: "Unaligned",
}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## Returns the faction a unit of `faction` should be shooting at.
static func opposing(faction: int) -> int:
	match faction:
		Faction.PLAYER: return Faction.ENEMY
		Faction.ENEMY: return Faction.PLAYER
		_: return -1


## True when the two factions want each other dead.
static func is_hostile(a: int, b: int) -> bool:
	if a == Faction.NEUTRAL or b == Faction.NEUTRAL:
		return false
	return a != b


static func group_for(faction: int) -> String:
	match faction:
		Faction.PLAYER: return GROUP_PLAYER_UNITS
		Faction.ENEMY: return GROUP_ENEMY_UNITS
		_: return GROUP_LOOSE_UNITS


static func layer_for(faction: int) -> int:
	match faction:
		Faction.PLAYER: return LAYER_ALLY
		Faction.ENEMY: return LAYER_ENEMY
		_: return LAYER_ITEM


static func stats_for(role: int) -> Dictionary:
	return ROLE_STATS.get(role, ROLE_STATS[UnitRole.LEGIONARY])


static func role_name(role: int) -> String:
	return String(stats_for(role).get("name", "Unit"))


static func role_short(role: int) -> String:
	return String(stats_for(role).get("short", "UNT"))


## Colour used to tint a unit's armour so factions read at a glance.
static func tint_for(faction: int, role: int) -> Color:
	var base: Color = stats_for(role).get("tint", Color.WHITE)
	match faction:
		Faction.PLAYER:
			return base
		Faction.ENEMY:
			# Shift enemy kit towards a cold blue so a melee scrum stays legible.
			return base.lerp(FACTION_COLORS[Faction.ENEMY], 0.72)
		_:
			return base.lerp(Color(0.82, 0.82, 0.80), 0.65)


## Cycle helper for the player's "next role to throw" selector.
static func next_player_role(current: int, step: int = 1) -> int:
	var idx := PLAYER_ROLES.find(current)
	if idx < 0:
		idx = 0
	idx = wrapi(idx + step, 0, PLAYER_ROLES.size())
	return PLAYER_ROLES[idx]
