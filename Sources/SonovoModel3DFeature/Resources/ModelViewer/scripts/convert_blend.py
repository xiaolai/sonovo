"""Headless Blender import/export used by the Sonovo model viewer.

Input and output paths arrive through the environment so neither path is ever
interpolated into a command line. `.blend` files open directly; USD files are
imported and re-exported, which is the fallback when the built-in USD parser
cannot read them. Python auto-execution stays disabled.

The script prints machine-readable markers for the native side:
`SONOVO_BLENDER_VERSION`, `SONOVO_SHAPE_KEYS`, `SONOVO_SCENES`,
`SONOVO_PROCEDURAL_MATERIALS`, and the final `SONOVO_EXPORT_OK`.
"""

import os
import sys

import bpy

# Node types whose look the glTF exporter cannot reproduce faithfully. This is
# a warning list, not a rejection list: geometry and base colors still export.
UNSUPPORTED_MATERIAL_NODES = {
    "TEX_NOISE", "TEX_VORONOI", "TEX_MUSGRAVE", "TEX_WAVE", "TEX_GRADIENT",
    "TEX_MAGIC", "TEX_BRICK", "TEX_CHECKER", "TEX_SKY", "TEX_POINTDENSITY",
    "TEX_GABOR", "TEX_IES", "BSDF_DIFFUSE", "BSDF_GLOSSY",
    "BSDF_TRANSPARENT", "BSDF_TRANSLUCENT", "BSDF_VELVET", "BSDF_TOON",
    "BSDF_HAIR", "BSDF_REFRACTION", "BSDF_SHEEN", "BSDF_METALLIC",
    "EMISSION", "MIX_SHADER", "ADD_SHADER", "ATTRIBUTE", "BEVEL",
    "AMBIENT_OCCLUSION", "WIREFRAME", "LAYER_WEIGHT", "FRESNEL", "CAMERA",
    "LIGHT_PATH", "TANGENT", "OBJECT_INFO",
}

USD_SUFFIXES = {".usd", ".usda", ".usdc", ".usdz"}


def required_environment(name):
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"Missing environment variable: {name}")
    return value


def load_source(source):
    suffix = os.path.splitext(source)[1].lower()
    if suffix == ".blend":
        bpy.ops.wm.open_mainfile(filepath=source, load_ui=False)
        return
    if suffix in USD_SUFFIXES:
        bpy.ops.wm.read_homefile(use_empty=True)
        result = bpy.ops.wm.usd_import(filepath=source)
        if "FINISHED" not in result:
            raise RuntimeError(f"USD import did not finish: {result}")
        return
    raise RuntimeError(f"Unsupported conversion input: {suffix}")


def scene_meshes():
    """Only objects linked to a scene are exported; orphan datablocks are not."""
    return [
        obj for obj in bpy.data.objects
        if obj.type == "MESH" and len(obj.users_scene) > 0
    ]


def has_shape_keys():
    return any(
        obj.data is not None and obj.data.shape_keys is not None
        for obj in scene_meshes()
    )


def material_has_unsupported_nodes(material):
    visited = set()

    def scan(tree):
        if tree in visited:
            return False
        visited.add(tree)
        for node in tree.nodes:
            if node.type in UNSUPPORTED_MATERIAL_NODES:
                return True
            if (
                node.type == "GROUP"
                and node.node_tree is not None
                and scan(node.node_tree)
            ):
                return True
        return False

    return scan(material.node_tree)


def procedural_material_count():
    used = {
        slot.material
        for obj in scene_meshes()
        for slot in obj.material_slots
        if slot.material is not None
    }
    count = 0
    for material in used:
        if not material.use_nodes or material.node_tree is None:
            continue
        if material_has_unsupported_nodes(material):
            count += 1
    return count


def main():
    source = required_environment("SONOVO_BLEND_INPUT")
    output = required_environment("SONOVO_BLEND_OUTPUT")

    if not os.path.isfile(source):
        raise RuntimeError(f"Source file not found: {source}")

    load_source(source)

    mesh_objects = scene_meshes()
    if not mesh_objects:
        raise RuntimeError("The file contains no mesh objects")

    keeps_shape_keys = has_shape_keys()
    procedural_materials = procedural_material_count()

    desired = {
        "filepath": output,
        "export_format": "GLB",
        # Applying modifiers prevents shape-key export. Preserve morph targets
        # when the file has them; otherwise bake modifiers into the mesh.
        "export_apply": not keeps_shape_keys,
        "export_morph": True,
        "export_animations": True,
        "export_yup": True,
        "export_cameras": False,
        "export_lights": False,
        # Export every scene. The viewer lets the user choose one.
        "use_active_scene": False,
        "use_selection": False,
        "export_extras": False,
    }
    available = set(bpy.ops.export_scene.gltf.get_rna_type().properties.keys())
    required_options = (
        "filepath",
        "export_format",
        "export_apply",
        "export_morph",
        "export_animations",
        "export_yup",
        "use_active_scene",
    )
    missing = [key for key in required_options if key not in available]
    if missing:
        raise RuntimeError(
            "The installed Blender's glTF exporter does not support: "
            + ", ".join(missing)
        )
    arguments = {key: value for key, value in desired.items() if key in available}

    result = bpy.ops.export_scene.gltf(**arguments)
    if "FINISHED" not in result:
        raise RuntimeError(f"glTF export did not finish: {result}")

    if not os.path.isfile(output) or os.path.getsize(output) <= 0:
        raise RuntimeError("The glTF exporter produced no output")

    # Print fidelity markers after the exporter's verbose output so they
    # always survive the native side's 8 KiB log tail.
    print(f"SONOVO_BLENDER_VERSION={bpy.app.version_string}")
    print(f"SONOVO_SHAPE_KEYS={1 if keeps_shape_keys else 0}")
    print(f"SONOVO_SCENES={len(bpy.data.scenes)}")
    print(f"SONOVO_PROCEDURAL_MATERIALS={procedural_materials}")
    print("SONOVO_EXPORT_OK")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"SONOVO_EXPORT_FAILED: {error}", file=sys.stderr)
        raise
