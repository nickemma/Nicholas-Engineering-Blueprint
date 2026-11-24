# A Rust storage engine · Self-check

Draw the state transitions and write down your answers before running the tests.

1. How does an empty value differ from a tombstone in memory, in a WAL frame, and in the CLI output?
2. A write is synced to the WAL and the process stops before replying. What happens on reopen? What can the caller infer from its missing acknowledgment?
3. A complete frame fails its checksum. How does recovery handle it? How does that differ from a final frame cut short during append?
4. List the files and syncs involved in flushing a memtable. Which generation does open choose if the process stops just before manifest publication? What changes if it stops just after?
5. One key has enough versions to span two blocks. Where does the index seek, and when can the reader stop looking?
6. Why do SSTable filters include tombstone keys? Why can a false-positive table check incur zero data-block probes?
7. Write the rows returned by a scan at sequences before and after a delete, followed by a reinsert. Include the exclusive upper bound.
8. What versions must a full merge keep for the oldest pin? What keeps a tombstone necessary when compaction only merges some runs?
9. A full merge produces zero live runs. Where does reopen find the next sequence? How does it know which WAL to read?
10. What do the block-probe and compaction-byte counters measure? Which elapsed-time or device-I/O claims would require a different experiment?

Check your answers against the [lessons](README.md) and the [recorded gate results](evidence/README.md).
