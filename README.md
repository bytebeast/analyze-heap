# analyze-heap

Runs Eclipse MAT in batch mode against a Java heap dump (.hprof) to produce Leak Suspects, System Overview, Top Components and class histogram reports. It collects the report zips from beside the dump into `reports/<dump>/`, extracts them, and fails if any of the three main reports is missing.

## Reports

1. **Leak Suspects** identifies potential memory leaks and large object retention chains.
2. **Overview** gives a general overview of the heap, threads and class histogram.
3. **Top Components** shows memory consumption grouped by components and classes.
4. **Class Histogram** (text) lists class-level object counts and shallow heap usage.

## Prerequisites

- Linux 64-bit
- Java 21 or newer for current MAT releases
- Eclipse MAT standalone Linux distribution
- `unzip` on `PATH`
- Sufficient RAM and disk space

The Java version used to run MAT does not have to match the Java version used by the application that generated the heap dump.

Links:

- Download: https://eclipse.dev/mat/download/
- Batch mode: https://help.eclipse.org/latest/topic/org.eclipse.mat.ui.help/tasks/batch.html
- Configuring MAT: https://help.eclipse.org/latest/topic/org.eclipse.mat.ui.help/tasks/configure_mat.html

## Directory structure

```
java-heap-analyzer/
|-- mat/              Eclipse MAT installation
|    |-- ParseHeapDump.sh
|    |-- MemoryAnalyzer.ini
|    |-- plugins/
|-- heapdumps/        Input Java heap dumps (.hprof)
|    |-- heapdump.hprof
|-- reports/          Generated analysis reports
|-- logs/             Execution logs
|-- analyze-heap.sh
```

## Install Eclipse MAT

Download the standalone Linux 64-bit version from https://eclipse.dev/mat/download/ and extract it into `mat/`:

```sh
mkdir -p ~/java-heap-analyzer/mat

tar -xzf /tmp/MemoryAnalyzer-*.tar.gz \
     -C ~/java-heap-analyzer/mat \
     --strip-components=1

ls -l ~/java-heap-analyzer/mat/ParseHeapDump.sh
chmod +x ~/java-heap-analyzer/mat/ParseHeapDump.sh
```

Archive names and internal directory structures may vary by release. Adjust the extraction command if necessary.

## Java configuration

MAT reads no environment variables of its own. The MemoryAnalyzer launcher picks Java in this order:

1. `-vm` in `MemoryAnalyzer.ini`
2. a bundled `jre/` directory in the MAT install
3. `java` on `PATH`

`JAVA_HOME` is likely not used by the launcher (not verified); it only helps when `PATH` is built from it. To pin the version reliably, add these two lines at the top of `mat/MemoryAnalyzer.ini`, before `-vmargs`:

```
-vm
/usr/lib/jvm/java-21-openjdk/bin/java
```

Adjust the path for your Linux distribution. If you set `-vm`, the Java version the script prints may differ from the one MAT actually uses.

### JVM option variables

The JVM reads these itself, so they also apply to MAT. They are often set globally in containers and CI images.

| Variable | Effect |
| --- | --- |
| `JAVA_TOOL_OPTIONS` | Applied before the command line. The ini wins. |
| `_JAVA_OPTIONS` | Applied after the command line and overrides the ini. A stray `-Xmx` here silently caps MAT. |

If MAT runs out of memory with a correct ini, check `env | grep JAVA`.

### Script variables

These apply to this script only, not MAT.

| Variable | Default |
| --- | --- |
| `BASE_DIR` | `~/java-heap-analyzer` |
| `MAT_HOME` | `$BASE_DIR/mat` |

## MAT memory configuration

Edit the existing `-Xmx` line under `-vmargs` in `mat/MemoryAnalyzer.ini` (don't add a second one). The shipped default is `-Xmx1024m`.

```
-vmargs
-Xmx31g
-XX:+AlwaysPreTouch
```

### Sizing

MAT memory depends on object count, not dump size. MAT's docs estimate the minimum to parse as:

```
bytes ~= objects * 28.25 + classes * 1000 + parser overhead
```

Rule of thumb: `-Xmx` = 1x dump size to start, 1.5x for comfort. Machine RAM = `-Xmx` plus a few GB for the OS and page cache, which MAT uses for its index files.

For an exact object count, run this on the live JVM before dumping (it triggers a full GC) and read the instance count on the Total line:

```sh
jcmd <pid> GC.class_histogram | tail -1
```

### Limits

- No MAT memory cap; physical RAM is the limit.
- Max 2,147,483,639 objects per dump.
- Stay at `-Xmx31g` or below, or go well above it. From 32g the JVM disables compressed oops and every reference doubles in size.

### Xms

`-Xms` does not reserve physical RAM on Linux; pages are only committed when touched. `-XX:+AlwaysPreTouch` commits the whole heap at startup, so MAT fails immediately if the RAM isn't there instead of mid-parse. It slows startup on large heaps. Setting `-Xms` equal to `-Xmx` is harmless but optional.

### Less memory than the dump size

Usually works, since the limit is object count. If it doesn't:

1. Parse on a bigger machine, then copy the dump and its index files to a smaller one. A parsed dump opens with much less memory.
2. Take live-only dumps (jcmd default). Avoid `jcmd -all` and MAT's `-keep_unreachable_objects`, which add objects.
3. Last resort: `-discard_ratio=<percent> -discard_pattern=<regex>`. Experimental. Skips indexing matching objects, so leak suspects and the dominator tree become incomplete.

## Usage

### Capture a heap dump (optional)

Run as the same OS user as the target JVM. The JVM itself writes the file, so the path is on its filesystem and needs roughly heap-size free space. Dumping pauses the application (seconds to minutes).

```sh
jcmd -l                                   # find the PID
jcmd <pid> GC.heap_dump /tmp/heapdump.hprof
```

Or with jmap:

```sh
jmap -dump:live,format=b,file=/tmp/heapdump.hprof <pid>
```

Both run a full GC first, so only live objects are dumped. Add `-all` to jcmd to keep unreachable objects. Don't use `-gz`, since the script expects a plain `.hprof`.

From a Kubernetes pod (the image needs a JDK for jcmd and tar for `kubectl cp`; the JVM is usually PID 1):

```sh
kubectl exec <pod> -- jcmd 1 GC.heap_dump /tmp/heapdump.hprof
kubectl cp <pod>:/tmp/heapdump.hprof ./heapdumps/heapdump.hprof
kubectl exec <pod> -- rm /tmp/heapdump.hprof
```

To capture automatically on OutOfMemoryError, start the JVM with:

```
-XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/path/to/dumps/
```

### Run the analysis

Place the dump in `~/java-heap-analyzer/heapdumps/`, then run:

```sh
./analyze-heap.sh ./heapdumps/heapdump.hprof
```

Or provide an absolute path:

```sh
./analyze-heap.sh /tmp/heapdump.hprof
```

Reports land in `~/java-heap-analyzer/reports/<dump>/` and the log in `~/java-heap-analyzer/logs/<dump>.log`.

## Reading the reports

A leak suspect is not necessarily a confirmed memory leak. Further investigation of object references and GC roots may be needed. Start with each suspect's "Shortest Paths To the Accumulation Point" and "Accumulated Objects in Dominator Tree" sections. They also give the object addresses (`@ 0x...`) and class names used below.

### Investigating from the command line

Any MAT query runs headless through `org.eclipse.mat.api:query`, the same way the script builds the histogram. The index files from the first run are reused, so these skip the parse.

```sh
MAT=~/java-heap-analyzer/mat/ParseHeapDump.sh
DUMP=~/java-heap-analyzer/heapdumps/heapdump.hprof
```

Why instances of a class are alive (merged paths to GC roots, weak and soft references excluded):

```sh
Q="merge_shortest_paths com.example.CacheEntry"
Q="$Q -excludes java.lang.ref.WeakReference:referent"
Q="$Q java.lang.ref.SoftReference:referent"
"$MAT" "$DUMP" -format=txt -command="$Q" org.eclipse.mat.api:query
```

Path to GC roots for one object:

```sh
"$MAT" "$DUMP" -format=txt -command="path2gc 0x7f3a2b10" \
  org.eclipse.mat.api:query
```

Incoming references to one object:

```sh
"$MAT" "$DUMP" -format=txt \
  -command="list_objects 0x7f3a2b10 -inbound" \
  org.eclipse.mat.api:query
```

What keeps instances alive, one level up:

```sh
"$MAT" "$DUMP" -format=txt \
  -command="immediate_dominators com.example.CacheEntry" \
  org.eclipse.mat.api:query
```

All GC roots, or the full dominator tree:

```
-command="gc_roots"
-command="dominator_tree"
```

Each run writes `<dump>_Query.zip` next to the dump and overwrites the previous one, so rename or unzip it between queries. Use `-format=csv` to grep or sort the output. Flag names (`-excludes`, `-inbound`) are not verified against every MAT release; check the log if a query fails.

## Troubleshooting

- **Out of memory:** increase `-Xmx` in `MemoryAnalyzer.ini`. See [MAT memory configuration](#mat-memory-configuration).
- **Insufficient disk space:** MAT creates additional index files alongside the heap dump. Ensure adequate free disk space before starting.
- **Slow analysis:** large dumps can take considerable time to parse and analyze.
- **Java version issues:** verify that MAT is running with Java 21 or newer.
- **Reports not generated:** check `logs/` for errors. Verify the MAT installation and heap dump integrity.

## Security

Heap dumps may contain passwords, tokens, customer data and other sensitive information. Restrict file permissions and access. The script runs with `umask 077` because reports, indexes and logs hold the same sensitive data as the dump.

Run large heap dump analysis on a dedicated machine rather than on the production application server.
