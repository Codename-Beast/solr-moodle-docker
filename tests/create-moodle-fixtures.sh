#!/usr/bin/env sh
# Copyright (c) 2026 Eledia GmbH / Bernd Schreistetter
# SPDX-License-Identifier: MIT

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
