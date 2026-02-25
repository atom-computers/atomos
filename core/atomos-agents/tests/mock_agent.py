class MockAgent:
    def __init__(self, model):
        self.model = model
    def bind_tools(self, tools):
        self.tools = tools
        return self
    def stream(self, prompt):
        class MockChunk:
            content = "Mocked Response"
        return [MockChunk()]
