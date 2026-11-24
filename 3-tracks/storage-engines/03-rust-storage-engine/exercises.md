# A Rust storage engine · Exercises

Use a separate learner workspace or branch. Predict the results and counters before running each workload.

## Split the merge into selected runs

Compact a subset of tables with overlapping keys. Include a newer tombstone in the inputs and an older value for the same key in an unselected run.

- Add the schedule to your test harness. Show that the newest-only merge would make the old value visible.
- Keep the tombstone while an older value can remain outside the compaction inputs. Show that current and pinned reads still agree with the reference model.
- Compare total bytes rewritten with a full merge on the same run inventory.

## Measure how key placement changes read cost

Build two tables with the same number of unique keys. Put absent probe keys between existing keys in one fixture and outside the indexed ranges in the other.

- Run each fixture with and without the Bloom filter. Verify that the results are identical.
- Record the number of queries, filter positives for absent keys, and data-block probes. Explain why a positive filter decision can still end in an index miss.
- Change the number of versions per key while keeping the distinct keys fixed. Compare filter size and compaction output.

## Reopen after retiring every version

Create a live value and delete it. Flush, compact until no SSTables remain, then interrupt the process once before and once after manifest publication.

- Predict the generation, active WAL, and watermark before inspecting either directory.
- Verify that the deleted key stays absent and that reinserting it uses the next sequence.
- Capture both inventories and keep the old and new manifests beside a timeline in your write-up.

Use the [gate](gate/README.md) and the [reference evidence](evidence/README.md) as a baseline for comparison.
