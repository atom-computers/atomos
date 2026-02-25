import logging
from langchain_community.chat_models import ChatOllama
from langchain_core.messages import HumanMessage, SystemMessage
from langchain_core.tools import tool

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

@tool
def check_sync_status(file_path: str) -> str:
    """Check the sync status of a file using SurrealDB mapping."""
    # Stub implementation for testing tool binding
    return f"File {file_path} is synced."

@tool
def retrieve_context(project_name: str) -> str:
    """Retrieve contextual embeddings from the Context Manager."""
    return f"Context for {project_name} loaded."

def create_deep_agent(model_name: str, context_ids: list[int] = None):
    """
    Creates a LangChain deep agent configured for Atom OS.
    """
    logger.info(f"Creating deep agent for model: {model_name}")
    
    # Initialize basic model
    llm = ChatOllama(model=model_name)
    
    # Bind tools to the agent
    tools = [check_sync_status, retrieve_context]
    
    # Langchain ollama may not support tool binding perfectly in older versions,
    # but for architecture validation we bind it.
    if hasattr(llm, "bind_tools"):
        try:
            llm = llm.bind_tools(tools)
        except NotImplementedError:
            logger.warning("bind_tools not implemented for this model, skipping tool binding for now")
            pass
        
    return llm
