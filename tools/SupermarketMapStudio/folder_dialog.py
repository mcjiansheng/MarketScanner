#!/usr/bin/env python3
"""Open a native file or directory chooser for the local Map Studio server."""

from __future__ import annotations

import platform
import subprocess
import sys
from typing import Callable


MACOS_DIALOG_SCRIPT = r'''
on run argv
    set dialogMode to item 1 of argv
    set dialogTitle to item 2 of argv
    try
        if dialogMode is "file" then
            set selectedItem to choose file with prompt dialogTitle
        else
            set selectedItem to choose folder with prompt dialogTitle
        end if
        return POSIX path of selectedItem
    on error number -128
        return ""
    end try
end run
'''


def macos_dialog(mode: str, title: str) -> str:
    """Use the system Finder chooser without depending on Python/Tk."""
    completed = subprocess.run(
        ["/usr/bin/osascript", "-e", MACOS_DIALOG_SCRIPT, mode, title],
        capture_output=True,
        text=True,
        timeout=180,
        check=False,
    )
    if completed.returncode != 0:
        message = completed.stderr.strip() or "macOS file chooser failed."
        raise RuntimeError(message)
    return completed.stdout.strip()


def tkinter_dialog(mode: str, title: str) -> str:
    """Portable fallback used when a native platform chooser is unavailable."""
    try:
        import tkinter as tk
        from tkinter import filedialog
    except (ImportError, ModuleNotFoundError) as exc:
        raise RuntimeError(f"Tk folder dialog is unavailable: {exc}") from exc

    try:
        root = tk.Tk()
    except tk.TclError as exc:
        raise RuntimeError(f"Tk folder dialog is unavailable: {exc}") from exc
    root.withdraw()
    try:
        root.attributes("-topmost", True)
    except tk.TclError:
        pass
    try:
        if mode == "file":
            return str(filedialog.askopenfilename(title=title))
        return str(filedialog.askdirectory(title=title, mustexist=True))
    finally:
        root.destroy()


def select_path(mode: str, title: str) -> str:
    if mode not in {"directory", "file"}:
        raise ValueError("Dialog mode must be directory or file.")
    chooser: Callable[[str, str], str]
    chooser = macos_dialog if platform.system() == "Darwin" else tkinter_dialog
    return chooser(mode, title)


def main() -> int:
    mode = sys.argv[1] if len(sys.argv) > 1 else "directory"
    title = sys.argv[2] if len(sys.argv) > 2 else "Select folder"
    try:
        selected = select_path(mode, title)
    except (OSError, RuntimeError, subprocess.SubprocessError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        return 2
    if selected:
        print(selected)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
