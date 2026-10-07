#!/usr/bin/env python3
"""One-off converter: docs/*.md -> a matching .docx, for handing a spec to
someone who wants a Word file, not a markdown file. Not part of the runtime
app or the Admin Build UI - a standalone script, run manually.

Handles the specific markdown subset actually used in docs/*.md: headings
(#/##/###), bold (**x**), inline code (`x`), bullet lists (- x), numbered
lists (1. x), pipe tables, fenced code blocks (```), and a --- horizontal
rule. Not a general markdown parser - it only needs to cover what these
two documents actually contain.
"""
import re
import sys
from pathlib import Path

from docx import Document
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.shared import Pt, RGBColor, Inches
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.oxml.ns import qn
from docx.oxml import OxmlElement

INLINE_CODE_COLOR = RGBColor(0xC7, 0x25, 0x4E)
HEADING_COLOR = RGBColor(0x1A, 0x1A, 0x1A)


def _style_code_run(run):
    run.font.name = "Consolas"
    run.font.size = Pt(9.5)
    run.font.color.rgb = INLINE_CODE_COLOR


_CODE_RE = re.compile(r"`.+?`")


def _add_plain_or_code(paragraph, text, bold=False):
    """Adds text that may contain `code` spans but no bold markers -
    every run gets `bold` (so this also serves the inside of a **bold**
    span that itself contains one or more `code` sub-spans)."""
    pos = 0
    for m in _CODE_RE.finditer(text):
        if m.start() > pos:
            run = paragraph.add_run(text[pos:m.start()])
            run.bold = bold
        run = paragraph.add_run(m.group(0)[1:-1])
        run.bold = bold
        _style_code_run(run)
        pos = m.end()
    if pos < len(text):
        run = paragraph.add_run(text[pos:])
        run.bold = bold


def add_inline_runs(paragraph, text):
    """Splits text on **bold** and `code` spans - either may contain the
    other nested inside it (e.g. **... `x` ...** or plain `... **x** ...`
    doesn't occur in these docs, but bold-wrapping-code and code-inside-
    bold both do) - and adds each as its own formatted run."""
    pattern = re.compile(r"(\*\*.+?\*\*|`.+?`)")
    pos = 0
    for m in pattern.finditer(text):
        if m.start() > pos:
            _add_plain_or_code(paragraph, text[pos:m.start()])
        token = m.group(0)
        if token.startswith("**"):
            _add_plain_or_code(paragraph, token[2:-2], bold=True)
        else:
            run = paragraph.add_run(token[1:-1])
            _style_code_run(run)
        pos = m.end()
    if pos < len(text):
        _add_plain_or_code(paragraph, text[pos:])


def set_cell_shading(cell, color_hex):
    tc_pr = cell._tc.get_or_add_tcPr()
    shd = OxmlElement("w:shd")
    shd.set(qn("w:val"), "clear")
    shd.set(qn("w:color"), "auto")
    shd.set(qn("w:fill"), color_hex)
    tc_pr.append(shd)


def convert(md_path: Path, docx_path: Path, title: str) -> None:
    lines = md_path.read_text(encoding="utf-8").splitlines()
    doc = Document()

    # Base styling - a plain, readable document, not trying to reproduce
    # any particular corporate template.
    normal = doc.styles["Normal"]
    normal.font.name = "Calibri"
    normal.font.size = Pt(10.5)

    for level in range(1, 5):
        style = doc.styles[f"Heading {level}"]
        style.font.color.rgb = HEADING_COLOR
        style.font.name = "Calibri"

    i = 0
    n = len(lines)
    first_heading_done = False
    in_code_block = False
    code_block_lines: list[str] = []

    while i < n:
        line = lines[i]
        stripped = line.strip()

        # Fenced code block
        if stripped.startswith("```"):
            if not in_code_block:
                in_code_block = True
                code_block_lines = []
            else:
                in_code_block = False
                p = doc.add_paragraph()
                p.paragraph_format.space_before = Pt(2)
                p.paragraph_format.space_after = Pt(8)
                run = p.add_run("\n".join(code_block_lines))
                run.font.name = "Consolas"
                run.font.size = Pt(9)
                # Light grey shading behind the whole block via a 1-cell table
                # is overkill here - a monospace run reads fine for these
                # short folder-tree/command blocks.
            i += 1
            continue
        if in_code_block:
            code_block_lines.append(line)
            i += 1
            continue

        # Horizontal rule
        if stripped == "---":
            p = doc.add_paragraph()
            p.paragraph_format.space_before = Pt(4)
            p.paragraph_format.space_after = Pt(4)
            pPr = p._p.get_or_add_pPr()
            pBdr = OxmlElement("w:pBdr")
            bottom = OxmlElement("w:bottom")
            bottom.set(qn("w:val"), "single")
            bottom.set(qn("w:sz"), "6")
            bottom.set(qn("w:space"), "1")
            bottom.set(qn("w:color"), "999999")
            pBdr.append(bottom)
            pPr.append(pBdr)
            i += 1
            continue

        # Blank line
        if not stripped:
            i += 1
            continue

        # Headings
        m = re.match(r"^(#{1,4})\s+(.*)$", line)
        if m:
            level = len(m.group(1))
            text = m.group(2).strip()
            style = "Title" if (not first_heading_done and level == 1) else f"Heading {level}"
            if style == "Title":
                first_heading_done = True
            p = doc.add_paragraph(style=style)
            add_inline_runs(p, text)
            i += 1
            continue

        # Table (a block of consecutive "|...|" lines, second line a separator)
        if stripped.startswith("|") and i + 1 < n and re.match(
                r"^\|?[\s:|-]+\|?$", lines[i + 1].strip()):
            table_lines = [stripped]
            j = i + 2
            while j < n and lines[j].strip().startswith("|"):
                table_lines.append(lines[j].strip())
                j += 1
            header = [c.strip() for c in table_lines[0].strip("|").split("|")]
            rows = [
                [c.strip() for c in row.strip("|").split("|")]
                for row in table_lines[1:]
            ]
            table = doc.add_table(rows=1, cols=len(header))
            table.style = "Table Grid"
            table.alignment = WD_TABLE_ALIGNMENT.LEFT
            for ci, htext in enumerate(header):
                cell = table.rows[0].cells[ci]
                cell.paragraphs[0].clear()
                add_inline_runs(cell.paragraphs[0], htext)
                for run in cell.paragraphs[0].runs:
                    run.bold = True
                set_cell_shading(cell, "E8E8E8")
            for row in rows:
                cells = table.add_row().cells
                for ci in range(len(header)):
                    text = row[ci] if ci < len(row) else ""
                    cells[ci].paragraphs[0].clear()
                    add_inline_runs(cells[ci].paragraphs[0], text)
            doc.add_paragraph().paragraph_format.space_after = Pt(4)
            i = j
            continue

        # Numbered list
        m = re.match(r"^(\d+)\.\s+(.*)$", stripped)
        if m:
            p = doc.add_paragraph(style="List Number")
            add_inline_runs(p, m.group(2))
            i += 1
            continue

        # Bullet list (single level - these docs don't nest bullets)
        m = re.match(r"^[-*]\s+(.*)$", stripped)
        if m:
            p = doc.add_paragraph(style="List Bullet")
            add_inline_runs(p, m.group(1))
            i += 1
            continue

        # Plain paragraph
        p = doc.add_paragraph()
        add_inline_runs(p, stripped)
        i += 1

    doc.core_properties.title = title
    doc.save(docx_path)
    print(f"Wrote {docx_path}")


if __name__ == "__main__":
    root = Path(__file__).resolve().parent.parent
    docs = root / "docs"
    out_dir = docs
    convert(
        docs / "Functional_Specification.md",
        out_dir / "Functional_Specification.docx",
        "Functional Specification - WMSNow Redwood Mobile",
    )
    convert(
        docs / "Technical_Specification.md",
        out_dir / "Technical_Specification.docx",
        "Technical Specification - WMSNow Redwood Mobile",
    )
