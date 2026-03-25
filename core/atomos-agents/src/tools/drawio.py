"""Draw.io diagram tools for atomos-agents.

Wraps the five tool functions from the ``drawio-mcp`` package as
LangChain tools so the agent can create, edit, style, lay out, and
inspect draw.io diagrams entirely in-process — no subprocess, no MCP
protocol overhead.

Complex parameters (lists of dicts, nested dicts) are accepted as JSON
strings and parsed before delegation so the LLM only needs to construct
flat tool arguments.
"""

from __future__ import annotations

import json
import logging
from typing import Optional

from langchain_core.tools import tool

from tools._shared import parse_json_param as _parse_json

logger = logging.getLogger(__name__)


# ── tools ──────────────────────────────────────────────────────────────────


@tool
def drawio_diagram(
    action: str,
    name: str = "",
    file_path: str = "",
    page_format: str = "A4_PORTRAIT",
    background: str = "none",
    grid: bool = True,
    grid_size: int = 10,
    page_name: str = "",
) -> str:
    """Manage draw.io diagram lifecycle.

    Actions:
      create    — Create a new empty diagram.  Params: name, page_format,
                  background, grid, grid_size.
      save      — Save diagram to a .drawio XML file.  Params: name, file_path.
      load      — Load an existing .drawio file.  Params: name, file_path.
      import_xml — Import raw XML into a diagram.
      list      — List all in-memory diagrams.
      get_xml   — Return the raw XML of a diagram.  Params: name.
      add_page  — Add a page to an existing diagram.  Params: name, page_name.
    """
    from drawio_mcp.server import diagram

    return diagram(
        action=action,
        name=name,
        file_path=file_path,
        page_format=page_format,
        background=background,
        grid=grid,
        grid_size=grid_size,
        page_name=page_name,
    )


@tool
def drawio_draw(
    action: str,
    diagram_name: str = "",
    vertices_json: str = "",
    edges_json: str = "",
    updates_json: str = "",
    cell_ids_json: str = "",
    title: str = "",
    subtitle: str = "",
    legend_entries_json: str = "",
    group_label: str = "",
    group_x: float = 0,
    group_y: float = 0,
    group_width: float = 300,
    group_height: float = 200,
    group_style_preset: str = "SWIMLANE",
    group_custom_style: str = "",
    group_parent_id: str = "1",
    node_styles_json: str = "",
    edge_style_preset: str = "",
    direction: str = "TB",
    rank_spacing: float = 100,
    node_spacing: float = 60,
    theme: str = "",
    page_index: int = 0,
) -> str:
    """Add, update, or delete diagram content.

    Actions:
      add_vertices — Add vertices.  vertices_json: list of
                     {label, x, y, width?, height?, style_preset?}.
      add_edges    — Add edges.  edges_json: list of
                     {source_id, target_id, label?, style_preset?}.
      add_group    — Add a container/group.
      update_cells — Update existing cells.  updates_json: list of
                     {cell_id, label?, style?, x?, y?, width?, height?}.
      delete_cells — Delete cells by ID.  cell_ids_json: list of IDs.
      add_title    — Add title/subtitle text.
      add_legend   — Add a color-coded legend.
      build_dag    — Build a complete auto-laid-out directed graph in ONE
                     call.  edges_json: list of {source, target, label?}.
                     Also accepts node_styles_json, theme, title, direction.
      build_full   — Build a complete manually-positioned diagram in ONE
                     call.  vertices_json + edges_json + theme + title.

    JSON parameters (pass as JSON strings):
      vertices_json      — Vertex list for add_vertices / build_full.
      edges_json         — Edge list for add_edges / build_dag / build_full.
      updates_json       — Update list for update_cells.
      cell_ids_json      — ID list for delete_cells.
      legend_entries_json — Legend entries for add_legend.
      node_styles_json   — Dict mapping labels to style presets (build_dag).
    """
    from drawio_mcp.server import draw

    try:
        vertices = _parse_json(vertices_json, "vertices_json")
        edges = _parse_json(edges_json, "edges_json")
        updates = _parse_json(updates_json, "updates_json")
        cell_ids = _parse_json(cell_ids_json, "cell_ids_json")
        legend_entries = _parse_json(legend_entries_json, "legend_entries_json")
        node_styles = _parse_json(node_styles_json, "node_styles_json")
    except ValueError as exc:
        return f"Error: {exc}"

    return draw(
        action=action,
        diagram_name=diagram_name,
        vertices=vertices,
        edges=edges,
        updates=updates,
        cell_ids=cell_ids,
        title=title,
        subtitle=subtitle,
        legend_entries=legend_entries,
        group_label=group_label,
        group_x=group_x,
        group_y=group_y,
        group_width=group_width,
        group_height=group_height,
        group_style_preset=group_style_preset,
        group_custom_style=group_custom_style,
        group_parent_id=group_parent_id,
        node_styles=node_styles,
        edge_style_preset=edge_style_preset,
        direction=direction,
        rank_spacing=rank_spacing,
        node_spacing=node_spacing,
        theme=theme,
        page_index=page_index,
    )


@tool
def drawio_style(
    action: str,
    diagram_name: str = "",
    base: str = "",
    fill_color: str = "",
    stroke_color: str = "",
    stroke_width: float = 0,
    font_color: str = "",
    font_size: int = 0,
    font_family: str = "",
    bold: bool = False,
    italic: bool = False,
    underline: bool = False,
    rounded: bool = False,
    dashed: bool = False,
    shadow: bool = False,
    opacity: int = 0,
    rotation: float = 0,
    theme: str = "",
    extra_json: str = "",
    cell_ids_json: str = "",
    skip_edges: bool = False,
    page_index: int = 0,
) -> str:
    """Style and appearance management.

    Actions:
      build               — Build a draw.io style string from parameters.
      apply_theme         — Apply a color theme (BLUE, GREEN, DARK, etc.)
                            to all or specific cells.
      list_vertex_presets — List all available vertex style presets.
      list_edge_presets   — List all available edge style presets.
      list_themes         — List all available color themes.

    JSON parameters:
      extra_json    — Extra key=value pairs for build (dict).
      cell_ids_json — Specific cell IDs for apply_theme (list).
    """
    from drawio_mcp.server import style

    try:
        extra = _parse_json(extra_json, "extra_json")
        cell_ids = _parse_json(cell_ids_json, "cell_ids_json")
    except ValueError as exc:
        return f"Error: {exc}"

    return style(
        action=action,
        diagram_name=diagram_name,
        base=base,
        fill_color=fill_color,
        stroke_color=stroke_color,
        stroke_width=stroke_width,
        font_color=font_color,
        font_size=font_size,
        font_family=font_family,
        bold=bold,
        italic=italic,
        underline=underline,
        rounded=rounded,
        dashed=dashed,
        shadow=shadow,
        opacity=opacity,
        rotation=rotation,
        theme=theme,
        extra=extra,
        cell_ids=cell_ids,
        skip_edges=skip_edges,
        page_index=page_index,
    )


@tool
def drawio_layout(
    action: str,
    diagram_name: str = "",
    direction: str = "TB",
    page_index: int = 0,
    adjacency_json: str = "",
    root: str = "",
    connections_json: str = "",
    labels_json: str = "",
    columns: int = 3,
    style_preset: str = "ROUNDED_RECTANGLE",
    custom_style: str = "",
    edge_style_preset: str = "DEFAULT",
    custom_edge_style: str = "",
    edge_labels_json: str = "",
    connect: bool = True,
    start_x: float = 50,
    start_y: float = 50,
    h_spacing: float = 60,
    v_spacing: float = 60,
    width: float = 120,
    height: float = 60,
    steps_json: str = "",
    cell_ids_json: str = "",
    alignment: str = "center",
    dist_direction: str = "horizontal",
    container_id: str = "",
    padding: float = 20,
    margin: float = 20,
    rank_spacing: float = 100,
    node_spacing: float = 60,
) -> str:
    """Layout and positioning operations.

    Actions:
      sugiyama         — Lay out a DAG (Sugiyama algorithm).
      tree             — Lay out a tree from adjacency list.
      horizontal       — Row of connected shapes.
      vertical         — Column of connected shapes.
      grid             — Grid of shapes.
      flowchart        — Create a flowchart from steps.
      smart_connect    — Smart port distribution + obstacle-aware routing.
      align            — Align shapes (left/center/right/top/middle/bottom).
      distribute       — Distribute shapes evenly.
      polish           — One-click cleanup of the entire diagram.
      relayout         — Reorganize existing diagram.
      compact          — Remove excess whitespace.
      reroute_edges    — Reroute edges around obstacles.
      resolve_overlaps — Push apart overlapping shapes.
      fix_labels       — Fix edge label collisions.
      optimize_connections — Optimize all edge paths.
      resize_container — Auto-size a container to fit children.

    JSON parameters:
      adjacency_json   — Dict mapping parent → children (tree).
      connections_json — List of {source, target, label?} (sugiyama).
      labels_json      — List of label strings (horizontal/vertical/grid).
      edge_labels_json — List of edge label strings.
      steps_json       — List of {label, type?} (flowchart).
      cell_ids_json    — List of cell IDs (align/distribute).
    """
    from drawio_mcp.server import layout as _layout

    try:
        adjacency = _parse_json(adjacency_json, "adjacency_json")
        connections = _parse_json(connections_json, "connections_json")
        labels = _parse_json(labels_json, "labels_json")
        edge_labels = _parse_json(edge_labels_json, "edge_labels_json")
        steps = _parse_json(steps_json, "steps_json")
        cell_ids = _parse_json(cell_ids_json, "cell_ids_json")
    except ValueError as exc:
        return f"Error: {exc}"

    return _layout(
        action=action,
        diagram_name=diagram_name,
        direction=direction,
        page_index=page_index,
        adjacency=adjacency,
        root=root,
        connections=connections,
        labels=labels,
        columns=columns,
        style_preset=style_preset,
        custom_style=custom_style,
        edge_style_preset=edge_style_preset,
        custom_edge_style=custom_edge_style,
        edge_labels=edge_labels,
        connect=connect,
        start_x=start_x,
        start_y=start_y,
        h_spacing=h_spacing,
        v_spacing=v_spacing,
        width=width,
        height=height,
        steps=steps,
        cell_ids=cell_ids,
        alignment=alignment,
        dist_direction=dist_direction,
        container_id=container_id,
        padding=padding,
        margin=margin,
        rank_spacing=rank_spacing,
        node_spacing=node_spacing,
    )


@tool
def drawio_inspect(
    action: str,
    diagram_name: str = "",
    margin: float = 0,
    page_index: int = 0,
) -> str:
    """Read-only inspection of diagrams.

    Actions:
      cells    — List all cells with IDs, types, labels, positions.
      overlaps — Check for overlapping shapes.
      ports    — List available connection port positions.
      info     — Get diagram summary (page count, cell counts).
    """
    from drawio_mcp.server import inspect as _inspect

    return _inspect(
        action=action,
        diagram_name=diagram_name,
        margin=margin,
        page_index=page_index,
    )


# ── registration helper ───────────────────────────────────────────────────

_DRAWIO_TOOLS = None


def get_drawio_tools() -> list:
    """Return all drawio tools.  Returns ``[]`` if the ``drawio-mcp``
    package is not installed."""
    global _DRAWIO_TOOLS
    if _DRAWIO_TOOLS is not None:
        return _DRAWIO_TOOLS

    try:
        import drawio_mcp  # noqa: F401 — verify importable
        _DRAWIO_TOOLS = [
            drawio_diagram,
            drawio_draw,
            drawio_style,
            drawio_layout,
            drawio_inspect,
        ]
    except ImportError:
        logger.warning(
            "drawio-mcp not installed — drawio tools unavailable.  "
            "Install with: pip install 'drawio-mcp>=1.0.0'"
        )
        _DRAWIO_TOOLS = []

    return _DRAWIO_TOOLS
