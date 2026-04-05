"""Parse PDF files into structured or text dicts.

Two-pass strategy:
  1. Try table extraction. If tables with >3 cols and >5 rows -> structured output.
  2. If no clean tables -> extract text -> text output.
  3. If no extractable text -> error (scanned PDF).

Returns:
    {"type": "structured", "sheets": [{"name": str, "columns": [str], "rows": [dict], "row_count": int}]}
    {"type": "text", "content": str, "char_count": int, "page_count": int}
    {"type": "error", "message": str}
"""

import sys


def parse(file_path):
    """Parse a PDF file.

    Args:
        file_path: Path to the PDF file.

    Returns:
        A dict with type "structured", "text", or "error".
    """
    try:
        import pdfplumber
    except ImportError:
        return {"type": "error", "message": "pdfplumber is not installed. Run: pip install pdfplumber"}

    try:
        pdf = pdfplumber.open(file_path)

        # Capture page_count BEFORE any chance of closing
        page_count = len(pdf.pages)

        # Pass 1: Try table extraction
        all_tables = []
        for page in pdf.pages:
            tables = page.extract_tables()
            if tables:
                all_tables.extend(tables)

        # Check if we have "clean" tables (>3 columns, >5 rows)
        clean_tables = [t for t in all_tables if len(t) > 5 and len(t[0]) > 3]

        if clean_tables:
            sheets = []
            for idx, table in enumerate(clean_tables):
                headers = [str(h) if h is not None else f"Column_{i}" for i, h in enumerate(table[0])]
                rows = []
                for raw_row in table[1:]:
                    # Skip empty rows
                    if not any(cell is not None and str(cell).strip() for cell in raw_row):
                        continue
                    row_dict = {}
                    for i, header in enumerate(headers):
                        val = raw_row[i] if i < len(raw_row) else None
                        row_dict[header] = val
                    rows.append(row_dict)

                sheets.append({
                    "name": f"Table_{idx + 1}",
                    "columns": headers,
                    "rows": rows,
                    "row_count": len(rows),
                })

            pdf.close()
            return {"type": "structured", "sheets": sheets}

        # Pass 2: Extract text
        text_parts = []
        for page in pdf.pages:
            text = page.extract_text()
            if text:
                text_parts.append(text)

        pdf.close()

        full_text = "\n\n".join(text_parts).strip()

        if not full_text:
            return {
                "type": "error",
                "message": "Scanned PDF detected. No extractable text found. OCR is required to process this file.",
            }

        return {
            "type": "text",
            "content": full_text,
            "char_count": len(full_text),
            "page_count": page_count,
        }

    except Exception as e:
        return {"type": "error", "message": str(e)}


if __name__ == "__main__":
    import json

    if len(sys.argv) < 2:
        print("Usage: python parse_pdf.py <file_path>")
        sys.exit(1)

    path = sys.argv[1]
    result = parse(path)
    print(json.dumps(result, indent=2, default=str))
