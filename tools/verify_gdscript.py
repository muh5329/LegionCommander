#!/usr/bin/env python3
"""Static checks for this project's GDScript, tuned to the errors Godot 4
actually refuses to compile.

Run from the project root:

    python3 tools/verify_gdscript.py

This is not a GDScript parser. It targets a specific short list of mistakes
that are easy to make, invisible on inspection, and hard-fail at load time:

  1. `:=` inference from an untyped loop variable      -> Parse Error
  2. a local shadowing a method in the same class      -> SHADOWED_VARIABLE
  3. a local/param shadowing a base-class property     -> SHADOWED_VARIABLE_BASE_CLASS
  4. a subclass redeclaring a base-class variable      -> Parse Error
  5. calls to project methods not in the class chain   -> runtime "nonexistent function"
  6. missing res:// resources in scenes and preloads   -> load failure
  7. structural damage (indent, empty blocks, brackets)

Exit code is non-zero when anything in the ERROR class is found.
"""

from __future__ import annotations

import re
import sys
from collections import defaultdict
from pathlib import Path

SKIP_DIRS = {".godot", "addons", "tools"}

# Properties on the Godot base classes we actually inherit from. Declaring a
# local, parameter or member with one of these names triggers
# SHADOWED_VARIABLE_BASE_CLASS.
ENGINE_PROPERTIES = {
    "Node": {"name", "owner", "scene_file_path", "process_mode", "multiplayer"},
    "Node3D": {"position", "rotation", "scale", "transform", "basis", "visible",
               "global_position", "global_rotation", "global_transform", "top_level",
               "quaternion", "rotation_degrees"},
    "CharacterBody3D": {"velocity", "motion_mode", "up_direction", "slide_on_ceiling",
                        "floor_max_angle", "floor_snap_length", "safe_margin"},
    "CollisionObject3D": {"collision_layer", "collision_mask", "input_ray_pickable"},
    "Area3D": {"monitoring", "monitorable", "gravity", "priority"},
    "Label3D": {"text", "font_size", "modulate", "outline_size", "pixel_size",
                "billboard", "shaded", "double_sided", "no_depth_test"},
    "Control": {"size", "position", "anchor_left", "anchor_top", "theme",
                "mouse_filter", "tooltip_text", "layout_mode"},
    "RefCounted": set(),
}


def gd_files(root: Path):
    for p in sorted(root.rglob("*.gd")):
        if SKIP_DIRS & set(p.parts):
            continue
        yield p


def tscn_files(root: Path):
    for p in sorted(root.rglob("*.tscn")):
        if SKIP_DIRS & set(p.parts):
            continue
        yield p


def strip_strings_and_comments(text: str) -> str:
    text = re.sub(r'"[^"\n]*"', '""', text)
    return re.sub(r"#.*", "", text)


def indent_of(line: str) -> int:
    return len(line) - len(line.lstrip("\t"))


def strip_call_arguments(expr: str) -> str:
    """Remove the contents of call parentheses, keeping grouping parentheses.

    A Variant passed *as an argument* does not make the result Variant - the
    type comes from the callee. But a Variant inside a grouping paren does:
    `(unit.pos - here).normalized()` is Variant all the way out. Telling those
    two apart is the whole game when predicting `:=` inference failures.
    """
    out = []
    i = 0
    while i < len(expr):
        ch = expr[i]
        if ch == "(" and i > 0 and (expr[i - 1].isalnum() or expr[i - 1] == "_"):
            depth = 1
            i += 1
            while i < len(expr) and depth:
                if expr[i] == "(":
                    depth += 1
                elif expr[i] == ")":
                    depth -= 1
                i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def rhs_is_variant(rhs: str, loop_var: str) -> bool:
    """True when `loop_var` still contributes to the *type* of `rhs`."""
    rhs = re.sub(r'"[^"]*"', '""', rhs)          # string literals aren't refs
    if re.search(r"\bas\s+[A-Z]\w*", rhs):        # explicit cast pins the type
        return False
    reduced = strip_call_arguments(rhs)
    return bool(re.search(rf"\b{re.escape(loop_var)}\b", reduced))


def build_class_table(sources: dict[Path, str]) -> dict:
    table = {}
    for path, text in sources.items():
        cn = re.search(r"^class_name\s+(\w+)", text, re.M)
        if not cn:
            continue
        ext = re.search(r"^extends\s+(\w+)", text, re.M)
        table[cn.group(1)] = {
            "parent": ext.group(1) if ext else None,
            "funcs": set(re.findall(r"^(?:static )?func (\w+)", text, re.M)),
            "vars": set(
                re.findall(
                    r"^(?:@\w+(?:\([^)]*\))?\s*\n?)*(?:var|const)\s+(\w+)", text, re.M
                )
            ),
            "signals": set(re.findall(r"^signal (\w+)", text, re.M)),
            "enums": set(re.findall(r"^enum (\w+)", text, re.M)),
            "file": path,
        }
    return table


def chain(table, name, key, depth=0) -> set:
    if depth > 8 or name not in table:
        return set()
    return table[name][key] | chain(table, table[name]["parent"], key, depth + 1)


def engine_props_for(table, name, depth=0) -> set:
    if depth > 8 or name is None:
        return set()
    if name in ENGINE_PROPERTIES:
        base = ENGINE_PROPERTIES[name]
        # Node3D etc. also inherit Node's properties.
        inherited = {
            "Node3D": "Node", "CharacterBody3D": "Node3D", "Area3D": "Node3D",
            "Label3D": "Node3D", "Control": "Node", "CollisionObject3D": "Node3D",
        }.get(name)
        return base | engine_props_for(table, inherited, depth + 1)
    if name in table:
        return engine_props_for(table, table[name]["parent"], depth + 1)
    return set()


def check(root: Path):
    errors: list[str] = []
    warnings: list[str] = []

    sources = {p: p.read_text() for p in gd_files(root)}
    table = build_class_table(sources)

    all_project_funcs = set()
    for info in table.values():
        all_project_funcs |= info["funcs"]

    file_to_class = {info["file"]: cname for cname, info in table.items()}

    for path, text in sources.items():
        lines = text.split("\n")
        cname = file_to_class.get(path)
        own_funcs = set(re.findall(r"^(?:static )?func (\w+)", text, re.M))
        rel = path.relative_to(root)

        # --- 1. `:=` inference from an untyped loop variable ----------------
        # `for x in <anything untyped>` makes x a Variant; any `var y := ...x...`
        # inside the loop is a hard parse error.
        untyped_loop_vars: dict[str, int] = {}
        for i, line in enumerate(lines, 1):
            m = re.match(r"\s*for (\w+)(\s*:\s*\w+)? in (.+):", line)
            if m:
                var, typed, source = m.group(1), m.group(2), m.group(3)
                if typed:
                    untyped_loop_vars.pop(var, None)
                elif source.strip().startswith("range("):
                    untyped_loop_vars.pop(var, None)
                else:
                    untyped_loop_vars[var] = i
            m2 = re.match(r"\s*var (\w+) := (.+)$", line)
            if m2 and untyped_loop_vars:
                for var, decl_line in untyped_loop_vars.items():
                    if rhs_is_variant(m2.group(2), var):
                        errors.append(
                            f"{rel}:{i} PARSE: `var {m2.group(1)} :=` infers from "
                            f"untyped loop var '{var}' (declared line {decl_line}). "
                            f"Type the loop (`for {var}: T in ...`) or annotate."
                        )

        # --- 2. local shadowing a method in the same class ------------------
        for i, line in enumerate(lines, 1):
            m = re.match(r"\s*var (\w+)\s*[:=]", line)
            if m and m.group(1) in own_funcs:
                errors.append(
                    f"{rel}:{i} SHADOWED_VARIABLE: local '{m.group(1)}' shadows "
                    f"the method {m.group(1)}() in this class."
                )

        # --- 3. local/param shadowing a base-class property -----------------
        if cname:
            engine = engine_props_for(table, table[cname]["parent"])
            for i, line in enumerate(lines, 1):
                m = re.match(r"\s+var (\w+)\s*[:=]", line)
                if m and m.group(1) in engine:
                    warnings.append(
                        f"{rel}:{i} SHADOWED_VARIABLE_BASE_CLASS: local "
                        f"'{m.group(1)}' shadows a base-class property."
                    )
                fm = re.match(r"\s*(?:static )?func \w+\(([^)]*)\)", line)
                if fm:
                    for param in fm.group(1).split(","):
                        pname = param.split(":")[0].split("=")[0].strip()
                        if pname and pname in engine:
                            warnings.append(
                                f"{rel}:{i} SHADOWED_VARIABLE_BASE_CLASS: param "
                                f"'{pname}' shadows a base-class property."
                            )

        # --- 7. structure ---------------------------------------------------
        for i, line in enumerate(lines, 1):
            if line.startswith(" ") and line.strip():
                errors.append(f"{rel}:{i} INDENT: leading space (project uses tabs).")
            code = re.sub(r"#.*", "", line).rstrip()
            if not code.endswith(":") or re.match(r"^\s*(var|const)\s", code):
                continue
            j = i  # lines is 0-based here; i is 1-based so lines[i] is the next line
            while j < len(lines) and (
                not lines[j].strip() or lines[j].strip().startswith("#")
            ):
                j += 1
            if j >= len(lines) or indent_of(lines[j]) <= indent_of(code):
                errors.append(f"{rel}:{i} EMPTY BLOCK: {code.strip()[:60]!r}")

        stripped = strip_strings_and_comments(text)
        for open_c, close_c in [("(", ")"), ("[", "]"), ("{", "}")]:
            if stripped.count(open_c) != stripped.count(close_c):
                errors.append(
                    f"{rel} UNBALANCED {open_c}{close_c}: "
                    f"{stripped.count(open_c)} vs {stripped.count(close_c)}"
                )

        # --- 6. preload / load paths ---------------------------------------
        for m in re.finditer(r'(?:pre)?load\("res://([^"]+)"\)', text):
            if not (root / m.group(1)).exists():
                errors.append(f"{rel} MISSING RESOURCE: res://{m.group(1)}")

    # --- 4. subclass redeclaring a base-class variable ----------------------
    for cname, info in table.items():
        parent = info["parent"]
        if parent in table:
            for dup in info["vars"] & chain(table, parent, "vars"):
                errors.append(
                    f"{info['file'].relative_to(root)} SHADOW: '{dup}' redeclares "
                    f"{parent}.{dup}"
                )

    # --- 5. cross-class member + moved-method resolution --------------------
    for path, text in sources.items():
        rel = path.relative_to(root)
        for m in re.finditer(r"\b([A-Z]\w+)\.(\w+)", text):
            klass, member = m.group(1), m.group(2)
            if klass not in table:
                continue
            known = (
                chain(table, klass, "funcs")
                | chain(table, klass, "vars")
                | chain(table, klass, "signals")
                | chain(table, klass, "enums")
            )
            if member not in known and member not in {"new", "keys", "values", "instantiate"}:
                errors.append(f"{rel} UNRESOLVED: {klass}.{member}")

        cname = file_to_class.get(path)
        if not cname:
            continue
        reachable = chain(table, cname, "funcs")
        for m in re.finditer(r"(?<![.\w])(_?[a-z]\w*)\(", text):
            fn = m.group(1)
            if fn in reachable or fn not in all_project_funcs:
                continue
            errors.append(
                f"{rel} MOVED?: {fn}() is defined in the project but not "
                f"reachable from {cname}."
            )

    # --- 6. scene resource paths -------------------------------------------
    for path in tscn_files(root):
        text = path.read_text()
        rel = path.relative_to(root)
        for m in re.finditer(r'path="res://([^"]+)"', text):
            if not (root / m.group(1)).exists():
                errors.append(f"{rel} MISSING RESOURCE: res://{m.group(1)}")
        declared_sub = set(re.findall(r'\[sub_resource type="[^"]+" id="([^"]+)"\]', text))
        for m in re.finditer(r'SubResource\("([^"]+)"\)', text):
            if m.group(1) not in declared_sub:
                errors.append(f"{rel} UNDECLARED SubResource: {m.group(1)}")
        declared_ext = set(re.findall(r'\[ext_resource [^\]]*id="([^"]+)"\]', text))
        for m in re.finditer(r'ExtResource\("([^"]+)"\)', text):
            if m.group(1) not in declared_ext:
                errors.append(f"{rel} UNDECLARED ExtResource: {m.group(1)}")

    return sorted(set(errors)), sorted(set(warnings))


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    errors, warnings = check(root)

    for w in warnings:
        print(f"  warn  {w}")
    for e in errors:
        print(f"  ERROR {e}")

    print()
    print(f"{len(errors)} error(s), {len(warnings)} warning(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
