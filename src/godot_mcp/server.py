"""Godot MCP Server - Bridge between MCP clients and the Godot 4 editor plugin."""

import httpx
from mcp.server.fastmcp import FastMCP

GODOT_HTTP_URL = "http://127.0.0.1:6789"

mcp = FastMCP("godot-mcp", log_level="INFO")


async def _godot_request(endpoint: str, method: str = "GET", body: dict | None = None) -> dict:
    """Send a request to the Godot HTTP plugin."""
    async with httpx.AsyncClient(base_url=GODOT_HTTP_URL, timeout=10.0) as client:
        if method == "POST":
            resp = await client.post(endpoint, json=body or {})
        else:
            resp = await client.get(endpoint)
        resp.raise_for_status()
        return resp.json()


@mcp.tool()
async def get_editor_state() -> dict:
    """Get the current state of the Godot editor (open scenes, selected nodes, etc.)."""
    return await _godot_request("/editor/state")


@mcp.tool()
async def get_scene_tree(scene_path: str = "") -> dict:
    """Get the scene tree of the currently open scene or a specific scene.

    Args:
        scene_path: Optional path to a specific scene file. If empty, uses the current scene.
    """
    params = f"?path={scene_path}" if scene_path else ""
    return await _godot_request(f"/scene/tree{params}")


@mcp.tool()
async def get_node_properties(node_path: str) -> dict:
    """Get all properties of a node in the current scene.

    Args:
        node_path: The node path in the scene tree (e.g. "Player/Sprite2D").
    """
    return await _godot_request(f"/scene/node?path={node_path}")


@mcp.tool()
async def set_node_property(node_path: str, property_name: str, value: str) -> dict:
    """Set a property on a node in the current scene.

    Args:
        node_path: The node path in the scene tree.
        property_name: The property to set (e.g. "position", "visible").
        value: The value as a JSON-compatible string.
    """
    return await _godot_request("/scene/node/property", method="POST", body={
        "node_path": node_path,
        "property": property_name,
        "value": value,
    })


@mcp.tool()
async def run_scene(scene_path: str = "") -> dict:
    """Run the current scene or a specific scene in the Godot editor.

    Args:
        scene_path: Optional path to the scene to run. If empty, runs the current scene.
    """
    return await _godot_request("/editor/run", method="POST", body={"scene": scene_path})


@mcp.tool()
async def stop_scene() -> dict:
    """Stop the currently running scene."""
    return await _godot_request("/editor/stop", method="POST")


@mcp.tool()
async def execute_script(code: str) -> dict:
    """Execute GDScript code in the editor context.

    Args:
        code: GDScript code to execute.
    """
    return await _godot_request("/script/execute", method="POST", body={"code": code})


@mcp.tool()
async def get_project_files(directory: str = "res://", pattern: str = "*") -> dict:
    """List files in the Godot project directory.

    Args:
        directory: The directory to list (default: project root "res://").
        pattern: Glob pattern to filter files (default: "*").
    """
    return await _godot_request(f"/project/files?dir={directory}&pattern={pattern}")


@mcp.tool()
async def read_script(path: str) -> dict:
    """Read the contents of a GDScript file.

    Args:
        path: Path to the script file (e.g. "res://scripts/player.gd").
    """
    return await _godot_request(f"/script/read?path={path}")


@mcp.tool()
async def write_script(path: str, content: str) -> dict:
    """Write content to a GDScript file.

    Args:
        path: Path to the script file.
        content: The full script content to write.
    """
    return await _godot_request("/script/write", method="POST", body={
        "path": path,
        "content": content,
    })


@mcp.tool()
async def create_node(type: str, name: str = "", parent_path: str = "") -> dict:
    """Create a new node in the current scene.

    Args:
        type: The Godot class name (e.g. "CharacterBody2D", "Sprite2D", "Label").
        name: Optional name for the node. If empty, Godot assigns a default name.
        parent_path: Path to the parent node. If empty, adds to the scene root.
    """
    return await _godot_request("/scene/node/create", method="POST", body={
        "type": type,
        "name": name,
        "parent_path": parent_path,
    })


@mcp.tool()
async def delete_node(node_path: str) -> dict:
    """Delete a node from the current scene.

    Args:
        node_path: The node path in the scene tree (e.g. "Player/OldSprite").
    """
    return await _godot_request("/scene/node/delete", method="POST", body={
        "node_path": node_path,
    })


def main():
    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
