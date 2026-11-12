# analyze-heap

Runs Eclipse MAT in batch mode against a Java heap dump (.hprof) to produce Leak Suspects, System Overview, Top Components and class histogram reports. It collects the report zips from beside the dump into `reports/<dump>/`, extracts them, and fails if any of the three main reports is missing.
