<p align="center">
  <img src="https://img.shields.io/badge/Godot-4.x-478CBF?style=for-the-badge&logo=godotengine&logoColor=white" alt="Godot 4">
  <img src="https://img.shields.io/badge/MCP-compatible-8A2BE2?style=for-the-badge" alt="MCP">
  <img src="https://img.shields.io/badge/Python-3.10+-3776AB?style=for-the-badge&logo=python&logoColor=white" alt="Python 3.10+">
  <img src="https://img.shields.io/badge/License-MIT-green?style=for-the-badge" alt="License">
  <img src="https://img.shields.io/badge/version-0.1.0-blue?style=for-the-badge" alt="Version">
</p>

# Godot MCP

> Control the Godot 4 editor from Claude Code (or any MCP client) via the Model Context Protocol.

**Godot MCP** is a bridge between AI assistants and the Godot 4 engine. It exposes 14 tools that let you inspect scenes, create nodes, modify properties, capture screenshots, and manage project files — all without leaving your terminal.

## Architecture

```
┌─────────────┐       stdio        ┌─────────────────┐      HTTP       ┌──────────────────┐
│  MCP Client │◄──────────────────►│  godot-mcp       │◄──────────────►│  Godot 4 Editor  │
│ (Claude Code)│                    │  (Python server) │  localhost:6789 │  (Editor Plugin) │
└─────────────┘                    └─────────────────┘                 └──────────────────┘
```

The system has two components:

1. **MCP Server** (Python) — Receives tool calls via stdio, translates them into HTTP requests
2. **Editor Plugin** (GDScript) — Runs inside Godot 4, exposes an HTTP API on `127.0.0.1:6789`

## Installation

### 1. Install the Python package

```bash
cd godot-mcp
pip install -e .
```

### 2. Install the Godot plugin

Copy the plugin folder into your Godot project:

```bash
cp -r godot_plugin/addons/godot_mcp /path/to/your/godot-project/addons/
```

Then in Godot: **Project → Project Settings → Plugins → Enable "Godot MCP"**

### 3. Configure Claude Code

Add to your Claude Code MCP settings (`~/.claude.json` or project config):

```json
{
  "mcpServers": {
    "godot-mcp": {
      "command": "godot-mcp",
      "type": "stdio"
    }
  }
}
```

## Available Tools

| Tool | Description |
|------|-------------|
| `get_editor_state` | Get current editor state (open scenes, selected nodes) |
| `get_scene_tree` | Get the full scene tree hierarchy |
| `get_node_properties` | Get all properties of a specific node |
| `set_node_property` | Modify a node property in real-time |
| `create_node` | Create a new node (any Godot class) in the scene tree |
| `delete_node` | Remove a node from the scene tree |
| `save_scene` | Save the current scene to disk |
| `run_scene` | Run the current or a specific scene |
| `stop_scene` | Stop the running scene |
| `execute_script` | Execute GDScript code in editor context |
| `get_project_files` | List project files with glob pattern filtering |
| `read_script` | Read the contents of a GDScript file |
| `write_script` | Write or modify a GDScript file |
| `get_viewport_screenshot` | Capture the editor viewport as base64 PNG |

## Usage Example

Once both the Godot plugin is enabled and Claude Code is configured, you can interact with your Godot project naturally:

```
You: "Show me the scene tree of the current scene"
Claude: [calls get_scene_tree] → returns the full node hierarchy

You: "Move the Player node to position (100, 200)"
Claude: [calls set_node_property("Player", "position", "Vector2(100, 200)")]

You: "Run the game and check if it works"
Claude: [calls run_scene] → launches the scene in Godot

You: "Create a new script that makes the player jump"
Claude: [calls write_script("res://scripts/player.gd", "...GDScript code...")]
```

## Requirements

- **Godot 4.x** with the editor plugin enabled
- **Python 3.10+**
- Dependencies: `mcp >= 1.0.0`, `httpx >= 0.27.0`

## Project Structure

```
godot-mcp/
├── src/godot_mcp/
│   ├── __init__.py
│   └── server.py            # MCP server (10 tools)
├── godot_plugin/addons/godot_mcp/
│   ├── plugin.cfg            # Plugin metadata
│   ├── plugin.gd             # Plugin entry point
│   └── godot_mcp_server.gd   # HTTP server (GDScript)
└── pyproject.toml
```

## License

MIT
