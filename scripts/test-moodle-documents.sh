#!/bin/bash
# Copyright (c) 2026 eLeDia.de / Bernd Schreistetter (bsc)
# Version: v3.4.9

# =========================================
# Moodle Document Testing for Solr
# =========================================
#
# Purpose:
#   - Test Solr with realistic Moodle documents
#   - Verify indexing, querying, filtering, highlighting
#   - Configurable cleanup for WebUI inspection
#
# Usage:
#   ./scripts/test-moodle-documents.sh                    # Run all tests, cleanup after
#   ./scripts/test-moodle-documents.sh --keep-documents   # Keep docs for WebUI inspection
#   ./scripts/test-moodle-documents.sh --wait-time 60     # Wait 60s before cleanup
#   ./scripts/test-moodle-documents.sh --no-cleanup       # Never cleanup (alias for --keep-documents)
#

set -o pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Configuration
KEEP_DOCUMENTS=false
WAIT_TIME=0
SOLR_HOST="127.0.0.1"

# Load runtime config from .env before deriving defaults
if [ -f ".env" ]; then
    source .env
fi
SOLR_PORT="${SOLR_PORT:-8983}"
SOLR_CORE="${SOLR_CORE_NAME:-eLeDia_core}"

# Counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
DOCS_INDEXED=0

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --keep-documents|--no-cleanup)
      KEEP_DOCUMENTS=true
      shift
      ;;
    --wait-time)
      WAIT_TIME="$2"
      shift 2
      ;;
    --help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --keep-documents     Keep test documents after completion (for WebUI inspection)"
      echo "  --no-cleanup         Alias for --keep-documents"
      echo "  --wait-time SECONDS  Wait N seconds before cleanup (default: 0)"
      echo "  --help               Show this help message"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
done

# Load credentials from .env
if [ -f ".env" ]; then
  source .env
else
  echo -e "${RED}ERROR: .env not found. Run setup first: ./setup.sh${NC}"
  exit 1
fi

# Helper functions
print_header() {
  echo -e "\n${BOLD}${BLUE}=======================================${NC}"
  echo -e "${BOLD}${BLUE}$1${NC}"
  echo -e "${BOLD}${BLUE}=======================================${NC}\n"
}

print_test() {
  echo -e "${BLUE}[TEST]${NC} $1"
  ((TESTS_RUN++))
}

print_pass() {
  echo -e "${GREEN}[PASS]${NC} $1"
  ((TESTS_PASSED++))
}

print_fail() {
  echo -e "${RED}[FAIL]${NC} $1"
  ((TESTS_FAILED++))
}

print_info() {
  echo -e "${YELLOW}[INFO]${NC} $1"
}

print_skip() {
  echo -e "${YELLOW}[SKIP]${NC} $1"
}

# Solr API helper
solr_post() {
  local endpoint="$1"
  local data="$2"
  curl -s -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" \
    -H "Content-Type: application/json" \
    -X POST \
    "http://${SOLR_HOST}:${SOLR_PORT}/solr/${SOLR_CORE}/${endpoint}" \
    -d "$data"
}

# Add document wrapper for Solr format
solr_add_doc() {
  local doc="$1"
  echo "[${doc}]"
}

solr_get() {
  local endpoint="$1"
  curl -s -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" \
    "http://${SOLR_HOST}:${SOLR_PORT}/solr/${SOLR_CORE}/${endpoint}"
}

assert_min_hits() {
  local test_name="$1"
  local endpoint="$2"
  local min_hits="$3"

  print_test "$test_name"
  local result num_found
  result=$(solr_get "$endpoint")
  num_found=$(echo "$result" | jq -r '.response.numFound' 2>/dev/null || echo "0")

  if [ "$num_found" -ge "$min_hits" ]; then
    print_pass "Found $num_found documents (expected >= $min_hits)"
  else
    print_fail "Found $num_found documents (expected >= $min_hits)"
  fi
}

# =========================================
# MOODLE TEST DOCUMENTS (Realistic Data)
# =========================================

# Document 1: Forum Post - Discussion about Solr
FORUM_POST_1='{
  "id": "solr_mod_forum-posts_45_1001_0",
  "title": "How to configure Apache Solr for Moodle",
  "content": "I have been working on integrating Apache Solr with our Moodle installation. The performance improvements are significant! Here are my findings: 1) Solr provides much faster search results than the basic search. 2) File content indexing works great with PDF and DOCX files. 3) The highlighting feature helps users find relevant content quickly.",
  "description1": "Discussion about Solr integration benefits",
  "description2": "Technical details and performance metrics",
  "type": 1,
  "contextid": 12345,
  "areaid": "mod_forum-posts",
  "courseid": 5,
  "groupid": 0,
  "userid": 123,
  "owneruserid": 123,
  "itemid": 1001,
  "modified": "2024-01-15T10:30:00Z"
}'

# Document 2: Course Information
COURSE_1='{
  "id": "solr_core_course_6_0",
  "title": "Advanced Moodle Administration",
  "content": "This comprehensive course covers advanced topics in Moodle administration including performance optimization, security hardening, backup strategies, and integration with external systems like Apache Solr for enhanced search capabilities. Students will learn how to configure and maintain production Moodle environments.",
  "description1": "CS501 - Advanced administration and optimization",
  "description2": "Prerequisites: Basic Moodle administration experience",
  "type": 1,
  "contextid": 13,
  "areaid": "core_course",
  "courseid": 6,
  "groupid": 0,
  "userid": 0,
  "owneruserid": -1,
  "itemid": 6,
  "modified": "2024-01-10T08:00:00Z"
}'

# Document 3: Wiki Page - Collaborative Documentation
WIKI_PAGE_1='{
  "id": "solr_mod_wiki-pages_78_2001_0",
  "title": "Solr Configuration Best Practices",
  "content": "This wiki page documents best practices for Apache Solr configuration. Key recommendations: Set maxBooleanClauses to 2048 or higher for large Moodle installations. Use ManagedIndexSchemaFactory for automatic schema updates. Configure adequate heap size (SOLR_HEAP) based on document count. Enable file indexing for PDF, DOCX, and PPTX files. Implement proper authentication with BasicAuth or Kerberos.",
  "description1": "Community-maintained Solr configuration guide",
  "description2": "Last updated: January 2024",
  "type": 1,
  "contextid": 12350,
  "areaid": "mod_wiki-pages",
  "courseid": 5,
  "groupid": 0,
  "userid": 156,
  "owneruserid": 156,
  "itemid": 2001,
  "modified": "2024-01-20T14:45:00Z"
}'

# Document 4: Glossary Entry - Technical Term
GLOSSARY_ENTRY_1='{
  "id": "solr_mod_glossary-entries_89_3001_0",
  "title": "Apache Lucene",
  "content": "Apache Lucene is a high-performance, full-featured text search engine library written in Java. It is the foundation for Apache Solr, providing the core indexing and search functionality. Lucene uses inverted indexes for fast full-text search and supports advanced features like fuzzy matching, phrase queries, and relevance scoring.",
  "description1": "Definition of Apache Lucene search library",
  "description2": "Related terms: Solr, indexing, full-text search, inverted index",
  "type": 1,
  "contextid": 12360,
  "areaid": "mod_glossary-entries",
  "courseid": 7,
  "groupid": 0,
  "userid": 98,
  "owneruserid": 98,
  "itemid": 3001,
  "modified": "2024-01-12T11:20:00Z"
}'

# Document 5: Book Chapter - Learning Material
BOOK_CHAPTER_1='{
  "id": "solr_mod_book-chapters_120_4001_0",
  "title": "Chapter 3: Introduction to Search Engines",
  "content": "Search engines are essential components of modern information systems. They enable users to quickly find relevant content in large document collections. A typical search engine consists of three main components: 1) Crawler/Indexer - collects and processes documents, 2) Index - stores structured data for fast retrieval, 3) Query Processor - interprets user queries and returns relevant results. Apache Solr implements all these components and provides additional features like faceting, highlighting, and spell checking.",
  "description1": "Introduction to search engine architecture and components",
  "description2": "Learning objectives: Understand indexing, querying, and ranking",
  "type": 1,
  "contextid": 12370,
  "areaid": "mod_book-chapters",
  "courseid": 8,
  "groupid": 0,
  "userid": 45,
  "owneruserid": -1,
  "itemid": 4001,
  "modified": "2024-01-08T09:15:00Z"
}'

# Document 6: Forum Post - Question about Performance
FORUM_POST_2='{
  "id": "solr_mod_forum-posts_45_1002_0",
  "title": "Slow search performance with large index",
  "content": "We are experiencing slow search response times after indexing over 100,000 documents. Each query takes 3-5 seconds which is too slow for our users. Has anyone optimized Solr for better performance? I have already increased SOLR_HEAP to 8GB but it did not help much. Any suggestions would be appreciated!",
  "description1": "Performance issue with large document collection",
  "description2": "Looking for optimization tips and configuration advice",
  "type": 1,
  "contextid": 12345,
  "areaid": "mod_forum-posts",
  "courseid": 5,
  "groupid": 0,
  "userid": 178,
  "owneruserid": 178,
  "itemid": 1002,
  "modified": "2024-01-22T16:20:00Z"
}'

# Document 7: Assignment Description
ASSIGNMENT_1='{
  "id": "solr_mod_assign-activity_95_5001_0",
  "title": "Project: Implement Global Search",
  "content": "In this assignment, you will implement and configure Apache Solr for a Moodle installation. Tasks include: 1) Install and configure Solr 9.x with proper security settings, 2) Set up the Moodle Solr search plugin, 3) Index sample course content, 4) Test search functionality with various queries, 5) Document your configuration and optimization steps. Submission deadline: February 15, 2024.",
  "description1": "Hands-on project for search engine implementation",
  "description2": "Worth 30% of final grade, group work allowed",
  "type": 1,
  "contextid": 12380,
  "areaid": "mod_assign-activity",
  "courseid": 6,
  "groupid": 0,
  "userid": 0,
  "owneruserid": 45,
  "itemid": 5001,
  "modified": "2024-01-25T10:00:00Z"
}'

# Array of all test documents
ALL_DOCUMENTS=(
  "$FORUM_POST_1"
  "$COURSE_1"
  "$WIKI_PAGE_1"
  "$GLOSSARY_ENTRY_1"
  "$BOOK_CHAPTER_1"
  "$FORUM_POST_2"
  "$ASSIGNMENT_1"
)

DOCUMENT_NAMES=(
  "Forum Post: Solr Configuration"
  "Course: Advanced Moodle Admin"
  "Wiki: Solr Best Practices"
  "Glossary: Apache Lucene"
  "Book Chapter: Search Engines"
  "Forum Post: Performance Issue"
  "Assignment: Global Search Project"
)

# =========================================
# MAIN TEST EXECUTION
# =========================================

print_header "MOODLE DOCUMENT TESTING FOR SOLR"

print_info "Configuration:"
print_info "  Solr Core: ${SOLR_CORE}"
print_info "  Keep Documents: ${KEEP_DOCUMENTS}"
print_info "  Wait Time: ${WAIT_TIME}s"
# Baseline Solr log line count so healthcheck only evaluates logs produced by this script run.
SOLR_LOG_BASELINE_LINES=$(docker compose logs --no-color solr 2>/dev/null | wc -l | tr -d ' ')
echo ""

# Ensure test target exists (Collection in SolrCloud, Core in Standalone)
SOLR_MODE_ENV="${SOLR_MODE:-}"
IS_SOLRCLOUD=false
if [ "${SOLR_MODE_ENV}" = "solrcloud" ]; then
  IS_SOLRCLOUD=true
fi

if [ "$IS_SOLRCLOUD" = "true" ]; then
  COLLECTIONS_JSON=$(curl -s -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" \
    "http://${SOLR_HOST}:${SOLR_PORT}/solr/admin/collections?action=LIST&wt=json")
  if ! echo "$COLLECTIONS_JSON" | grep -q "\"${SOLR_CORE}\""; then
    print_info "Collection '${SOLR_CORE}' fehlt — erstelle Test-Collection via Collections API"
    curl -s -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" \
      "http://${SOLR_HOST}:${SOLR_PORT}/solr/admin/collections?action=CREATE&name=${SOLR_CORE}&numShards=1&replicationFactor=1&collection.configName=eLeDia-moodle-tenant&wt=json" >/dev/null
    sleep 2
  fi
else
  if ! curl -s -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" \
    "http://${SOLR_HOST}:${SOLR_PORT}/solr/admin/cores?action=STATUS&core=${SOLR_CORE}&wt=json" \
    | grep -q '"instanceDir"'; then
    print_info "Core '${SOLR_CORE}' fehlt — erstelle Test-Core via Core Admin API"
    curl -s -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" \
      "http://${SOLR_HOST}:${SOLR_PORT}/solr/admin/cores?action=CREATE&name=${SOLR_CORE}&configSet=eLeDia-moodle-tenant&wt=json" >/dev/null
    sleep 2
  fi
fi

# Re-baseline logs after setup actions to avoid false positives in final log healthcheck
SOLR_LOG_BASELINE_LINES=$(docker compose logs --no-color solr 2>/dev/null | wc -l | tr -d ' ')

# Solr connectivity test
print_header "CONNECTIVITY TEST"
print_test "Solr connectivity and authentication"
PING_RESULT=$(solr_get "select?q=*:*&rows=0&wt=json" 2>&1)
if echo "$PING_RESULT" | jq -e '.responseHeader.status == 0' >/dev/null 2>&1; then
  print_pass "Solr is reachable and authenticated"
else
  print_fail "Cannot connect to Solr"
  echo "Response: $PING_RESULT"
  exit 1
fi

# Index test documents
print_header "DOCUMENT INDEXING"
for i in "${!ALL_DOCUMENTS[@]}"; do
  print_test "Indexing: ${DOCUMENT_NAMES[$i]}"

  # Wrap document in array for Solr
  DOC_ARRAY=$(solr_add_doc "${ALL_DOCUMENTS[$i]}")
  RESPONSE=$(solr_post "update?commit=true" "$DOC_ARRAY")

  if echo "$RESPONSE" | grep -q '"status":0'; then
    print_pass "Document indexed successfully"
    ((DOCS_INDEXED++))
  else
    print_fail "Failed to index document"
    echo "Response: $RESPONSE"
  fi
done

print_info "Indexed ${DOCS_INDEXED}/${#ALL_DOCUMENTS[@]} documents"

# Wait for soft commit
echo ""
print_info "Waiting 2s for auto-soft-commit..."
sleep 2

# Query tests
print_header "QUERY TESTS"

# Simple text search
print_test "Simple text search (q=Solr)"
RESULT=$(solr_get "select?q=Solr&wt=json")
NUM_FOUND=$(echo "$RESULT" | jq -r '.response.numFound' 2>/dev/null || echo "0")
if [ "$NUM_FOUND" -ge 3 ]; then
  print_pass "Found $NUM_FOUND documents containing 'Solr'"
else
  print_fail "Expected at least 3 documents, found $NUM_FOUND"
fi

# Field-specific search
print_test "Field-specific search (title:performance)"
RESULT=$(solr_get "select?q=title:performance&wt=json")
NUM_FOUND=$(echo "$RESULT" | jq -r '.response.numFound' 2>/dev/null || echo "0")
if [ "$NUM_FOUND" -ge 1 ]; then
  print_pass "Found $NUM_FOUND documents with 'performance' in title"
else
  print_fail "Expected at least 1 document, found $NUM_FOUND"
fi

# Filter query (courseid)
print_test "Filter query (fq=courseid:5)"
RESULT=$(solr_get "select?q=*:*&fq=courseid:5&wt=json")
NUM_FOUND=$(echo "$RESULT" | jq -r '.response.numFound' 2>/dev/null || echo "0")
if [ "$NUM_FOUND" -ge 2 ]; then
  print_pass "Found $NUM_FOUND documents in course 5"
else
  print_fail "Expected at least 2 documents, found $NUM_FOUND"
fi

# Multiple area filter
print_test "Area filter (fq=areaid:(mod_forum-posts OR mod_book-chapters))"
RESULT=$(solr_get "select?q=*:*&fq=areaid:(mod_forum-posts%20OR%20mod_book-chapters)&wt=json")
NUM_FOUND=$(echo "$RESULT" | jq -r '.response.numFound' 2>/dev/null || echo "0")
if [ "$NUM_FOUND" -ge 3 ]; then
  print_pass "Found $NUM_FOUND documents in forum posts or book chapters"
else
  print_fail "Expected at least 3 documents, found $NUM_FOUND"
fi

# Phrase search
print_test "Phrase search (q=\"Apache Solr\")"
RESULT=$(solr_get "select?q=%22Apache%20Solr%22&wt=json")
NUM_FOUND=$(echo "$RESULT" | jq -r '.response.numFound' 2>/dev/null || echo "0")
if [ "$NUM_FOUND" -ge 1 ]; then
  print_pass "Found $NUM_FOUND documents with phrase 'Apache Solr'"
else
  print_fail "Expected at least 1 document, found $NUM_FOUND"
fi

# Wildcard search
print_test "Wildcard search (q=optimi*)"
RESULT=$(solr_get "select?q=optimi*&wt=json")
NUM_FOUND=$(echo "$RESULT" | jq -r '.response.numFound' 2>/dev/null || echo "0")
if [ "$NUM_FOUND" -ge 2 ]; then
  print_pass "Found $NUM_FOUND documents matching 'optimi*'"
else
  print_fail "Expected at least 2 documents, found $NUM_FOUND"
fi

# Moodle engine-like query patterns (validated against Moodle 4.1-5.2 Solr engine fq usage)
print_header "MOODLE 4.1-5.2 QUERY COMPATIBILITY"

assert_min_hits \
  "Moodle-style course filter ({!cache=false}courseid:(5 OR 6))" \
  "select?q=*:*&fq=%7B!cache=false%7Dcourseid:(5%20OR%206)&wt=json" \
  4

assert_min_hits \
  "Moodle-style area filter ({!cache=false}areaid:(mod_forum-posts OR core_course))" \
  "select?q=*:*&fq=%7B!cache=false%7Dareaid:(mod_forum-posts%20OR%20core_course)&wt=json" \
  3

assert_min_hits \
  "Moodle owner visibility filter (owneruserid:(-1 OR 123))" \
  "select?q=*:*&fq=owneruserid:(%5C-1%20OR%20123)&wt=json" \
  3

assert_min_hits \
  "Moodle context filter (contextid:(12345 OR 12350))" \
  "select?q=*:*&fq=contextid:(12345%20OR%2012350)&wt=json" \
  3

print_test "Moodle group visibility pattern (group/context fallback) [POST]"
GROUP_VIS_RESULT=$(curl -s -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" \
  -X POST "http://${SOLR_HOST}:${SOLR_PORT}/solr/${SOLR_CORE}/select?wt=json" \
  --data-urlencode 'q=*:*' \
  --data-urlencode 'fq=(*:* -groupid:[* TO *]) OR groupid:(0) OR (*:* -contextid:(12345))')
GROUP_VIS_FOUND=$(echo "$GROUP_VIS_RESULT" | jq -r '.response.numFound' 2>/dev/null || echo "0")
if [ "$GROUP_VIS_FOUND" -ge 7 ]; then
  print_pass "Found $GROUP_VIS_FOUND documents (expected >= 7)"
else
  print_fail "Found $GROUP_VIS_FOUND documents (expected >= 7)"
fi

print_test "Combined Moodle query (q=Solr + course + area + owner filters) [POST]"
COMBINED_RESULT=$(curl -s -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" \
  -X POST "http://${SOLR_HOST}:${SOLR_PORT}/solr/${SOLR_CORE}/select?wt=json" \
  --data-urlencode 'q=Solr' \
  --data-urlencode 'fq={!cache=false}courseid:(5 OR 6)' \
  --data-urlencode 'fq={!cache=false}areaid:(mod_forum-posts OR mod_wiki-pages OR mod_assign-activity)' \
  --data-urlencode 'fq=owneruserid:(-1 OR 123 OR 156 OR 45)')
COMBINED_FOUND=$(echo "$COMBINED_RESULT" | jq -r '.response.numFound' 2>/dev/null || echo "0")
if [ "$COMBINED_FOUND" -ge 3 ]; then
  print_pass "Found $COMBINED_FOUND documents (expected >= 3)"
else
  print_fail "Found $COMBINED_FOUND documents (expected >= 3)"
fi

# Highlighting
print_header "HIGHLIGHTING TEST"
print_test "Highlighting (hl=true, hl.fl=title,content)"
RESULT=$(solr_get "select?q=Solr&hl=true&hl.fl=title,content&wt=json")
HAS_HIGHLIGHTING=$(echo "$RESULT" | jq -r 'has("highlighting")' 2>/dev/null || echo "false")
if [ "$HAS_HIGHLIGHTING" = "true" ]; then
  HIGHLIGHT_COUNT=$(echo "$RESULT" | jq -r '.highlighting | length' 2>/dev/null || echo "0")
  print_pass "Highlighting enabled, $HIGHLIGHT_COUNT documents highlighted"
else
  print_fail "Highlighting not working"
fi

# Faceting
print_header "FACETING TEST"
print_test "Faceting by areaid"
RESULT=$(solr_get "select?q=*:*&facet=true&facet.field=areaid&wt=json")
HAS_FACETS=$(echo "$RESULT" | jq -r 'has("facet_counts")' 2>/dev/null || echo "false")
if [ "$HAS_FACETS" = "true" ]; then
  FACET_COUNT=$(echo "$RESULT" | jq -r '.facet_counts.facet_fields.areaid | length' 2>/dev/null || echo "0")
  print_pass "Faceting working, $FACET_COUNT facet values"
else
  print_fail "Faceting not working"
fi

# Sorting
print_header "SORTING TEST"
print_test "Sort by modification date (sort=modified desc)"
RESULT=$(solr_get "select?q=*:*&sort=modified%20desc&rows=2&wt=json")
NUM_FOUND=$(echo "$RESULT" | jq -r '.response.numFound' 2>/dev/null || echo "0")
if [ "$NUM_FOUND" -ge 1 ]; then
  FIRST_DOC_TITLE=$(echo "$RESULT" | jq -r '.response.docs[0].title' 2>/dev/null || echo "")
  print_pass "Sorting works, most recent: $FIRST_DOC_TITLE"
else
  print_fail "Sorting test failed"
fi

# Document count verification
print_header "INDEX VERIFICATION"
print_test "Total document count in index"
RESULT=$(solr_get "select?q=*:*&rows=0&wt=json")
TOTAL_DOCS=$(echo "$RESULT" | jq -r '.response.numFound' 2>/dev/null || echo "0")
if [ "$TOTAL_DOCS" -ge "$DOCS_INDEXED" ]; then
  print_pass "Index contains $TOTAL_DOCS documents (expected at least $DOCS_INDEXED)"
else
  print_fail "Index only contains $TOTAL_DOCS documents, expected at least $DOCS_INDEXED"
fi

# WebUI Inspection pause
if [ "$KEEP_DOCUMENTS" = true ] || [ "$WAIT_TIME" -gt 0 ]; then
  print_header "WEBUI INSPECTION PAUSE"

  print_info "Documents are indexed and ready for inspection!"
  print_info ""
  print_info "Open Solr WebUI to view documents:"
  print_info "  URL: http://${SOLR_HOST}:${SOLR_PORT}/solr/#/${SOLR_CORE}/query"
  print_info "  Username: ${SOLR_ADMIN_USER}"
  print_info "  Password: <from .env file>"
  print_info ""
  print_info "Try these queries in the WebUI:"
  print_info "  q=*:*                        (all documents)"
  print_info "  q=Solr                       (search for 'Solr')"
  print_info "  q=title:performance          (search in titles)"
  print_info "  q=*:*&fq=courseid:5         (filter by course)"
  print_info "  q=Solr&hl=true&hl.fl=content (with highlighting)"
  print_info ""

  if [ "$WAIT_TIME" -gt 0 ]; then
    print_info "Waiting ${WAIT_TIME} seconds before cleanup..."
    sleep "$WAIT_TIME"
  else
    print_info "Documents will be kept (no automatic cleanup)"
    print_info "To manually cleanup, run:"
    print_info "  curl -u admin:password -X POST \"http://${SOLR_HOST}:${SOLR_PORT}/solr/${SOLR_CORE}/update?commit=true\" -H \"Content-Type: text/xml\" --data-binary '<delete><query>*:*</query></delete>'"
  fi
fi

# PDF / Tika extraction test
print_header "TIKA FILE INDEXING TEST"

FIXTURE_SCRIPT="tests/create-moodle-fixtures.sh"
if [ -f "$FIXTURE_SCRIPT" ]; then
  print_info "Generating file fixtures via ${FIXTURE_SCRIPT}"
  sh "$FIXTURE_SCRIPT" >/tmp/_fixture_gen.log 2>&1 || {
    print_fail "Fixture generation failed"
    sed 's/^/[FIXTURE] /' /tmp/_fixture_gen.log | head -n 20
  }
fi

PDF_FILE="tests/test-moodle-document.pdf"
if [ -f "$PDF_FILE" ]; then
  # Step 1: verify Tika extracts text from the PDF
  print_test "Tika extraction: upload test PDF to /update/extract (expect 200)"
  TIKA_RESP=$(curl -s -o /tmp/_tika_resp -w '%{http_code}' \
    -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" \
    -F "file=@${PDF_FILE}" \
    "http://${SOLR_HOST}:${SOLR_PORT}/solr/${SOLR_CORE}/update/extract?extractOnly=true&wt=json" 2>/dev/null)
  if [ "$TIKA_RESP" = "200" ]; then
    print_pass "Tika extraction endpoint reachable (HTTP 200)"
    # Verify extracted text contains known keyword
    if grep -q "ELEDIA TIKA TEST MARKER" /tmp/_tika_resp 2>/dev/null; then
      print_pass "Tika extracted PDF text content correctly (marker found)"
    else
      print_info "Tika extractOnly returned 200 but marker string not found (parser-dependent); semantic PDF search check remains authoritative"
    fi
  else
    print_fail "Tika extraction failed (HTTP $TIKA_RESP) — check SOLR_MODULES=extraction"
  fi

  # Step 2: index the PDF with Tika into Solr
  print_test "Tika indexing: index test PDF into Solr core"
  TIKA_IDX=$(curl -s -o /dev/null -w '%{http_code}' \
    -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" \
    -F "file=@${PDF_FILE}" \
    "http://${SOLR_HOST}:${SOLR_PORT}/solr/${SOLR_CORE}/update/extract?commit=true&literal.id=tika_test_pdf&literal.title=Solr+Tika+PDF+Test&literal.areaid=test_files&literal.contextid=99999&literal.itemid=1&literal.courseid=1&literal.owneruserid=1&literal.modified=2026-01-01T00:00:00Z&literal.type=1&wt=json" 2>/dev/null)
  if [ "$TIKA_IDX" = "200" ]; then
    print_pass "PDF indexed via Tika (HTTP 200)"
    ((DOCS_INDEXED++))

    # Step 3: search for content that was inside the PDF
    sleep 1
    print_test "PDF content searchable: marker query scoped to indexed PDF id"
    SEARCH_RESP=$(solr_get "select?q=content:ELEDIA+TIKA+TEST+MARKER&fq=id:tika_test_pdf&wt=json")
    PDF_HITS=$(echo "$SEARCH_RESP" | jq -r '.response.numFound // 0')
    if [ "$PDF_HITS" -ge 1 ]; then
      print_pass "PDF marker searchable in content field (id=tika_test_pdf)"
    else
      print_fail "PDF marker not searchable in content field for id=tika_test_pdf"
    fi

    # Step 4: search for other keywords from the PDF
    print_test "PDF content: query for 'moodle solr tika'"
    SEARCH_RESP=$(solr_get "select?q=moodle+solr+tika&wt=json")
    FOUND=$(echo "$SEARCH_RESP" | jq -r '.response.numFound' 2>/dev/null || echo "0")
    if [ "$FOUND" -ge 1 ]; then
      print_pass "PDF textual content indexed and searchable"
    else
      print_fail "PDF textual content not found in index"
    fi
  else
    print_fail "PDF indexing via Tika failed (HTTP $TIKA_IDX)"
  fi
  rm -f /tmp/_tika_resp
else
  print_skip "Test PDF not found at $PDF_FILE — skipping Tika tests"
  print_info "Generate with: sh tests/create-moodle-fixtures.sh"
fi

# Multi-format Tika checks (text files, HTML, CSV, RTF, image metadata)
print_header "MULTI-FORMAT FILE TESTS"

FILE_FIXTURES=(
  "tests/fixture-notes.txt|tika_fixture_txt|ELEDIA TIKA TEST MARKER"
  "tests/fixture-course-overview.html|tika_fixture_html|ELEDIA HTML FIXTURE MARKER"
  "tests/fixture-gradebook.csv|tika_fixture_csv|workplace indexing"
  "tests/fixture-announcement.rtf|tika_fixture_rtf|ELEDIA RTF FIXTURE MARKER"
  "tests/fixture-campus-photo.png|tika_fixture_png|"
)

for spec in "${FILE_FIXTURES[@]}"; do
  IFS='|' read -r file_path doc_id marker <<< "$spec"

  if [ ! -f "$file_path" ]; then
    print_skip "Fixture missing: $file_path"
    continue
  fi

  print_test "Tika index fixture: $(basename "$file_path")"
  idx_code=$(curl -s -o /tmp/_tika_idx -w '%{http_code}' \
    -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" \
    -F "file=@${file_path}" \
    "http://${SOLR_HOST}:${SOLR_PORT}/solr/${SOLR_CORE}/update/extract?commit=true&literal.id=${doc_id}&literal.title=$(basename "$file_path")&literal.areaid=test_files&literal.contextid=99999&literal.itemid=1&literal.courseid=1&literal.owneruserid=1&literal.modified=2026-01-01T00:00:00Z&literal.type=1&wt=json" 2>/dev/null)

  if [ "$idx_code" = "200" ]; then
    print_pass "Indexed $(basename "$file_path")"
    ((DOCS_INDEXED++))
  else
    print_fail "Indexing failed for $(basename "$file_path") (HTTP $idx_code)"
    sed 's/^/[IDX] /' /tmp/_tika_idx | head -n 10
    continue
  fi

  assert_min_hits "Indexed doc retrievable by id: ${doc_id}" \
    "select?q=id:${doc_id}&rows=1&wt=json" 1

  if [ -n "$marker" ]; then
    print_test "Tika extractOnly validates content in $(basename "$file_path")"
    extract_code=$(curl -s -o /tmp/_tika_extract -w '%{http_code}' \
      -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" \
      -F "file=@${file_path}" \
      "http://${SOLR_HOST}:${SOLR_PORT}/solr/${SOLR_CORE}/update/extract?extractOnly=true&wt=json" 2>/dev/null)

    if [ "$extract_code" = "200" ] && grep -qi "$marker" /tmp/_tika_extract; then
      print_pass "Extracted text contains expected marker"
    else
      print_fail "extractOnly did not return expected marker for $(basename "$file_path")"
      sed 's/^/[EXTRACT] /' /tmp/_tika_extract | head -n 10
    fi
  fi
done
rm -f /tmp/_tika_idx /tmp/_tika_extract /tmp/_fixture_gen.log

# Abort if no documents were indexed — cleanup would be misleading
if [ "$DOCS_INDEXED" -eq 0 ]; then
  echo -e "${RED}ERROR: No documents were indexed — aborting without cleanup${NC}"
  exit 1
fi

# Cleanup
if [ "$KEEP_DOCUMENTS" = false ]; then
  print_header "CLEANUP"
  print_test "Removing test documents"

  # Use proper Content-Type for XML delete
  CLEANUP_RESPONSE=$(curl -s -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" \
    -H "Content-Type: text/xml" \
    -X POST \
    "http://${SOLR_HOST}:${SOLR_PORT}/solr/${SOLR_CORE}/update?commit=true" \
    --data-binary '<delete><query>*:*</query></delete>')

  # Check for success in both JSON and XML format
  if echo "$CLEANUP_RESPONSE" | grep -qE '("status":0|<int name="status">0</int>)'; then
    print_pass "Test documents removed successfully"
  else
    print_fail "Failed to cleanup test documents"
    echo "Cleanup response: $CLEANUP_RESPONSE"
  fi

  # Verify cleanup
  sleep 1
  RESULT=$(solr_get "select?q=*:*&rows=0&wt=json")
  REMAINING_DOCS=$(echo "$RESULT" | jq -r '.response.numFound' 2>/dev/null || echo "999")

  if [ "$REMAINING_DOCS" -eq 0 ]; then
    print_pass "Index is clean (0 documents)"
  else
    print_fail "Index still contains $REMAINING_DOCS documents"
  fi
fi

# Solr log validation after query workload
print_header "SOLR LOG HEALTHCHECK"
print_test "No actionable ERROR/SEVERE in recent Solr logs"
SOLR_LOG_ALL=$(docker compose logs --no-color solr 2>/dev/null || true)
SOLR_LOG_TAIL=$(echo "$SOLR_LOG_ALL" | awk -v n="$SOLR_LOG_BASELINE_LINES" 'NR>n')
LOG_REPORT="tests/solr-log-findings.md"
{
  echo "# Solr Log Findings"
  echo ""
  echo "Generated: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  echo ""
  echo "## Scope"
  echo "- Source: docker compose logs --tail=400 solr"
  echo "- Focus: actionable WARN/ERROR/SEVERE related to Moodle/Solr indexing and query behavior"
  echo ""
} > "$LOG_REPORT"

SOLR_ERRORS=$(echo "$SOLR_LOG_TAIL" | grep -E '^[^|]*\| .*\b(ERROR|SEVERE)\b\s+\(' | grep -Evi 'SSL is off|No appenders could be found' || true)
if [ -z "$SOLR_ERRORS" ]; then
  print_pass "No actionable ERROR/SEVERE lines found in recent Solr logs"
  {
    echo "## ERROR/SEVERE"
    echo "none"
    echo ""
  } >> "$LOG_REPORT"
else
  print_fail "Actionable ERROR/SEVERE lines detected in Solr logs"
  print_info "First findings:"
  echo "$SOLR_ERRORS" | head -n 8 | sed 's/^/[LOG] /'
  {
    echo "## ERROR/SEVERE"
    echo '```'
    echo "$SOLR_ERRORS" | head -n 50
    echo '```'
    echo ""
  } >> "$LOG_REPORT"
fi

print_test "No actionable WARN lines in recent Solr logs"
SOLR_WARNINGS=$(echo "$SOLR_LOG_TAIL" | grep -Ei '\bWARN\b' | grep -Evi 'SSL is off|deprecated|deprecation|Jetty request logging enabled|ZkCredentialsInjector|ZkACLProvider|OPEN_ACL_UNSAFE|DefaultZkACLProvider|MessagingBinders .*DataSource.*not found|FileSystemFontProvider New fonts found|FileSystemFontProvider Building on-disk font cache|FileSystemFontProvider Finished building on-disk font cache|PDType1Font Using fallback font LiberationSans' || true)
if [ -z "$SOLR_WARNINGS" ]; then
  print_pass "No actionable WARN lines found in recent Solr logs"
  {
    echo "## WARN"
    echo "none"
    echo ""
  } >> "$LOG_REPORT"
else
  print_fail "Actionable WARN lines detected in Solr logs"
  print_info "First findings:"
  echo "$SOLR_WARNINGS" | head -n 8 | sed 's/^/[LOG] /'
  {
    echo "## WARN"
    echo '```'
    echo "$SOLR_WARNINGS" | head -n 80
    echo '```'
    echo ""
  } >> "$LOG_REPORT"
fi
print_test "No URI size overflow warnings in Solr logs"
SOLR_URI_WARN=$(echo "$SOLR_LOG_TAIL" | grep -E 'URI is too large' || true)
if [ -z "$SOLR_URI_WARN" ]; then
  print_pass "No URI size overflow warnings found"
  {
    echo "## URI length"
    echo "none"
    echo ""
  } >> "$LOG_REPORT"
else
  print_fail "URI size overflow warnings detected (Jetty HttpParser)"
  echo "$SOLR_URI_WARN" | head -n 8 | sed 's/^/[LOG] /'
  {
    echo "## URI length"
    echo '```'
    echo "$SOLR_URI_WARN" | head -n 50
    echo '```'
    echo ""
  } >> "$LOG_REPORT"
fi
print_info "Log findings written to ${LOG_REPORT}"

# Summary
print_header "TEST SUMMARY"
echo ""
TOTAL_ASSERTIONS=$((TESTS_PASSED + TESTS_FAILED))
echo -e "${BOLD}Total Tests:${NC}    $TOTAL_ASSERTIONS"
echo -e "${GREEN}${BOLD}Passed:${NC}         $TESTS_PASSED"
echo -e "${RED}${BOLD}Failed:${NC}         $TESTS_FAILED"
echo ""
echo -e "${BOLD}Documents:${NC}      $DOCS_INDEXED indexed"
echo ""
echo "RESULTS:total=${TOTAL_ASSERTIONS};passed=${TESTS_PASSED};failed=${TESTS_FAILED}"

if [ "$TESTS_FAILED" -eq 0 ]; then
  SUCCESS_RATE=100
  echo -e "${BOLD}Success Rate:${NC}   ${SUCCESS_RATE}%"
  echo ""
  echo -e "${GREEN}${BOLD}MOODLE DOCUMENT TESTS PASSED${NC}"
  exit 0
else
  if [ "$TOTAL_ASSERTIONS" -gt 0 ]; then
    SUCCESS_RATE=$((TESTS_PASSED * 100 / TOTAL_ASSERTIONS))
  else
    SUCCESS_RATE=0
  fi
  echo -e "${BOLD}Success Rate:${NC}   ${SUCCESS_RATE}%"
  echo ""
  echo -e "${RED}${BOLD}SOME TESTS FAILED${NC}"
  exit 1
fi
