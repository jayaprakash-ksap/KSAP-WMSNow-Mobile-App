"""Lists and serves captured photos/signatures (see UploadService /
captured_files_receiver.py's original protocol, now also handled by
app.py's /upload route) for the Admin Build UI's /images browsing page.

Reuses the SAME <project_root>/captured_images/ folder
tools/captured_files_receiver.py has always written to - no data
migration, both can write here interchangeably.

Filenames carry no customer/instance/username info (unlike session logs,
which have that in their own first line) - just a type prefix and a
timestamp:
    SplitIBLPN_<lpn>_<epoch_ms>.jpg
    POD_<order>_<epoch_ms>.png
So browsing/filtering here is by type and date only, not by customer.

Because of that, app.py's company-scoped accounts (2026-09-25) can't be
shown a filtered Images page safely - there's nothing here to filter ON -
so the whole /images* section is unrestricted-accounts-only for now (see
app.py's unrestricted_required). To lift that, UploadService (Flutter,
lib/services/upload_service.dart) and this module's save_upload would both
need to start carrying a customer/company tag (e.g. a new filename
segment or an X-Customer header alongside X-Filename), and list_images/
filter_images here would need to parse and filter on it, the same way
log_lib.py already does for session logs via each file's SESSION line.
"""

import os
import re
from pathlib import Path

IMAGES_DIR = Path(__file__).resolve().parent.parent.parent / "captured_images"

_UNSAFE_CHARS = re.compile(r"[^A-Za-z0-9_.-]")


def safe_filename(raw: str) -> str:
    """Same reasoning as captured_files_receiver.py's own safe_filename -
    never let a header/URL value escape IMAGES_DIR."""
    name = os.path.basename(raw.strip())
    name = _UNSAFE_CHARS.sub("_", name)
    return name or "upload.bin"


def save_upload(filename: str, body: bytes) -> Path:
    IMAGES_DIR.mkdir(parents=True, exist_ok=True)
    dest = IMAGES_DIR / safe_filename(filename)
    # Same collision guard as captured_files_receiver.py - app filenames
    # already carry a millisecond timestamp, so this should be rare.
    counter = 1
    stem, suffix = dest.stem, dest.suffix
    while dest.exists():
        dest = IMAGES_DIR / f"{stem}_{counter}{suffix}"
        counter += 1
    dest.write_bytes(body)
    return dest


def _guess_type(filename: str) -> str:
    if filename.startswith("POD_"):
        return "POD Signature"
    if filename.startswith("SplitIBLPN_"):
        return "Split IBLPN Photo"
    return "Other"


def list_images() -> list:
    """Newest first. Each entry: filename, type, timestamp (ISO, from the
    file's own mtime - these files carry no internal timestamp to parse),
    date (YYYY-MM-DD, for the date filter), size_bytes."""
    if not IMAGES_DIR.exists():
        return []
    entries = []
    for path in IMAGES_DIR.iterdir():
        if not path.is_file():
            continue
        stat = path.stat()
        from datetime import datetime
        mtime = datetime.fromtimestamp(stat.st_mtime)
        entries.append({
            "filename": path.name,
            "type": _guess_type(path.name),
            "timestamp": mtime.isoformat(timespec="seconds"),
            "date": mtime.strftime("%Y-%m-%d"),
            "size_bytes": stat.st_size,
        })
    entries.sort(key=lambda e: e["timestamp"], reverse=True)
    return entries


def filter_images(image_type: str = "", date: str = "") -> list:
    images = list_images()
    if image_type:
        images = [i for i in images if i["type"] == image_type]
    if date:
        images = [i for i in images if i["date"] == date]
    return images
