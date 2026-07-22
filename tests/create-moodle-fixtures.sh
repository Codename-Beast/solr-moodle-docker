#!/usr/bin/env sh
# Copyright (c) 2026 eLeDia.de / Bernd Schreistetter (bsc)

set -eu

BASE_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

cat > "$BASE_DIR/fixture-notes.txt" <<'EOF'
Moodle Solr Tika integration test notes.
Marker: ELEDIA TIKA TEST MARKER.
This plain text file validates full-text indexing.
EOF

cat > "$BASE_DIR/fixture-course-overview.html" <<'EOF'
<!doctype html>
<html><head><meta charset="utf-8"><title>Moodle Solr Fixture</title></head>
<body>
<h1>Advanced Moodle Search</h1>
<p>Apache Solr powers fast global search in Moodle Workplace deployments.</p>
<p>Marker: ELEDIA HTML FIXTURE MARKER</p>
</body></html>
EOF

cat > "$BASE_DIR/fixture-gradebook.csv" <<'EOF'
userid,course,topic,score
101,CS501,solr search optimization,95
102,CS501,moodle workplace indexing,91
EOF

cat > "$BASE_DIR/fixture-announcement.rtf" <<'EOF'
{\rtf1\ansi\deff0 {\fonttbl {\f0 Arial;}}\f0\fs24 Moodle Workplace maintenance window with Solr reindex. Marker: ELEDIA RTF FIXTURE MARKER}
EOF

# Create a minimal DOCX fixture with only standard library tooling.
# Tika must extract this marker during Moodle/Solr file indexing.
if command -v python3 >/dev/null 2>&1; then
  python3 - "$BASE_DIR/fixture-word-document.docx" <<'PY'
import html
import sys
import zipfile

out = sys.argv[1]
marker = "ELEDIA DOCX FIXTURE MARKER"
text = (
    "Moodle Solr Word document fixture. "
    f"Marker: {marker}. "
    "This validates DOCX full-text extraction through Apache Tika."
)
content_types = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>'''
rels = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>'''
doc = f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>eLeDia Moodle Solr DOCX Fixture</w:t></w:r></w:p><w:p><w:r><w:t>{html.escape(text)}</w:t></w:r></w:p><w:sectPr/></w:body></w:document>'''
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
    zf.writestr("[Content_Types].xml", content_types)
    zf.writestr("_rels/.rels", rels)
    zf.writestr("word/document.xml", doc)
PY
else
  echo "INFO: no python3 found; DOCX fixture will be skipped by tests" >&2
fi

# Create a PPTX fixture when python-pptx is available.
# The fallback intentionally skips instead of writing a hand-rolled OOXML file:
# Apache Tika is stricter than zip/XML smoke checks for PowerPoint packages.
if command -v python3 >/dev/null 2>&1 && python3 - <<'PY' >/dev/null 2>&1
import pptx
PY
then
  python3 - "$BASE_DIR/fixture-presentation.pptx" <<'PY'
import sys
from pptx import Presentation

out = sys.argv[1]
marker = "ELEDIA PPTX FIXTURE MARKER"
prs = Presentation()
slide = prs.slides.add_slide(prs.slide_layouts[5])
slide.shapes.title.text = "eLeDia Moodle Solr PPTX Fixture"
box = slide.shapes.add_textbox(914400, 1828800, 7772400, 1828800)
box.text_frame.text = (
    "Moodle Solr PowerPoint fixture. "
    f"Marker: {marker}. "
    "This validates PPTX full-text extraction through Apache Tika."
)
prs.save(out)
PY
else
  echo "INFO: python-pptx not available; PPTX fixture will be skipped by tests" >&2
fi

# Create PNG "photo" fixture (prefer ImageMagick; otherwise keep checked-in PNG)
if command -v convert >/dev/null 2>&1; then
  convert -size 1200x630 xc:'#202024' \
    -fill '#ff8c00' -stroke '#ff8c00' -strokewidth 4 -draw 'rectangle 40,40 1160,590' \
    -fill white -pointsize 42 -annotate +70+120 'Moodle Campus Search Demo' \
    -fill '#ffb440' -pointsize 34 -annotate +70+200 'ELEDIA PHOTO MARKER' \
    -fill '#dddddd' -pointsize 26 -annotate +70+280 'Photo fixture for Solr/Tika metadata indexing' \
    "$BASE_DIR/fixture-campus-photo.png"
elif [ -f "$BASE_DIR/fixture-campus-photo.png" ]; then
  :
else
  echo "INFO: no ImageMagick convert found and no prebuilt PNG present; photo fixture will be skipped by tests" >&2
fi

echo "Fixtures generated in $BASE_DIR"
