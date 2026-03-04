import asyncio
from agent_factory import create_atomos_deep_agent
from langchain_core.messages import HumanMessage

async def run_test():
    agent = create_atomos_deep_agent("llama3.2", [], "test-1")
    config = {"configurable": {"thread_id": "test-1", "session_id": "test-1"}}
    
    print("Starting stream...")
    async for chunk, metadata in agent.astream(
        {"messages": [HumanMessage(content="Use the task tool to launch a general-purpose agent to research renewable energy.")]},
        config=config,
        stream_mode="messages",
    ):
        node = metadata.get("langgraph_node", "")
        if node == "model":
            print(f"Model Chunk: {chunk.model_dump()}")
        elif node == "tools":
            print(f"Tool Chunk: {chunk.model_dump()}")
        else:
            print(f"Other Node {node}: {chunk}")

asyncio.run(run_test())
