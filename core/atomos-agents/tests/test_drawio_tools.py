"""
Tests for the drawio tools (tools/drawio.py).

Covers:
  - Tool registration and discovery via get_drawio_tools()
  - Tool names, descriptions, and argument schemas
  - Handler invocation round-trip (mock drawio_mcp.server functions)
  - JSON parsing for complex parameters (vertices, edges, etc.)
  - Error handling for invalid JSON input
  - Graceful degradation when drawio-mcp is unavailable
  - Integration with tool_registry allowed-tools list
"""

import json
import sys
import types as builtin_types
import pytest
from unittest.mock import MagicMock, patch


# ── helpers ────────────────────────────────────────────────────────────────


def _install_fake_drawio_module():
    """Inject a fake drawio_mcp package into sys.modules so deferred
    imports inside tool functions resolve without the real package."""
    pkg = builtin_types.ModuleType("drawio_mcp")
    server_mod = builtin_types.ModuleType("drawio_mcp.server")

    server_mod.diagram = MagicMock(return_value="diagram result")
    server_mod.draw = MagicMock(return_value="draw result")
    server_mod.style = MagicMock(return_value="style result")
    server_mod.layout = MagicMock(return_value="layout result")
    server_mod.inspect = MagicMock(return_value="inspect result")

    pkg.server = server_mod
    pkg.__version__ = "1.0.2"
    sys.modules["drawio_mcp"] = pkg
    sys.modules["drawio_mcp.server"] = server_mod
    return server_mod


def _uninstall_fake_drawio_module():
    sys.modules.pop("drawio_mcp", None)
    sys.modules.pop("drawio_mcp.server", None)


def _reset_module_state():
    """Reset the drawio module's cached tools list."""
    import tools.drawio as mod
    mod._DRAWIO_TOOLS = None


# ── tool registration ─────────────────────────────────────────────────────


class TestDrawioToolRegistration:

    def test_get_drawio_tools_returns_five_tools(self):
        _install_fake_drawio_module()
        try:
            import tools.drawio as mod
            _reset_module_state()
            result = mod.get_drawio_tools()
            assert len(result) == 5
        finally:
            _uninstall_fake_drawio_module()
            _reset_module_state()

    def test_tool_names_are_namespaced(self):
        _install_fake_drawio_module()
        try:
            import tools.drawio as mod
            _reset_module_state()
            result = mod.get_drawio_tools()
            names = {t.name for t in result}
            assert names == {
                "drawio_diagram",
                "drawio_draw",
                "drawio_style",
                "drawio_layout",
                "drawio_inspect",
            }
        finally:
            _uninstall_fake_drawio_module()
            _reset_module_state()

    def test_diagram_tool_has_action_arg(self):
        from tools.drawio import drawio_diagram
        schema = drawio_diagram.args_schema
        if schema:
            assert "action" in schema.model_fields

    def test_draw_tool_has_expected_args(self):
        from tools.drawio import drawio_draw
        schema = drawio_draw.args_schema
        if schema:
            assert "action" in schema.model_fields
            assert "diagram_name" in schema.model_fields
            assert "vertices_json" in schema.model_fields
            assert "edges_json" in schema.model_fields

    def test_inspect_tool_has_action_arg(self):
        from tools.drawio import drawio_inspect
        schema = drawio_inspect.args_schema
        if schema:
            assert "action" in schema.model_fields

    def test_graceful_when_package_missing(self):
        """get_drawio_tools returns [] when drawio-mcp is not installed."""
        _uninstall_fake_drawio_module()
        import tools.drawio as mod
        _reset_module_state()
        result = mod.get_drawio_tools()
        assert result == []
        _reset_module_state()


# ── diagram lifecycle ─────────────────────────────────────────────────────


class TestDrawioDiagram:

    def test_create_diagram(self):
        fake = _install_fake_drawio_module()
        fake.diagram = MagicMock(return_value="Created diagram 'test'")
        try:
            from tools.drawio import drawio_diagram
            result = drawio_diagram.invoke({
                "action": "create",
                "name": "test",
            })
            assert "Created" in result
            fake.diagram.assert_called_once()
            call_kwargs = fake.diagram.call_args
            assert call_kwargs.kwargs["action"] == "create"
            assert call_kwargs.kwargs["name"] == "test"
        finally:
            _uninstall_fake_drawio_module()

    def test_save_diagram(self):
        fake = _install_fake_drawio_module()
        fake.diagram = MagicMock(return_value="Saved to /tmp/test.drawio")
        try:
            from tools.drawio import drawio_diagram
            result = drawio_diagram.invoke({
                "action": "save",
                "name": "test",
                "file_path": "/tmp/test.drawio",
            })
            assert "Saved" in result
            call_kwargs = fake.diagram.call_args
            assert call_kwargs.kwargs["file_path"] == "/tmp/test.drawio"
        finally:
            _uninstall_fake_drawio_module()

    def test_load_diagram(self):
        fake = _install_fake_drawio_module()
        fake.diagram = MagicMock(return_value="Loaded diagram 'arch'")
        try:
            from tools.drawio import drawio_diagram
            result = drawio_diagram.invoke({
                "action": "load",
                "name": "arch",
                "file_path": "/tmp/arch.drawio",
            })
            assert "Loaded" in result
        finally:
            _uninstall_fake_drawio_module()

    def test_page_format_passed_through(self):
        fake = _install_fake_drawio_module()
        try:
            from tools.drawio import drawio_diagram
            drawio_diagram.invoke({
                "action": "create",
                "name": "wide",
                "page_format": "A4_LANDSCAPE",
            })
            call_kwargs = fake.diagram.call_args
            assert call_kwargs.kwargs["page_format"] == "A4_LANDSCAPE"
        finally:
            _uninstall_fake_drawio_module()


# ── draw content ──────────────────────────────────────────────────────────


class TestDrawioDraw:

    def test_build_dag(self):
        fake = _install_fake_drawio_module()
        fake.draw = MagicMock(return_value='{"cells": ["id1", "id2"]}')
        try:
            from tools.drawio import drawio_draw
            edges = [
                {"source": "Client", "target": "API Gateway"},
                {"source": "API Gateway", "target": "Database"},
            ]
            result = drawio_draw.invoke({
                "action": "build_dag",
                "diagram_name": "arch",
                "edges_json": json.dumps(edges),
                "theme": "BLUE",
                "title": "Architecture",
            })
            assert "cells" in result
            call_kwargs = fake.draw.call_args
            assert call_kwargs.kwargs["action"] == "build_dag"
            assert call_kwargs.kwargs["edges"] == edges
            assert call_kwargs.kwargs["theme"] == "BLUE"
            assert call_kwargs.kwargs["title"] == "Architecture"
        finally:
            _uninstall_fake_drawio_module()

    def test_build_full_with_vertices_and_edges(self):
        fake = _install_fake_drawio_module()
        fake.draw = MagicMock(return_value='{"cells": ["a", "b"]}')
        try:
            from tools.drawio import drawio_draw
            vertices = [
                {"label": "Web App", "x": 100, "y": 50, "style_preset": "BLUE_BOX"},
                {"label": "DB", "x": 100, "y": 200, "style_preset": "DATABASE"},
            ]
            edges = [{"source_id": "a", "target_id": "b"}]
            result = drawio_draw.invoke({
                "action": "build_full",
                "diagram_name": "sys",
                "vertices_json": json.dumps(vertices),
                "edges_json": json.dumps(edges),
                "theme": "GREEN",
            })
            call_kwargs = fake.draw.call_args
            assert call_kwargs.kwargs["vertices"] == vertices
            assert call_kwargs.kwargs["edges"] == edges
        finally:
            _uninstall_fake_drawio_module()

    def test_node_styles_json_parsed(self):
        fake = _install_fake_drawio_module()
        try:
            from tools.drawio import drawio_draw
            node_styles = {"PostgreSQL": "DATABASE", "Client": "USER"}
            drawio_draw.invoke({
                "action": "build_dag",
                "diagram_name": "test",
                "edges_json": json.dumps([{"source": "A", "target": "B"}]),
                "node_styles_json": json.dumps(node_styles),
            })
            call_kwargs = fake.draw.call_args
            assert call_kwargs.kwargs["node_styles"] == node_styles
        finally:
            _uninstall_fake_drawio_module()

    def test_empty_json_params_become_none(self):
        fake = _install_fake_drawio_module()
        try:
            from tools.drawio import drawio_draw
            drawio_draw.invoke({
                "action": "add_title",
                "diagram_name": "test",
                "title": "Hello",
            })
            call_kwargs = fake.draw.call_args
            assert call_kwargs.kwargs["vertices"] is None
            assert call_kwargs.kwargs["edges"] is None
            assert call_kwargs.kwargs["node_styles"] is None
        finally:
            _uninstall_fake_drawio_module()

    def test_invalid_json_returns_error(self):
        _install_fake_drawio_module()
        try:
            from tools.drawio import drawio_draw
            result = drawio_draw.invoke({
                "action": "build_dag",
                "diagram_name": "test",
                "edges_json": "not valid json{{{",
            })
            assert "Error" in result
            assert "Invalid JSON" in result
        finally:
            _uninstall_fake_drawio_module()

    def test_delete_cells_with_ids(self):
        fake = _install_fake_drawio_module()
        fake.draw = MagicMock(return_value="Deleted 2 cells")
        try:
            from tools.drawio import drawio_draw
            ids = ["cell-1", "cell-2"]
            result = drawio_draw.invoke({
                "action": "delete_cells",
                "diagram_name": "test",
                "cell_ids_json": json.dumps(ids),
            })
            assert "Deleted" in result
            call_kwargs = fake.draw.call_args
            assert call_kwargs.kwargs["cell_ids"] == ids
        finally:
            _uninstall_fake_drawio_module()

    def test_direction_and_spacing_passed(self):
        fake = _install_fake_drawio_module()
        try:
            from tools.drawio import drawio_draw
            drawio_draw.invoke({
                "action": "build_dag",
                "diagram_name": "test",
                "edges_json": json.dumps([{"source": "A", "target": "B"}]),
                "direction": "LR",
                "rank_spacing": 150,
                "node_spacing": 80,
            })
            call_kwargs = fake.draw.call_args
            assert call_kwargs.kwargs["direction"] == "LR"
            assert call_kwargs.kwargs["rank_spacing"] == 150
            assert call_kwargs.kwargs["node_spacing"] == 80
        finally:
            _uninstall_fake_drawio_module()


# ── style ─────────────────────────────────────────────────────────────────


class TestDrawioStyle:

    def test_apply_theme(self):
        fake = _install_fake_drawio_module()
        fake.style = MagicMock(return_value="Applied BLUE theme to 5 cells")
        try:
            from tools.drawio import drawio_style
            result = drawio_style.invoke({
                "action": "apply_theme",
                "diagram_name": "test",
                "theme": "BLUE",
            })
            assert "Applied" in result
            call_kwargs = fake.style.call_args
            assert call_kwargs.kwargs["theme"] == "BLUE"
        finally:
            _uninstall_fake_drawio_module()

    def test_list_vertex_presets(self):
        fake = _install_fake_drawio_module()
        fake.style = MagicMock(return_value="RECTANGLE\nELLIPSE\nDATABASE")
        try:
            from tools.drawio import drawio_style
            result = drawio_style.invoke({
                "action": "list_vertex_presets",
            })
            assert "RECTANGLE" in result
        finally:
            _uninstall_fake_drawio_module()

    def test_build_style_string(self):
        fake = _install_fake_drawio_module()
        fake.style = MagicMock(
            return_value="rounded=1;fillColor=#dae8fc;strokeColor=#6c8ebf;"
        )
        try:
            from tools.drawio import drawio_style
            result = drawio_style.invoke({
                "action": "build",
                "rounded": True,
                "fill_color": "#dae8fc",
                "stroke_color": "#6c8ebf",
            })
            assert "fillColor" in result
            call_kwargs = fake.style.call_args
            assert call_kwargs.kwargs["rounded"] is True
            assert call_kwargs.kwargs["fill_color"] == "#dae8fc"
        finally:
            _uninstall_fake_drawio_module()

    def test_cell_ids_json_parsed(self):
        fake = _install_fake_drawio_module()
        try:
            from tools.drawio import drawio_style
            ids = ["cell-a", "cell-b"]
            drawio_style.invoke({
                "action": "apply_theme",
                "diagram_name": "test",
                "theme": "GREEN",
                "cell_ids_json": json.dumps(ids),
            })
            call_kwargs = fake.style.call_args
            assert call_kwargs.kwargs["cell_ids"] == ids
        finally:
            _uninstall_fake_drawio_module()


# ── layout ────────────────────────────────────────────────────────────────


class TestDrawioLayout:

    def test_polish(self):
        fake = _install_fake_drawio_module()
        fake.layout = MagicMock(return_value="Polish complete")
        try:
            from tools.drawio import drawio_layout
            result = drawio_layout.invoke({
                "action": "polish",
                "diagram_name": "test",
            })
            assert "Polish" in result
        finally:
            _uninstall_fake_drawio_module()

    def test_flowchart_with_steps(self):
        fake = _install_fake_drawio_module()
        fake.layout = MagicMock(return_value='{"cells": ["s1", "s2"]}')
        try:
            from tools.drawio import drawio_layout
            steps = [
                {"label": "Start", "type": "terminator"},
                {"label": "Process", "type": "process"},
                {"label": "End", "type": "terminator"},
            ]
            result = drawio_layout.invoke({
                "action": "flowchart",
                "diagram_name": "flow",
                "steps_json": json.dumps(steps),
                "direction": "TB",
            })
            call_kwargs = fake.layout.call_args
            assert call_kwargs.kwargs["steps"] == steps
            assert call_kwargs.kwargs["direction"] == "TB"
        finally:
            _uninstall_fake_drawio_module()

    def test_tree_with_adjacency(self):
        fake = _install_fake_drawio_module()
        try:
            from tools.drawio import drawio_layout
            adjacency = {"CEO": ["CTO", "CFO"], "CTO": ["VP Eng"]}
            drawio_layout.invoke({
                "action": "tree",
                "diagram_name": "org",
                "adjacency_json": json.dumps(adjacency),
                "root": "CEO",
            })
            call_kwargs = fake.layout.call_args
            assert call_kwargs.kwargs["adjacency"] == adjacency
            assert call_kwargs.kwargs["root"] == "CEO"
        finally:
            _uninstall_fake_drawio_module()

    def test_horizontal_with_labels(self):
        fake = _install_fake_drawio_module()
        try:
            from tools.drawio import drawio_layout
            labels = ["Step 1", "Step 2", "Step 3"]
            drawio_layout.invoke({
                "action": "horizontal",
                "diagram_name": "steps",
                "labels_json": json.dumps(labels),
                "connect": True,
            })
            call_kwargs = fake.layout.call_args
            assert call_kwargs.kwargs["labels"] == labels
            assert call_kwargs.kwargs["connect"] is True
        finally:
            _uninstall_fake_drawio_module()

    def test_align_with_cell_ids(self):
        fake = _install_fake_drawio_module()
        try:
            from tools.drawio import drawio_layout
            ids = ["c1", "c2", "c3"]
            drawio_layout.invoke({
                "action": "align",
                "diagram_name": "test",
                "cell_ids_json": json.dumps(ids),
                "alignment": "center",
            })
            call_kwargs = fake.layout.call_args
            assert call_kwargs.kwargs["cell_ids"] == ids
            assert call_kwargs.kwargs["alignment"] == "center"
        finally:
            _uninstall_fake_drawio_module()

    def test_invalid_json_returns_error(self):
        _install_fake_drawio_module()
        try:
            from tools.drawio import drawio_layout
            result = drawio_layout.invoke({
                "action": "tree",
                "diagram_name": "test",
                "adjacency_json": "{bad json",
            })
            assert "Error" in result
            assert "Invalid JSON" in result
        finally:
            _uninstall_fake_drawio_module()


# ── inspect ───────────────────────────────────────────────────────────────


class TestDrawioInspect:

    def test_list_cells(self):
        fake = _install_fake_drawio_module()
        fake.inspect = MagicMock(
            return_value='[{"id": "2", "type": "vertex", "label": "Box"}]'
        )
        try:
            from tools.drawio import drawio_inspect
            result = drawio_inspect.invoke({
                "action": "cells",
                "diagram_name": "test",
            })
            assert "Box" in result
        finally:
            _uninstall_fake_drawio_module()

    def test_check_overlaps(self):
        fake = _install_fake_drawio_module()
        fake.inspect = MagicMock(return_value="No overlaps found")
        try:
            from tools.drawio import drawio_inspect
            result = drawio_inspect.invoke({
                "action": "overlaps",
                "diagram_name": "test",
                "margin": 5,
            })
            assert "No overlaps" in result
            call_kwargs = fake.inspect.call_args
            assert call_kwargs.kwargs["margin"] == 5
        finally:
            _uninstall_fake_drawio_module()

    def test_get_info(self):
        fake = _install_fake_drawio_module()
        fake.inspect = MagicMock(
            return_value='{"pages": 1, "vertices": 4, "edges": 3}'
        )
        try:
            from tools.drawio import drawio_inspect
            result = drawio_inspect.invoke({
                "action": "info",
                "diagram_name": "test",
            })
            assert "pages" in result
        finally:
            _uninstall_fake_drawio_module()


# ── JSON parsing helper ──────────────────────────────────────────────────


class TestParseJson:

    def test_empty_string_returns_none(self):
        from tools.drawio import _parse_json
        assert _parse_json("", "test") is None

    def test_valid_json_list(self):
        from tools.drawio import _parse_json
        result = _parse_json('[{"a": 1}]', "test")
        assert result == [{"a": 1}]

    def test_valid_json_dict(self):
        from tools.drawio import _parse_json
        result = _parse_json('{"key": "value"}', "test")
        assert result == {"key": "value"}

    def test_invalid_json_raises_value_error(self):
        from tools.drawio import _parse_json
        with pytest.raises(ValueError, match="Invalid JSON for test"):
            _parse_json("{not json", "test")


# ── tool_registry integration ─────────────────────────────────────────────


class TestRegistryIntegration:

    def test_drawio_tools_in_allowed_set(self):
        from tool_registry import _ALLOWED_EXPOSED_TOOLS

        assert "drawio_diagram" in _ALLOWED_EXPOSED_TOOLS
        assert "drawio_draw" in _ALLOWED_EXPOSED_TOOLS
        assert "drawio_style" in _ALLOWED_EXPOSED_TOOLS
        assert "drawio_layout" in _ALLOWED_EXPOSED_TOOLS
        assert "drawio_inspect" in _ALLOWED_EXPOSED_TOOLS

    def test_drawio_tools_count_in_allowed_set(self):
        from tool_registry import _ALLOWED_EXPOSED_TOOLS

        drawio_tools = {t for t in _ALLOWED_EXPOSED_TOOLS if t.startswith("drawio_")}
        assert len(drawio_tools) == 5
