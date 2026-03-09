"""Godot MCP Server - Bridge between MCP clients and the Godot 4 editor plugin."""

import base64
import httpx
from mcp.server.fastmcp import FastMCP

GODOT_HTTP_URL = "http://127.0.0.1:6789"
ASSET_LIBRARY_URL = "https://godotengine.org/asset-library/api"

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
async def save_scene(path: str = "") -> dict:
    """Save the current scene to disk.

    Args:
        path: Optional file path (e.g. "res://scenes/level.tscn"). If empty, saves to the scene's existing path.
    """
    return await _godot_request("/scene/save", method="POST", body={"path": path})


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


@mcp.tool()
async def get_viewport_screenshot() -> dict:
    """Capture a screenshot of the Godot editor viewport and return it as base64 PNG."""
    return await _godot_request("/viewport/screenshot")


@mcp.tool()
async def get_logs(level: str = "", clear: bool = False) -> dict:
    """Get recent log messages and errors from the Godot editor console.

    Args:
        level: Optional filter: "info", "warning", or "error". If empty, returns all levels.
        clear: If true, clears the log buffer after reading.
    """
    params = []
    if level:
        params.append(f"level={level}")
    if clear:
        params.append("clear=true")
    qs = f"?{'&'.join(params)}" if params else ""
    return await _godot_request(f"/editor/logs{qs}")


@mcp.tool()
async def search_assets(query: str, godot_version: str = "4", category: str = "", page: int = 0, max_results: int = 10, sort: str = "rating") -> dict:
    """Search the Godot Asset Library for assets.

    Args:
        query: Search terms (e.g. "pixel art character", "platformer controller").
        godot_version: Major Godot version filter (default: "4"). Use "3" for Godot 3.x assets.
        category: Optional category filter (e.g. "2D Tools", "Shaders", "Templates").
        page: Page number for pagination (default: 0).
        max_results: Results per page (default: 10, max: 40).
        sort: Sort order: "rating", "name", "updated", or "cost" (default: "rating").
    """
    params = {
        "filter": query,
        "godot_version": godot_version,
        "max_results": min(max_results, 40),
        "page": page,
        "sort": sort,
    }
    if category:
        params["category"] = category
    async with httpx.AsyncClient(timeout=15.0) as client:
        resp = await client.get(f"{ASSET_LIBRARY_URL}/asset", params=params)
        resp.raise_for_status()
        data = resp.json()
    total_pages = data.get("pages", 1)
    total_items = data.get("total_items", 0)
    results = []
    for asset in data.get("result", []):
        results.append({
            "id": asset.get("asset_id"),
            "title": asset.get("title"),
            "description": asset.get("description", ""),
            "author": asset.get("author"),
            "category": asset.get("category"),
            "godot_version": asset.get("godot_version", ""),
            "rating": asset.get("rating"),
            "cost": asset.get("cost", ""),
            "support_level": asset.get("support_level", ""),
            "download_url": asset.get("download_url", ""),
            "icon_url": asset.get("icon_url", ""),
        })
    return {
        "query": query,
        "godot_version": godot_version,
        "page": page,
        "total_pages": total_pages,
        "total_items": total_items,
        "count": len(results),
        "results": results,
    }


@mcp.tool()
async def download_asset(asset_id: int) -> dict:
    """Download and install an asset from the Godot Asset Library into the project.

    Args:
        asset_id: The asset ID from the Godot Asset Library (get it from search_assets).
    """
    async with httpx.AsyncClient(timeout=30.0, follow_redirects=True) as client:
        # Get asset details
        resp = await client.get(f"{ASSET_LIBRARY_URL}/asset/{asset_id}")
        resp.raise_for_status()
        asset_info = resp.json()

        title = asset_info.get("title", f"asset_{asset_id}")
        download_url = asset_info.get("download_url", "")
        if not download_url:
            return {"error": "No download URL found for this asset"}

        # Download the zip
        zip_resp = await client.get(download_url)
        zip_resp.raise_for_status()

    # Send zip to Godot plugin for extraction
    zip_b64 = base64.b64encode(zip_resp.content).decode("ascii")
    # Clean asset name for filesystem
    safe_name = "".join(c if c.isalnum() or c in "-_ " else "" for c in title).strip()
    safe_name = safe_name.replace(" ", "_")

    return await _godot_request("/asset/install", method="POST", body={
        "zip_base64": zip_b64,
        "asset_name": safe_name,
    })


@mcp.tool()
async def preview_asset(path: str) -> dict:
    """Preview an image file from the Godot project (png, jpg, svg). Returns base64 PNG resized to max 512px.

    Args:
        path: Path to the image in the project (e.g. "res://assets/icon.png").
    """
    return await _godot_request(f"/asset/preview?path={path}")


def main():
    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
