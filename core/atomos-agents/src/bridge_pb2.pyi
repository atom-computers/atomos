from google.protobuf.internal import containers as _containers
from google.protobuf import descriptor as _descriptor
from google.protobuf import message as _message
from collections.abc import Iterable as _Iterable
from typing import ClassVar as _ClassVar, Optional as _Optional

DESCRIPTOR: _descriptor.FileDescriptor

class AgentRequest(_message.Message):
    __slots__ = ("prompt", "model", "images", "context")
    PROMPT_FIELD_NUMBER: _ClassVar[int]
    MODEL_FIELD_NUMBER: _ClassVar[int]
    IMAGES_FIELD_NUMBER: _ClassVar[int]
    CONTEXT_FIELD_NUMBER: _ClassVar[int]
    prompt: str
    model: str
    images: _containers.RepeatedScalarFieldContainer[str]
    context: _containers.RepeatedScalarFieldContainer[int]
    def __init__(self, prompt: _Optional[str] = ..., model: _Optional[str] = ..., images: _Optional[_Iterable[str]] = ..., context: _Optional[_Iterable[int]] = ...) -> None: ...

class AgentResponse(_message.Message):
    __slots__ = ("content", "done", "tool_call", "status")
    CONTENT_FIELD_NUMBER: _ClassVar[int]
    DONE_FIELD_NUMBER: _ClassVar[int]
    TOOL_CALL_FIELD_NUMBER: _ClassVar[int]
    STATUS_FIELD_NUMBER: _ClassVar[int]
    content: str
    done: bool
    tool_call: str
    status: str
    def __init__(self, content: _Optional[str] = ..., done: bool = ..., tool_call: _Optional[str] = ..., status: _Optional[str] = ...) -> None: ...
