# Compaction checkpoint — details

> Loaded on demand — not part of the SessionStart payload.

Auto-compaction fires on the harness's clock, not on a task boundary. Left alone it lands
mid-edit and takes with it every piece of working state that lived only in reasoning.

In a repository with a `.claude/.compact-gate/` directory the gate inverts that: automatic
compaction is **blocked** until this session has written a checkpoint, and the `SessionStart`
hook names the file to write — one per session, so sessions sharing a working directory do not
race. Write it when the work is durable — spec on disk, edits saved, sub-agent results
integrated, nothing that matters living only in your reasoning — never mid-edit. Then make one
more small tool call: `PreCompact` only runs on the next compaction attempt, so a session that
checkpoints and goes quiet is never compacted at all. Rewrite it every time; the gate compares
its mtime against the last compaction it let through.
