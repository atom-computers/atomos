import os
from abc import ABC, abstractmethod
from typing import List

class FilesystemBackend(ABC):
    """Abstract base class for filesystem operations."""
    
    @abstractmethod
    def read_file(self, path: str) -> str:
        pass
        
    @abstractmethod
    def write_file(self, path: str, content: str) -> None:
        pass
        
    @abstractmethod
    def list_directory(self, path: str) -> List[str]:
        pass

class LocalFilesystemBackend(FilesystemBackend):
    """Local filesystem backend with directory traversal protection."""
    
    def __init__(self, base_dir: str):
        self.base_dir = os.path.abspath(base_dir)
        if not os.path.exists(self.base_dir):
            os.makedirs(self.base_dir)
            
    def _resolve_and_check_path(self, path: str) -> str:
        # Resolve the absolute path
        target_path = os.path.abspath(os.path.join(self.base_dir, path.lstrip('/')))
        # Check if the target path is still within the base directory
        if not target_path.startswith(self.base_dir):
            raise PermissionError(f"Access denied: path {path} is outside the allowed base directory.")
        return target_path

    def read_file(self, path: str) -> str:
        target_path = self._resolve_and_check_path(path)
        with open(target_path, 'r', encoding='utf-8') as f:
            return f.read()

    def write_file(self, path: str, content: str) -> None:
        target_path = self._resolve_and_check_path(path)
        os.makedirs(os.path.dirname(target_path), exist_ok=True)
        with open(target_path, 'w', encoding='utf-8') as f:
            f.write(content)

    def list_directory(self, path: str) -> List[str]:
        target_path = self._resolve_and_check_path(path)
        if not os.path.isdir(target_path):
            raise NotADirectoryError(f"Path {path} is not a directory.")
        return os.listdir(target_path)


class SandboxFilesystemBackend(FilesystemBackend):
    """Stub for Kata container sandbox filesystem backend."""
    
    def read_file(self, path: str) -> str:
        raise NotImplementedError("Sandbox filesystem not yet implemented.")
        
    def write_file(self, path: str, content: str) -> None:
        raise NotImplementedError("Sandbox filesystem not yet implemented.")
        
    def list_directory(self, path: str) -> List[str]:
        raise NotImplementedError("Sandbox filesystem not yet implemented.")
