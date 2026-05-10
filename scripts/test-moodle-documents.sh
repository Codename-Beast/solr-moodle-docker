#!/bin/bash
# =========================================
# Moodle Document Testing for Solr
# Developer: BSC Bernd Schreistetter
# Company: Eledia.de
# Version: v2.0
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
SOLR_PORT="8983"

# Load SOLR_CORE_NAME from .env or use default
if [ -f ".env" ]; then
    source .env
fi
SOLR_CORE="${SOLR_CORE_NAME:-moodle_core}"

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
echo ""

# Solr connectivity test
print_header "CONNECTIVITY TEST"
print_test "Solr connectivity and authentication"
PING_RESULT=$(solr_get "admin/ping" 2>&1)
if echo "$PING_RESULT" | grep -q '"status":"OK"'; then
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

# Summary
print_header "TEST SUMMARY"
echo ""
echo -e "${BOLD}Total Tests:${NC}    $TESTS_RUN"
echo -e "${GREEN}${BOLD}Passed:${NC}         $TESTS_PASSED"
echo -e "${RED}${BOLD}Failed:${NC}         $TESTS_FAILED"
echo ""
echo -e "${BOLD}Documents:${NC}      $DOCS_INDEXED indexed"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
  SUCCESS_RATE=100
  echo -e "${BOLD}Success Rate:${NC}   ${SUCCESS_RATE}%"
  echo ""
  echo -e "${GREEN}${BOLD}MOODLE DOCUMENT TESTS PASSED${NC}"
  exit 0
else
  SUCCESS_RATE=$((TESTS_PASSED * 100 / TESTS_RUN))
  echo -e "${BOLD}Success Rate:${NC}   ${SUCCESS_RATE}%"
  echo ""
  echo -e "${RED}${BOLD}SOME TESTS FAILED${NC}"
  exit 1
fi
