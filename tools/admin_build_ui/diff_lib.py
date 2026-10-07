"""Computes a highlighted source-code diff between two build snapshots for
the Compare page.

Each build (see build_lib.py's record_build/_snapshot_source) gets a plain
copy of lib/ - the Flutter app source - saved under data/snapshots/<id>/lib.
No git involved: comparing two builds only ever needs "what did the code
look like when each was built", and a plain file copy answers that without
requiring commits at build time or a clean working tree.
"""

import difflib
import html
from pathlib import Path

SNAPSHOTS_DIR = Path(__file__).resolve().parent / "data" / "snapshots"


def snapshot_lib_dir(record_id: str) -> Path:
    return SNAPSHOTS_DIR / record_id / "lib"


def _list_files(root: Path) -> dict:
    """relative posix path -> absolute Path, for every file under root."""
    if not root.exists():
        return {}
    return {p.relative_to(root).as_posix(): p for p in root.rglob("*") if p.is_file()}


def _read_lines(path: Path) -> list:
    try:
        return path.read_text(encoding="utf-8", errors="replace").splitlines(keepends=True)
    except OSError:
        return []


def _highlight_diff(lines_a: list, lines_b: list) -> str:
    """Unified diff (Python's own difflib, no extra dependency), each line
    wrapped in a span colored by its +/-/@@ prefix for the template to
    render as-is (marked |safe)."""
    diff = difflib.unified_diff(lines_a, lines_b, fromfile="A", tofile="B", lineterm="")
    out = []
    for line in diff:
        css = "ctx"
        if line.startswith("+++") or line.startswith("---"):
            css = "file"
        elif line.startswith("@@"):
            css = "hunk"
        elif line.startswith("+"):
            css = "add"
        elif line.startswith("-"):
            css = "del"
        out.append(f'<span class="diff-{css}">{html.escape(line)}</span>')
    return "\n".join(out) if out else "(no textual differences)"


def compare_snapshots(record_id_a: str, record_id_b: str) -> dict:
    """Returns {available, files: [{path, status, diff_html}]} - files that
    are byte-identical between the two builds are left out entirely, so
    only what actually changed is shown. `available` is False when either
    build predates this feature (no snapshot was ever taken for it)."""
    dir_a = snapshot_lib_dir(record_id_a)
    dir_b = snapshot_lib_dir(record_id_b)
    if not dir_a.exists() or not dir_b.exists():
        return {"available": False, "files": []}

    files_a = _list_files(dir_a)
    files_b = _list_files(dir_b)

    files = []
    for rel in sorted(set(files_a) | set(files_b)):
        pa, pb = files_a.get(rel), files_b.get(rel)
        if pa and not pb:
            status = "removed"
        elif pb and not pa:
            status = "added"
        else:
            if pa.read_bytes() == pb.read_bytes():
                continue
            status = "modified"
        files.append({
            "path": rel,
            "status": status,
            "diff_html": _highlight_diff(
                _read_lines(pa) if pa else [],
                _read_lines(pb) if pb else [],
            ),
        })
    return {"available": True, "files": files}
