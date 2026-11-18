#!/bin/bash
###############################################################################
## Java Heap Dump Analyzer - Eclipse Memory Analyzer (MAT)
###############################################################################
##
## Runs Eclipse MAT in batch mode against a Java heap dump (.hprof) and
## collects the Leak Suspects, Overview, Top Components and class histogram
## reports into $BASE_DIR/reports/<dump>/.
##
## USAGE:
##   ./analyze-heap.sh <heapdump.hprof>
##
##   BASE_DIR (default ~/java-heap-analyzer) and MAT_HOME (default
##   $BASE_DIR/mat) override the install paths.
##
## Setup, Java and MAT memory configuration, troubleshooting and
## investigation tips are in README.md.
##
###############################################################################
###############################################################################
## 1. ENVIRONMENT AND CONFIGURATION
###############################################################################

__author__="github.com/bytebeast"

# Reports, indexes and logs hold the same sensitive data as the dump.
umask 077

BASE_DIR="${BASE_DIR:-$HOME/java-heap-analyzer}"

MAT_HOME="${MAT_HOME:-$BASE_DIR/mat}"
HEAP_DIR="$BASE_DIR/heapdumps"
REPORT_DIR="$BASE_DIR/reports"
LOG_DIR="$BASE_DIR/logs"

# Optional Java configuration. Prefer -vm in MemoryAnalyzer.ini (see README).
# Otherwise uncomment and modify if Java 21 is not the system default.
#
# export JAVA_HOME=/usr/lib/jvm/java-21-openjdk
# export PATH="$JAVA_HOME/bin:$PATH"

###############################################################################
## 2. INPUT VALIDATION
###############################################################################

HEAP_DUMP="$1"

if [ -z "$HEAP_DUMP" ]; then
    echo "Usage: $0 <heapdump.hprof>"
    echo
    echo "Example:"
    echo "  $0 $HEAP_DIR/heapdump.hprof"
    exit 1
fi

if [ ! -f "$HEAP_DUMP" ]; then
    echo "ERROR: Heap dump not found: $HEAP_DUMP"
    exit 1
fi

if [ ! -x "$MAT_HOME/ParseHeapDump.sh" ]; then
    echo "ERROR: MAT executable not found:"
    echo "  $MAT_HOME/ParseHeapDump.sh"
    exit 1
fi

for cmd in java unzip; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: $cmd not found in PATH."
        exit 1
    fi
done

mkdir -p "$REPORT_DIR" "$LOG_DIR"

###############################################################################
## 3. INITIALIZE ANALYSIS
###############################################################################

HEAP_DUMP=$(realpath "$HEAP_DUMP")
DUMP_DIR=$(dirname "$HEAP_DUMP")
DUMP_NAME=$(basename "$HEAP_DUMP" .hprof)

DUMP_REPORT_DIR="$REPORT_DIR/$DUMP_NAME"
LOG_FILE="$LOG_DIR/${DUMP_NAME}.log"

mkdir -p "$DUMP_REPORT_DIR"

echo "================================================="
echo "          JAVA HEAP DUMP ANALYZER"
echo "================================================="
echo "Heap Dump : $HEAP_DUMP"
echo "MAT Home  : $MAT_HOME"
echo "Reports   : $DUMP_REPORT_DIR"
echo "Log       : $LOG_FILE"
echo "Java      : $(java -version 2>&1 | grep -m1 version)"
echo "================================================="

# MAT writes report zips next to the dump. Running from the dump's directory
# means they land in the same place even if a release writes to the cwd.
# The marker lets us pick up only zips produced by this run.
MARKER="$DUMP_REPORT_DIR/.run-started"
touch "$MARKER"
cd "$DUMP_DIR" || exit 1

# Moves zips created since the marker into the report dir and extracts each
# into a folder of the same name. Prints how many it collected.
collect_reports() {
    local count=0 zip
    while IFS= read -r -d '' zip; do
        mv -f "$zip" "$DUMP_REPORT_DIR/"
        zip="$DUMP_REPORT_DIR/$(basename "$zip")"
        unzip -oq "$zip" -d "${zip%.zip}"
        count=$((count + 1))
    done < <(find "$DUMP_DIR" -maxdepth 1 -name "${DUMP_NAME}_*.zip" -newer "$MARKER" -print0)
    echo "$count"
}

###############################################################################
## 4. RUN ECLIPSE MAT REPORTS
###############################################################################

echo
echo "Starting Eclipse MAT analysis..."

"$MAT_HOME/ParseHeapDump.sh" "$HEAP_DUMP" \
    org.eclipse.mat.api:suspects \
    org.eclipse.mat.api:overview \
    org.eclipse.mat.api:top_components \
    2>&1 | tee "$LOG_FILE"

MAT_STATUS=${PIPESTATUS[0]}
REPORT_COUNT=$(collect_reports)

# MAT can exit 0 after a report fails, so the zips are the real success test.
if [ "$MAT_STATUS" -ne 0 ] || [ "$REPORT_COUNT" -lt 3 ]; then
    echo "ERROR: MAT report generation failed (exit $MAT_STATUS, $REPORT_COUNT of 3 reports)."
    echo "Review log: $LOG_FILE"
    exit 1
fi

###############################################################################
## 5. GENERATE TEXT HISTOGRAM
###############################################################################

echo
echo "Generating class histogram..."

# Index files from the first run are reused, so this skips the parse.
"$MAT_HOME/ParseHeapDump.sh" "$HEAP_DUMP" \
    -command=histogram \
    -format=txt \
    org.eclipse.mat.api:query \
    2>&1 | tee -a "$LOG_FILE"

HISTOGRAM_STATUS=${PIPESTATUS[0]}

if [ "$HISTOGRAM_STATUS" -ne 0 ] || [ "$(collect_reports)" -lt 1 ]; then
    echo "WARNING: Histogram generation failed."
    echo "Review log: $LOG_FILE"
fi

rm -f "$MARKER"

###############################################################################
## 6. DISPLAY RESULTS
###############################################################################

echo
echo "================================================="
echo "             ANALYSIS COMPLETED"
echo "================================================="
echo "Heap Dump : $HEAP_DUMP"
echo "Reports   : $DUMP_REPORT_DIR"
echo "Log       : $LOG_FILE"
echo
echo "Generated reports:"
find "$DUMP_REPORT_DIR" -maxdepth 1 -name '*.zip' -print
echo
echo "================================================="

exit 0

###############################################################################
## END OF SCRIPT
###############################################################################
