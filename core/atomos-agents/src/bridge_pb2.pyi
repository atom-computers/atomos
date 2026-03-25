from google.protobuf.internal import containers as _containers
from google.protobuf.internal import enum_type_wrapper as _enum_type_wrapper
from google.protobuf import descriptor as _descriptor
from google.protobuf import message as _message
from collections.abc import Iterable as _Iterable, Mapping as _Mapping
from typing import ClassVar as _ClassVar, Optional as _Optional, Union as _Union

DESCRIPTOR: _descriptor.FileDescriptor

class UiBlockType(int, metaclass=_enum_type_wrapper.EnumTypeWrapper):
    __slots__ = ()
    UI_BLOCK_CARD: _ClassVar[UiBlockType]
    UI_BLOCK_TABLE: _ClassVar[UiBlockType]
    UI_BLOCK_APPROVAL_PROMPT: _ClassVar[UiBlockType]
    UI_BLOCK_PROGRESS_BAR: _ClassVar[UiBlockType]
    UI_BLOCK_FILE_TREE: _ClassVar[UiBlockType]
    UI_BLOCK_DIFF_VIEW: _ClassVar[UiBlockType]
UI_BLOCK_CARD: UiBlockType
UI_BLOCK_TABLE: UiBlockType
UI_BLOCK_APPROVAL_PROMPT: UiBlockType
UI_BLOCK_PROGRESS_BAR: UiBlockType
UI_BLOCK_FILE_TREE: UiBlockType
UI_BLOCK_DIFF_VIEW: UiBlockType

class ChatMessage(_message.Message):
    __slots__ = ("role", "content")
    ROLE_FIELD_NUMBER: _ClassVar[int]
    CONTENT_FIELD_NUMBER: _ClassVar[int]
    role: str
    content: str
    def __init__(self, role: _Optional[str] = ..., content: _Optional[str] = ...) -> None: ...

class AgentRequest(_message.Message):
    __slots__ = ("prompt", "model", "images", "context", "history", "thread_id")
    PROMPT_FIELD_NUMBER: _ClassVar[int]
    MODEL_FIELD_NUMBER: _ClassVar[int]
    IMAGES_FIELD_NUMBER: _ClassVar[int]
    CONTEXT_FIELD_NUMBER: _ClassVar[int]
    HISTORY_FIELD_NUMBER: _ClassVar[int]
    THREAD_ID_FIELD_NUMBER: _ClassVar[int]
    prompt: str
    model: str
    images: _containers.RepeatedScalarFieldContainer[str]
    context: _containers.RepeatedScalarFieldContainer[int]
    history: _containers.RepeatedCompositeFieldContainer[ChatMessage]
    thread_id: str
    def __init__(self, prompt: _Optional[str] = ..., model: _Optional[str] = ..., images: _Optional[_Iterable[str]] = ..., context: _Optional[_Iterable[int]] = ..., history: _Optional[_Iterable[_Union[ChatMessage, _Mapping]]] = ..., thread_id: _Optional[str] = ...) -> None: ...

class AgentResponse(_message.Message):
    __slots__ = ("content", "done", "tool_call", "status", "credential_required", "terminal_event", "ui_blocks")
    CONTENT_FIELD_NUMBER: _ClassVar[int]
    DONE_FIELD_NUMBER: _ClassVar[int]
    TOOL_CALL_FIELD_NUMBER: _ClassVar[int]
    STATUS_FIELD_NUMBER: _ClassVar[int]
    CREDENTIAL_REQUIRED_FIELD_NUMBER: _ClassVar[int]
    TERMINAL_EVENT_FIELD_NUMBER: _ClassVar[int]
    UI_BLOCKS_FIELD_NUMBER: _ClassVar[int]
    content: str
    done: bool
    tool_call: str
    status: str
    credential_required: str
    terminal_event: str
    ui_blocks: _containers.RepeatedCompositeFieldContainer[UiBlock]
    def __init__(self, content: _Optional[str] = ..., done: bool = ..., tool_call: _Optional[str] = ..., status: _Optional[str] = ..., credential_required: _Optional[str] = ..., terminal_event: _Optional[str] = ..., ui_blocks: _Optional[_Iterable[_Union[UiBlock, _Mapping]]] = ...) -> None: ...

class UiBlockAction(_message.Message):
    __slots__ = ("id", "label", "style")
    ID_FIELD_NUMBER: _ClassVar[int]
    LABEL_FIELD_NUMBER: _ClassVar[int]
    STYLE_FIELD_NUMBER: _ClassVar[int]
    id: str
    label: str
    style: str
    def __init__(self, id: _Optional[str] = ..., label: _Optional[str] = ..., style: _Optional[str] = ...) -> None: ...

class TableRow(_message.Message):
    __slots__ = ("cells",)
    CELLS_FIELD_NUMBER: _ClassVar[int]
    cells: _containers.RepeatedScalarFieldContainer[str]
    def __init__(self, cells: _Optional[_Iterable[str]] = ...) -> None: ...

class UiBlock(_message.Message):
    __slots__ = ("block_id", "block_type", "title", "description", "body", "columns", "rows", "actions", "progress", "progress_label", "file_paths", "diff_content", "diff_language")
    BLOCK_ID_FIELD_NUMBER: _ClassVar[int]
    BLOCK_TYPE_FIELD_NUMBER: _ClassVar[int]
    TITLE_FIELD_NUMBER: _ClassVar[int]
    DESCRIPTION_FIELD_NUMBER: _ClassVar[int]
    BODY_FIELD_NUMBER: _ClassVar[int]
    COLUMNS_FIELD_NUMBER: _ClassVar[int]
    ROWS_FIELD_NUMBER: _ClassVar[int]
    ACTIONS_FIELD_NUMBER: _ClassVar[int]
    PROGRESS_FIELD_NUMBER: _ClassVar[int]
    PROGRESS_LABEL_FIELD_NUMBER: _ClassVar[int]
    FILE_PATHS_FIELD_NUMBER: _ClassVar[int]
    DIFF_CONTENT_FIELD_NUMBER: _ClassVar[int]
    DIFF_LANGUAGE_FIELD_NUMBER: _ClassVar[int]
    block_id: str
    block_type: UiBlockType
    title: str
    description: str
    body: str
    columns: _containers.RepeatedScalarFieldContainer[str]
    rows: _containers.RepeatedCompositeFieldContainer[TableRow]
    actions: _containers.RepeatedCompositeFieldContainer[UiBlockAction]
    progress: float
    progress_label: str
    file_paths: _containers.RepeatedScalarFieldContainer[str]
    diff_content: str
    diff_language: str
    def __init__(self, block_id: _Optional[str] = ..., block_type: _Optional[_Union[UiBlockType, str]] = ..., title: _Optional[str] = ..., description: _Optional[str] = ..., body: _Optional[str] = ..., columns: _Optional[_Iterable[str]] = ..., rows: _Optional[_Iterable[_Union[TableRow, _Mapping]]] = ..., actions: _Optional[_Iterable[_Union[UiBlockAction, _Mapping]]] = ..., progress: _Optional[float] = ..., progress_label: _Optional[str] = ..., file_paths: _Optional[_Iterable[str]] = ..., diff_content: _Optional[str] = ..., diff_language: _Optional[str] = ...) -> None: ...

class ApprovalRequest(_message.Message):
    __slots__ = ("block_id", "action_id")
    BLOCK_ID_FIELD_NUMBER: _ClassVar[int]
    ACTION_ID_FIELD_NUMBER: _ClassVar[int]
    block_id: str
    action_id: str
    def __init__(self, block_id: _Optional[str] = ..., action_id: _Optional[str] = ...) -> None: ...

class ApprovalReply(_message.Message):
    __slots__ = ("success",)
    SUCCESS_FIELD_NUMBER: _ClassVar[int]
    success: bool
    def __init__(self, success: bool = ...) -> None: ...

class StoreSecretRequest(_message.Message):
    __slots__ = ("service", "key", "value")
    SERVICE_FIELD_NUMBER: _ClassVar[int]
    KEY_FIELD_NUMBER: _ClassVar[int]
    VALUE_FIELD_NUMBER: _ClassVar[int]
    service: str
    key: str
    value: str
    def __init__(self, service: _Optional[str] = ..., key: _Optional[str] = ..., value: _Optional[str] = ...) -> None: ...

class StoreSecretResponse(_message.Message):
    __slots__ = ("success", "error")
    SUCCESS_FIELD_NUMBER: _ClassVar[int]
    ERROR_FIELD_NUMBER: _ClassVar[int]
    success: bool
    error: str
    def __init__(self, success: bool = ..., error: _Optional[str] = ...) -> None: ...

class HasSecretRequest(_message.Message):
    __slots__ = ("service", "key")
    SERVICE_FIELD_NUMBER: _ClassVar[int]
    KEY_FIELD_NUMBER: _ClassVar[int]
    service: str
    key: str
    def __init__(self, service: _Optional[str] = ..., key: _Optional[str] = ...) -> None: ...

class HasSecretResponse(_message.Message):
    __slots__ = ("exists",)
    EXISTS_FIELD_NUMBER: _ClassVar[int]
    exists: bool
    def __init__(self, exists: bool = ...) -> None: ...
