"""Cross-platform, process-scoped file locking for localized output stores.

The platform lock modules are imported lazily so importing Map Studio on one
platform never requires modules that only exist on another platform.  Both
backends use kernel-managed locks, which are released automatically when a
process exits or crashes.
"""

from __future__ import annotations

import errno
import os
import time
from pathlib import Path
from typing import BinaryIO, TypeAlias


class FileLockError(OSError):
    """The operating-system file lock could not be acquired or released."""


class FileLockTimeout(FileLockError, TimeoutError):
    """The file lock remained owned by another process until the deadline."""


class _PlatformFileLock:
    backend_name = "unknown"

    @staticmethod
    def acquire(handle: BinaryIO) -> None:
        raise NotImplementedError

    @staticmethod
    def release(handle: BinaryIO) -> None:
        raise NotImplementedError


class PosixFileLock(_PlatformFileLock):
    backend_name = "posix-flock"

    @staticmethod
    def acquire(handle: BinaryIO) -> None:
        # fcntl is intentionally unavailable on Windows and must remain lazy.
        import fcntl

        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)

    @staticmethod
    def release(handle: BinaryIO) -> None:
        import fcntl

        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


class WindowsFileLock(_PlatformFileLock):
    backend_name = "windows-msvcrt"

    @staticmethod
    def acquire(handle: BinaryIO) -> None:
        # msvcrt is intentionally unavailable on POSIX and must remain lazy.
        import msvcrt

        handle.seek(0)
        msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)

    @staticmethod
    def release(handle: BinaryIO) -> None:
        import msvcrt

        handle.seek(0)
        msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)


FileLockBackend: TypeAlias = type[_PlatformFileLock]


def select_file_lock_backend(platform_name: str | None = None) -> FileLockBackend:
    """Return the native backend without importing its platform-only module."""

    selected = os.name if platform_name is None else platform_name
    if selected == "posix":
        return PosixFileLock
    if selected == "nt":
        return WindowsFileLock
    raise FileLockError(f"Unsupported file-lock platform: {selected!r}")


def _is_contention_error(exc: OSError) -> bool:
    # Windows reports ERROR_LOCK_VIOLATION through winerror 33 or 36 depending
    # on the runtime. POSIX normally reports EACCES/EAGAIN for nonblocking flock.
    return (
        exc.errno in {errno.EACCES, errno.EAGAIN, errno.EDEADLK}
        or getattr(exc, "winerror", None) in {33, 36}
    )


class FileLock:
    """Exclusive OS-level lock on one byte of a stable lock file."""

    def __init__(
        self,
        path: Path,
        *,
        timeout_seconds: float | None = 30.0,
        poll_interval_seconds: float = 0.05,
        platform_name: str | None = None,
    ):
        if timeout_seconds is not None and (
            isinstance(timeout_seconds, bool) or timeout_seconds < 0
        ):
            raise ValueError("File-lock timeout must be non-negative or None.")
        if (
            isinstance(poll_interval_seconds, bool)
            or poll_interval_seconds <= 0
        ):
            raise ValueError("File-lock poll interval must be positive.")
        self.path = Path(path)
        self.timeout_seconds = timeout_seconds
        self.poll_interval_seconds = poll_interval_seconds
        self.backend = select_file_lock_backend(platform_name)
        self._handle: BinaryIO | None = None

    @property
    def is_locked(self) -> bool:
        return self._handle is not None

    def acquire(self) -> None:
        if self._handle is not None:
            raise FileLockError(f"File lock is already held: {self.path}")
        self.path.parent.mkdir(parents=True, exist_ok=True)
        handle = self.path.open("a+b")
        try:
            # Windows byte-range locking requires the byte to exist. Keeping the
            # same byte on POSIX makes the lock file representation identical.
            handle.seek(0, os.SEEK_END)
            if handle.tell() == 0:
                handle.write(b"\0")
                handle.flush()
            deadline = (
                None
                if self.timeout_seconds is None
                else time.monotonic() + self.timeout_seconds
            )
            started = time.monotonic()
            while True:
                try:
                    self.backend.acquire(handle)
                    self._handle = handle
                    return
                except OSError as exc:
                    if not _is_contention_error(exc):
                        raise FileLockError(
                            f"Failed to acquire {self.backend.backend_name} lock "
                            f"{self.path}: {exc}"
                        ) from exc
                    now = time.monotonic()
                    if deadline is not None and now >= deadline:
                        elapsed = now - started
                        raise FileLockTimeout(
                            f"Timed out after {elapsed:.3f}s waiting for exclusive "
                            f"{self.backend.backend_name} lock {self.path} "
                            f"(requesting_pid={os.getpid()})."
                        ) from exc
                    delay = self.poll_interval_seconds
                    if deadline is not None:
                        delay = min(delay, max(0.0, deadline - now))
                    time.sleep(delay)
        except Exception:
            handle.close()
            raise

    def release(self) -> None:
        handle = self._handle
        if handle is None:
            return
        self._handle = None
        try:
            self.backend.release(handle)
        except OSError as exc:
            raise FileLockError(
                f"Failed to release {self.backend.backend_name} lock "
                f"{self.path}: {exc}"
            ) from exc
        finally:
            handle.close()

    def __enter__(self) -> FileLock:
        self.acquire()
        return self

    def __exit__(self, exc_type: object, exc: object, traceback: object) -> None:
        self.release()
