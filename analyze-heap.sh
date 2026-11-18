#!/bin/bash
###############################################################################
## Java Heap Dump Analyzer - Eclipse Memory Analyzer (MAT)
###############################################################################
##
## DESCRIPTION:
##   Command-line utility to analyze Java heap dumps (.hprof) using Eclipse MAT.
##
##   Generates:
##     1. Leak Suspects report
##     2. Overview report
##     3. Top Components report
##     4. Class Histogram report (text format)
##
## OFFICIAL DOWNLOAD:
##   https://eclipse.dev/mat/download/
##
## DOCUMENTATION:
##   https://help.eclipse.org/latest/topic/org.eclipse.mat.ui.help/tasks/batch.html
##   https://help.eclipse.org/latest/topic/org.eclipse.mat.ui.help/tasks/configure_mat.html
##
## PREREQUISITES:
##   - Linux 64-bit
##   - Java 21 or newer for current MAT releases
##   - Eclipse MAT standalone Linux distribution
##   - Sufficient RAM and disk space
##
## NOTE:
##   The Java version used to run MAT does not have to match the Java version
##   used by the application that generated the heap dump.
##
###############################################################################
## 1. DIRECTORY STRUCTURE
###############################################################################
##
##   Create the following directory structure:
##
##   java-heap-analyzer/
##   |
##   |-- mat/
##   |    |-- ParseHeapDump.sh
##   |    |-- MemoryAnalyzer.ini
##   |    |-- plugins/
##   |
##   |-- heapdumps/
##   |    |-- heapdump.hprof
##   |
##   |-- reports/
##   |
##   |-- logs/
##   |
##   |-- analyze-heap.sh
##
##   Directory purposes:
##
##     mat/       - Eclipse MAT installation
##     heapdumps/ - Input Java heap dumps (.hprof)
##     reports/   - Generated analysis reports
##     logs/      - Execution logs
##
###############################################################################
## 2. DOWNLOAD AND INSTALL ECLIPSE MAT
###############################################################################
##
##   Download the standalone Linux 64-bit version from:
##
##   https://eclipse.dev/mat/download/
##
##   Extract MAT into the mat directory.
##
##   Example:
##
##     mkdir -p ~/java-heap-analyzer/mat
##
##     tar -xzf /tmp/MemoryAnalyzer-*.tar.gz \
##          -C ~/java-heap-analyzer/mat \
##          --strip-components=1
##
##   Verify installation:
##
##     ls -l ~/java-heap-analyzer/mat/ParseHeapDump.sh
##
##   Make executable:
##
##     chmod +x ~/java-heap-analyzer/mat/ParseHeapDump.sh
##
##   IMPORTANT:
##     Archive names and internal directory structures may vary by release.
##     Adjust the extraction command if necessary.
##
###############################################################################
## 3. JAVA CONFIGURATION
###############################################################################
##
##   Current Eclipse MAT releases require Java 21 or newer.
##
##   MAT reads no environment variables of its own. The MemoryAnalyzer
##   launcher picks Java in this order:
##
##     1. -vm in MemoryAnalyzer.ini
##     2. a bundled jre/ directory in the MAT install
##     3. java on PATH
##
##   JAVA_HOME is likely not used by the launcher (not verified); it only
##   helps when PATH is built from it. To pin the version reliably, add these
##   two lines at the top of mat/MemoryAnalyzer.ini, before -vmargs:
##
##     -vm
##     /usr/lib/jvm/java-21-openjdk/bin/java
##
##   Adjust the path for your Linux distribution. If you set -vm, the Java
##   version this script prints may differ from the one MAT actually uses.
##
##   JVM OPTION VARIABLES:
##     The JVM reads these itself, so they also apply to MAT. They are often
##     set globally in containers and CI images.
##
##       JAVA_TOOL_OPTIONS - applied before the command line; the ini wins.
##       _JAVA_OPTIONS     - applied after the command line; overrides the
##                           ini. A stray -Xmx here silently caps MAT.
##
##     If MAT runs out of memory with a correct ini, check: env | grep JAVA
##
##   SCRIPT VARIABLES (this script only, not MAT):
##
##     BASE_DIR - root directory (default: ~/java-heap-analyzer)
##     MAT_HOME - Eclipse MAT install (default: $BASE_DIR/mat)
##
###############################################################################
## 4. MAT MEMORY CONFIGURATION
###############################################################################
##
##   Edit the existing -Xmx line under -vmargs in mat/MemoryAnalyzer.ini
##   (don't add a second one). The shipped default is -Xmx1024m.
##
##     -vmargs
##     -Xmx31g
##     -XX:+AlwaysPreTouch
##
##   SIZING:
##     MAT memory depends on object count, not dump size. MAT's docs estimate
##     the minimum to parse as:
##
##       bytes ~= objects * 28.25 + classes * 1000 + parser overhead
##
##     Rule of thumb: -Xmx = 1x dump size to start, 1.5x for comfort.
##     Machine RAM = -Xmx plus a few GB for the OS and page cache, which MAT
##     uses for its index files.
##
##     For an exact object count, run this on the live JVM before dumping
##     (it triggers a full GC) and read the instance count on the Total line:
##
##       jcmd <pid> GC.class_histogram | tail -1
##
##   LIMITS:
##     - No MAT memory cap; physical RAM is the limit.
##     - Max 2,147,483,639 objects per dump.
##     - Stay at -Xmx31g or below, or go well above it. From 32g the JVM
##       disables compressed oops and every reference doubles in size.
##
##   XMS:
##     -Xms does not reserve physical RAM on Linux; pages are only committed
##     when touched. -XX:+AlwaysPreTouch commits the whole heap at startup,
##     so MAT fails immediately if the RAM isn't there instead of mid-parse.
##     It slows startup on large heaps. Setting -Xms equal to -Xmx is
##     harmless but optional.
##
##   LESS MEMORY THAN THE DUMP SIZE:
##     Usually works, since the limit is object count. If it doesn't:
##     1. Parse on a bigger machine, then copy the dump and its index files
##        to a smaller one. A parsed dump opens with much less memory.
##     2. Take live-only dumps (jcmd default). Avoid jcmd -all and MAT's
##        -keep_unreachable_objects, which add objects.
##     3. Last resort: -discard_ratio=<percent> -discard_pattern=<regex>.
##        Experimental. Skips indexing matching objects, so leak suspects
##        and the dominator tree become incomplete.
##
###############################################################################
## 5. HOW TO USE
###############################################################################
##
##   Step 0 (optional): Capture a heap dump
##
##     Run as the same OS user as the target JVM. The JVM itself writes the
##     file, so the path is on its filesystem and needs roughly heap-size
##     free space. Dumping pauses the application (seconds to minutes).
##
##       jcmd -l                                   # find the PID
##       jcmd <pid> GC.heap_dump /tmp/heapdump.hprof
##
##     Or with jmap:
##
##       jmap -dump:live,format=b,file=/tmp/heapdump.hprof <pid>
##
##     Both run a full GC first, so only live objects are dumped. Add -all
##     to jcmd to keep unreachable objects. Don't use -gz, since this script
##     expects a plain .hprof.
##
##     From a Kubernetes pod (the image needs a JDK for jcmd and tar for
##     kubectl cp; the JVM is usually PID 1):
##
##       kubectl exec <pod> -- jcmd 1 GC.heap_dump /tmp/heapdump.hprof
##       kubectl cp <pod>:/tmp/heapdump.hprof ./heapdumps/heapdump.hprof
##       kubectl exec <pod> -- rm /tmp/heapdump.hprof
##
##     To capture automatically on OutOfMemoryError, start the JVM with:
##
##       -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/path/to/dumps/
##
##   Step 1:
##     Place the Java heap dump inside:
##
##       ~/java-heap-analyzer/heapdumps/
##
##   Example:
##
##       ~/java-heap-analyzer/heapdumps/heapdump.hprof
##
##   Step 2:
##     Run this script:
##
##       ./analyze-heap.sh ./heapdumps/heapdump.hprof
##
##   Or provide an absolute path:
##
##       ./analyze-heap.sh /tmp/heapdump.hprof
##
##   Step 3:
##     Review reports under:
##
##       ~/java-heap-analyzer/reports/
##
###############################################################################
## 6. REPORT DESCRIPTIONS
###############################################################################
##
##   Leak Suspects:
##     Identifies potential memory leaks and large object retention chains.
##
##   Overview:
##     Provides a general overview of the heap, threads and class histogram.
##
##   Top Components:
##     Identifies memory consumption grouped by components and classes.
##
##   Histogram:
##     Provides class-level object counts and shallow heap usage.
##
##   NOTE:
##     A leak suspect is not necessarily a confirmed memory leak.
##     Further investigation of object references and GC roots may be needed.
##     Start with each suspect's "Shortest Paths To the Accumulation Point"
##     and "Accumulated Objects in Dominator Tree" sections. They also give
##     the object addresses (@ 0x...) and class names used below.
##
##   INVESTIGATING FROM THE COMMAND LINE:
##     Any MAT query runs headless through org.eclipse.mat.api:query, the
##     same way section 12 builds the histogram. The index files from the
##     first run are reused, so these skip the parse.
##
##       MAT=~/java-heap-analyzer/mat/ParseHeapDump.sh
##       DUMP=~/java-heap-analyzer/heapdumps/heapdump.hprof
##
##     Why instances of a class are alive (merged paths to GC roots,
##     weak and soft references excluded):
##
##       Q="merge_shortest_paths com.example.CacheEntry"
##       Q="$Q -excludes java.lang.ref.WeakReference:referent"
##       Q="$Q java.lang.ref.SoftReference:referent"
##       "$MAT" "$DUMP" -format=txt -command="$Q" org.eclipse.mat.api:query
##
##     Path to GC roots for one object:
##
##       "$MAT" "$DUMP" -format=txt -command="path2gc 0x7f3a2b10" \
##         org.eclipse.mat.api:query
##
##     Incoming references to one object:
##
##       "$MAT" "$DUMP" -format=txt \
##         -command="list_objects 0x7f3a2b10 -inbound" \
##         org.eclipse.mat.api:query
##
##     What keeps instances alive, one level up:
##
##       "$MAT" "$DUMP" -format=txt \
##         -command="immediate_dominators com.example.CacheEntry" \
##         org.eclipse.mat.api:query
##
##     All GC roots, or the full dominator tree:
##
##       -command="gc_roots"
##       -command="dominator_tree"
##
##     Each run writes <dump>_Query.zip next to the dump and overwrites the
##     previous one, so rename or unzip it between queries. Use -format=csv
##     to grep or sort the output. Flag names (-excludes, -inbound) are not
##     verified against every MAT release; check the log if a query fails.
##
###############################################################################
## 7. TROUBLESHOOTING AND OPERATIONAL NOTES
###############################################################################
##
##   OUT OF MEMORY:
##     Increase -Xmx in MemoryAnalyzer.ini. See section 4.
##
##   INSUFFICIENT DISK SPACE:
##     MAT creates additional index files alongside the heap dump.
##     Ensure adequate free disk space before starting.
##
##   SLOW ANALYSIS:
##     Large dumps can take considerable time to parse and analyze.
##
##   JAVA VERSION ISSUES:
##     Verify that MAT is running with Java 21 or newer.
##
##   REPORTS NOT GENERATED:
##     Check logs/ for errors.
##     Verify MAT installation and heap dump integrity.
##
##   SECURITY:
##     Heap dumps may contain passwords, tokens, customer data and other
##     sensitive information. Restrict file permissions and access.
##
##   RECOMMENDATION:
##     Run large heap dump analysis on a dedicated machine rather than
##     on the production application server.
##
###############################################################################
###############################################################################
## 8. ENVIRONMENT AND CONFIGURATION
###############################################################################

__author__="github.com/bytebeast"

# Reports, indexes and logs hold the same sensitive data as the dump.
umask 077

BASE_DIR="${BASE_DIR:-$HOME/java-heap-analyzer}"

MAT_HOME="${MAT_HOME:-$BASE_DIR/mat}"
HEAP_DIR="$BASE_DIR/heapdumps"
REPORT_DIR="$BASE_DIR/reports"
LOG_DIR="$BASE_DIR/logs"

# Optional Java configuration. Prefer -vm in MemoryAnalyzer.ini (section 3).
# Otherwise uncomment and modify if Java 21 is not the system default.
#
# export JAVA_HOME=/usr/lib/jvm/java-21-openjdk
# export PATH="$JAVA_HOME/bin:$PATH"

###############################################################################
## 9. INPUT VALIDATION
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
## 10. INITIALIZE ANALYSIS
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
## 11. RUN ECLIPSE MAT REPORTS
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
## 12. GENERATE TEXT HISTOGRAM
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
## 13. DISPLAY RESULTS
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
