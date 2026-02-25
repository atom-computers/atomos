import pytest

@pytest.mark.skip(reason="Security Manager (Section 5) not yet implemented")
@pytest.mark.asyncio
async def test_untrusted_agent_sandbox_stub():
    """Stub for Security Test: Untrusted agent code runs in Kata sandbox -> cannot access host filesystem."""
    pass

@pytest.mark.skip(reason="Security Manager (Section 5) not yet implemented")
@pytest.mark.asyncio
async def test_browser_request_surrealdb_denied_stub():
    """Stub for Security Test: Browser-based request to SurrealDB is denied."""
    pass

@pytest.mark.skip(reason="Security Manager (Section 5) not yet implemented")
@pytest.mark.asyncio
async def test_expired_certificate_rejection_stub():
    """Stub for Security Test: Expired certificate causes connection rejection."""
    pass

@pytest.mark.skip(reason="Security Manager (Section 5) not yet implemented")
@pytest.mark.asyncio
async def test_unapproved_mcp_connection_blocked_stub():
    """Stub for Security Test: Unapproved MCP server connection is blocked."""
    pass
