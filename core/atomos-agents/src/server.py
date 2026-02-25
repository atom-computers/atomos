import asyncio
import logging
from concurrent import futures
import grpc

import bridge_pb2
import bridge_pb2_grpc
from agent_factory import create_deep_agent
from langchain_core.messages import HumanMessage

class AgentServiceServicer(bridge_pb2_grpc.AgentServiceServicer):
    
    def StreamAgentTurn(self, request, context):
        llm = create_deep_agent(request.model, request.context)
        
        # We process this synchronously for now because grpcio's basic servicer is sync unless we use grpc.aio
        # LangChain provides `stream`
        try:
            chunks = llm.stream([HumanMessage(content=request.prompt)])
            for chunk in chunks:
                yield bridge_pb2.AgentResponse(
                    content=str(chunk.content),
                    done=False,
                    status="Thinking..."
                )
            
            yield bridge_pb2.AgentResponse(
                content="",
                done=True,
                status="Done"
            )
        except Exception as e:
            logging.error(f"Error during streaming: {e}")
            yield bridge_pb2.AgentResponse(
                content=str(e),
                done=True,
                status="Error"
            )

def serve():
    import os
    port = os.environ.get("PORT", "50051")
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=10))
    bridge_pb2_grpc.add_AgentServiceServicer_to_server(AgentServiceServicer(), server)
    server.add_insecure_port(f'[::]:{port}')
    logging.info(f"Agent Server starting on port {port}...")
    server.start()
    server.wait_for_termination()

if __name__ == '__main__':
    logging.basicConfig(level=logging.INFO)
    serve()
