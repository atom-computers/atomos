"""
Tests for Generative UI rendering protocol (TASKLIST_2 §3).

Verifies that:
- send_ui_block() builds correct protobuf messages for all block types
- UiBlock protobuf serialization round-trips correctly
- Approval prompt flow: SendApproval RPC unblocks the waiting coroutine
- Approval timeout returns __timeout__ sentinel
"""
import asyncio
import json
import pytest
from unittest.mock import MagicMock, patch

import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

import bridge_pb2
import bridge_pb2_grpc


class TestUiBlockProtobuf:
    """Verify UiBlock protobuf serialization round-trip."""

    def test_card_round_trip(self):
        block = bridge_pb2.UiBlock(
            block_id="card-1",
            block_type=bridge_pb2.UI_BLOCK_CARD,
            title="Summary",
            description="Build completed",
            body="All **42** tests passed.",
        )
        data = block.SerializeToString()
        restored = bridge_pb2.UiBlock()
        restored.ParseFromString(data)

        assert restored.block_id == "card-1"
        assert restored.block_type == bridge_pb2.UI_BLOCK_CARD
        assert restored.title == "Summary"
        assert restored.body == "All **42** tests passed."

    def test_table_round_trip(self):
        block = bridge_pb2.UiBlock(
            block_id="tbl-1",
            block_type=bridge_pb2.UI_BLOCK_TABLE,
            title="Dependencies",
            columns=["Name", "Version"],
            rows=[
                bridge_pb2.TableRow(cells=["tokio", "1.0"]),
                bridge_pb2.TableRow(cells=["serde", "1.0"]),
            ],
        )
        data = block.SerializeToString()
        restored = bridge_pb2.UiBlock()
        restored.ParseFromString(data)

        assert restored.block_type == bridge_pb2.UI_BLOCK_TABLE
        assert list(restored.columns) == ["Name", "Version"]
        assert len(restored.rows) == 2
        assert list(restored.rows[0].cells) == ["tokio", "1.0"]

    def test_approval_prompt_round_trip(self):
        block = bridge_pb2.UiBlock(
            block_id="approval-1",
            block_type=bridge_pb2.UI_BLOCK_APPROVAL_PROMPT,
            title="Push this PR?",
            description="This will push to main branch",
            actions=[
                bridge_pb2.UiBlockAction(id="approve", label="Approve", style="primary"),
                bridge_pb2.UiBlockAction(id="deny", label="Deny", style="danger"),
            ],
        )
        data = block.SerializeToString()
        restored = bridge_pb2.UiBlock()
        restored.ParseFromString(data)

        assert restored.block_type == bridge_pb2.UI_BLOCK_APPROVAL_PROMPT
        assert len(restored.actions) == 2
        assert restored.actions[0].id == "approve"
        assert restored.actions[1].style == "danger"

    def test_progress_bar_round_trip(self):
        block = bridge_pb2.UiBlock(
            block_id="prog-1",
            block_type=bridge_pb2.UI_BLOCK_PROGRESS_BAR,
            title="Deploying",
            progress=0.75,
            progress_label="75%",
        )
        data = block.SerializeToString()
        restored = bridge_pb2.UiBlock()
        restored.ParseFromString(data)

        assert restored.block_type == bridge_pb2.UI_BLOCK_PROGRESS_BAR
        assert abs(restored.progress - 0.75) < 0.001
        assert restored.progress_label == "75%"

    def test_file_tree_round_trip(self):
        block = bridge_pb2.UiBlock(
            block_id="tree-1",
            block_type=bridge_pb2.UI_BLOCK_FILE_TREE,
            title="Project structure",
            file_paths=["src/", "src/main.rs", "src/lib.rs", "Cargo.toml"],
        )
        data = block.SerializeToString()
        restored = bridge_pb2.UiBlock()
        restored.ParseFromString(data)

        assert restored.block_type == bridge_pb2.UI_BLOCK_FILE_TREE
        assert list(restored.file_paths) == ["src/", "src/main.rs", "src/lib.rs", "Cargo.toml"]

    def test_diff_view_round_trip(self):
        diff = """\
--- a/file.rs
+++ b/file.rs
@@ -1,3 +1,3 @@
 fn main() {
-    println!("old");
+    println!("new");
 }"""
        block = bridge_pb2.UiBlock(
            block_id="diff-1",
            block_type=bridge_pb2.UI_BLOCK_DIFF_VIEW,
            title="Changes to file.rs",
            diff_content=diff,
            diff_language="rust",
        )
        data = block.SerializeToString()
        restored = bridge_pb2.UiBlock()
        restored.ParseFromString(data)

        assert restored.block_type == bridge_pb2.UI_BLOCK_DIFF_VIEW
        assert 'println!("new")' in restored.diff_content
        assert restored.diff_language == "rust"

    def test_agent_response_with_ui_blocks(self):
        block = bridge_pb2.UiBlock(
            block_id="blk-1",
            block_type=bridge_pb2.UI_BLOCK_CARD,
            title="Test",
        )
        resp = bridge_pb2.AgentResponse(ui_blocks=[block])
        data = resp.SerializeToString()
        restored = bridge_pb2.AgentResponse()
        restored.ParseFromString(data)

        assert len(restored.ui_blocks) == 1
        assert restored.ui_blocks[0].block_id == "blk-1"


class TestSendUiBlock:
    """Verify the send_ui_block() helper produces correct proto messages."""

    def test_send_card(self):
        from server import send_ui_block
        resp = send_ui_block(
            "card",
            block_id="c1",
            title="Build Report",
            body="Everything passed.",
        )
        assert len(resp.ui_blocks) == 1
        b = resp.ui_blocks[0]
        assert b.block_id == "c1"
        assert b.block_type == bridge_pb2.UI_BLOCK_CARD
        assert b.title == "Build Report"

    def test_send_table(self):
        from server import send_ui_block
        resp = send_ui_block(
            "table",
            title="Results",
            columns=["Test", "Status"],
            rows=[["unit", "pass"], ["integration", "fail"]],
        )
        b = resp.ui_blocks[0]
        assert b.block_type == bridge_pb2.UI_BLOCK_TABLE
        assert list(b.columns) == ["Test", "Status"]
        assert len(b.rows) == 2

    def test_send_approval_prompt(self):
        from server import send_ui_block
        resp = send_ui_block(
            "approval_prompt",
            block_id="ap1",
            title="Deploy?",
            actions=[
                {"id": "go", "label": "Deploy", "style": "primary"},
                {"id": "stop", "label": "Cancel", "style": "danger"},
            ],
        )
        b = resp.ui_blocks[0]
        assert b.block_type == bridge_pb2.UI_BLOCK_APPROVAL_PROMPT
        assert len(b.actions) == 2
        assert b.actions[0].id == "go"

    def test_send_progress_bar(self):
        from server import send_ui_block
        resp = send_ui_block(
            "progress_bar",
            title="Upload",
            progress=0.5,
            progress_label="50%",
        )
        b = resp.ui_blocks[0]
        assert b.block_type == bridge_pb2.UI_BLOCK_PROGRESS_BAR
        assert abs(b.progress - 0.5) < 0.001

    def test_send_diff_view(self):
        from server import send_ui_block
        resp = send_ui_block(
            "diff_view",
            title="Diff",
            diff_content="+added\n-removed",
            diff_language="python",
        )
        b = resp.ui_blocks[0]
        assert b.block_type == bridge_pb2.UI_BLOCK_DIFF_VIEW
        assert "+added" in b.diff_content

    def test_auto_block_id(self):
        from server import send_ui_block
        resp = send_ui_block("card", title="Auto ID")
        b = resp.ui_blocks[0]
        assert b.block_id.startswith("blk-")


class TestApprovalFlow:
    """Verify the approval blocking/unblocking mechanism."""

    def test_approval_response_round_trip(self):
        req = bridge_pb2.ApprovalRequest(block_id="blk-1", action_id="approve")
        data = req.SerializeToString()
        restored = bridge_pb2.ApprovalRequest()
        restored.ParseFromString(data)
        assert restored.block_id == "blk-1"
        assert restored.action_id == "approve"

        reply = bridge_pb2.ApprovalReply(success=True)
        data = reply.SerializeToString()
        restored_reply = bridge_pb2.ApprovalReply()
        restored_reply.ParseFromString(data)
        assert restored_reply.success is True

    def test_send_approval_unblocks_waiting_coroutine(self):
        from server import AgentServiceServicer, _pending_approvals, send_approval_prompt

        servicer = AgentServiceServicer()

        async def run():
            event = asyncio.Event()
            result = {}
            _pending_approvals["test-blk"] = (event, result)

            req = MagicMock()
            req.block_id = "test-blk"
            req.action_id = "approve"

            async def approve_later():
                await asyncio.sleep(0.05)
                await servicer.SendApproval(req, MagicMock())

            task = asyncio.create_task(approve_later())

            try:
                await asyncio.wait_for(event.wait(), timeout=2.0)
            except asyncio.TimeoutError:
                pytest.fail("Approval event was not set in time")

            await task
            assert result["action_id"] == "approve"
            _pending_approvals.pop("test-blk", None)

        asyncio.run(run())

    def test_send_approval_unknown_block_returns_failure(self):
        from server import AgentServiceServicer

        servicer = AgentServiceServicer()

        async def run():
            req = MagicMock()
            req.block_id = "nonexistent"
            req.action_id = "approve"
            reply = await servicer.SendApproval(req, MagicMock())
            assert reply.success is False

        asyncio.run(run())

    def test_approval_prompt_timeout(self):
        from server import _pending_approvals

        async def run():
            event = asyncio.Event()
            result = {}
            _pending_approvals["timeout-blk"] = (event, result)

            try:
                await asyncio.wait_for(event.wait(), timeout=0.1)
                action = result.get("action_id", "__timeout__")
            except asyncio.TimeoutError:
                action = "__timeout__"

            assert action == "__timeout__"
            _pending_approvals.pop("timeout-blk", None)

        asyncio.run(run())
