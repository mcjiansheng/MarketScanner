#!/usr/bin/env python3
"""Open a native file or directory chooser for the local Map Studio server."""

from __future__ import annotations

import sys


def main() -> int:
    mode = sys.argv[1] if len(sys.argv) > 1 else "directory"
    title = sys.argv[2] if len(sys.argv) > 2 else "Select folder"
    try:
        import tkinter as tk
        from tkinter import filedialog
    except ImportError as exc:
        print(f"Tk folder dialog is unavailable: {exc}", file=sys.stderr)
        return 2

    try:
        root = tk.Tk()
    except tk.TclError as exc:
        print(f"Tk folder dialog is unavailable: {exc}", file=sys.stderr)
        return 2
    root.withdraw()
    try:
        root.attributes("-topmost", True)
    except tk.TclError:
        pass
    try:
        if mode == "file":
            selected = filedialog.askopenfilename(title=title)
        else:
            selected = filedialog.askdirectory(title=title, mustexist=True)
    finally:
        root.destroy()
    if selected:
        print(selected)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
