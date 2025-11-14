from pathlib import Path
from typing import List
import os
import re

from app.core.config import settings


class InvalidWorkspacePath(ValueError):
    """Raised when a requested path is unsafe or escapes the workspace sandbox."""
    pass


def ensure_workspace_root() -> Path:
    root = Path(settings.WORKSPACE_ROOT)
    root.mkdir(parents=True, exist_ok=True)
    return root


def create_workspace(project_id: str) -> Path:
    root = ensure_workspace_root()
    ws = root / project_id
    ws.mkdir(parents=True, exist_ok=True)

    codex_dir = ws / ".codex"
    codex_dir.mkdir(exist_ok=True)

    return ws


def _is_windows_drive_path(p: str) -> bool:
    # Detect "C:\..." or "C:/..." and UNC paths "\\server\share"
    return bool(re.match(r"^[a-zA-Z]:[/\\]", p)) or p.startswith("\\\\")


def safe_resolve_path(workspace_path: str, rel_path: str) -> Path:
    """
    Resolve a user-supplied relative path safely within the workspace sandbox.

    Rules:
    - Reject absolute paths and Windows drive/UNC paths.
    - Resolve symlinks and ".." segments.
    - Reject if the final resolved path is outside the workspace root.
    - For non-existent targets, resolution happens with strict=False, but the
      computed path must still remain under the workspace root.
    """
    root = Path(workspace_path).resolve()
    if _is_windows_drive_path(rel_path):
        raise InvalidWorkspacePath("Absolute or drive path not allowed")

    user_path = Path(rel_path)

    if user_path.is_absolute():
        raise InvalidWorkspacePath("Absolute path not allowed")

    # Join and resolve with strict=False so that non-existent paths can still be checked
    candidate = (root / user_path).resolve(strict=False)

    # Ensure candidate remains within root
    try:
        candidate.relative_to(root)
    except ValueError:
        raise InvalidWorkspacePath("Path escapes workspace")

    return candidate


def list_files(workspace_path: str) -> List[dict]:
    """
    List files under the workspace, without following symlinked directories that
    escape the workspace. Files whose real path escapes are skipped.
    """
    files: List[dict] = []
    root = Path(workspace_path)
    root_real = root.resolve()

    # Walk without following directory symlinks
    for dirpath, dirnames, filenames in os.walk(root_real, followlinks=False):
        # Prune any directory entries that would resolve outside the workspace
        kept_dirs = []
        for d in dirnames:
            full = Path(dirpath) / d
            try:
                real = full.resolve(strict=False)
                # If it's a symlink or resolves outside, skip
                try:
                    real.relative_to(root_real)
                except ValueError:
                    continue
            except Exception:
                # If we cannot resolve for any reason, skip descending
                continue
            kept_dirs.append(d)
        dirnames[:] = kept_dirs

        # Collect files that remain inside after resolution
        for fname in filenames:
            fpath = Path(dirpath) / fname
            try:
                real = fpath.resolve(strict=False)
                real.relative_to(root_real)
            except Exception:
                # Skip files whose resolution escapes or can't be resolved safely
                continue

            try:
                rel = fpath.relative_to(root_real)
            except ValueError:
                # Shouldn't happen if above check passed, but guard anyway
                continue

            try:
                size = fpath.stat().st_size
            except FileNotFoundError:
                # Handle race conditions
                continue

            files.append({"path": str(rel), "size": size})

    return files


def read_file(workspace_path: str, rel_path: str) -> str:
    """
    Safely read a file within the workspace.
    - Raises InvalidWorkspacePath for unsafe paths or symlink escapes.
    - Raises FileNotFoundError for safe-but-missing paths.
    """
    target = safe_resolve_path(workspace_path, rel_path)

    # Must exist and be a regular file
    if not target.exists() or not target.is_file():
        raise FileNotFoundError(rel_path)

    # Double-check final real path is still within workspace to guard symlink races
    root_real = Path(workspace_path).resolve()
    real = target.resolve(strict=True)
    try:
        real.relative_to(root_real)
    except ValueError:
        # Symlink points outside
        raise InvalidWorkspacePath("Symlink escapes workspace")

    return target.read_text(encoding="utf-8")
