# Core 07 self-check

Answer these without running the code. Use the lesson tests to check your reasoning afterward.

| Lesson | Explain it |
|---|---|
| 01 · Failure and time | A monitor hears nothing for five ticks. Give two indistinguishable histories and describe how you would reproduce one from a seed. How does eventual synchrony change the progress argument? |
| 02 · Election | Explain majority intersection for three and five peers. Who remembers the vote and what should happen when a lower-term message arrives? |
| 03 · Replication | A returning follower matches through index 4, but index 5 differs. Which bytes are logically replaced? What can an empty Append with a matching index 4 tell the follower? |
| 04 · Commit | The leader counts an older-term entry on a majority. What additional event can commit its prefix? Why does a receiving follower cap the commit index at the last index verified by that Append? |
| 05 · Persistence | Trace a vote through a crash before save, after save but before send, and after send. Which promise can an outside peer already rely on? |
| 06 · Rust WAL | How does replay distinguish a short payload from a checksum failure in a complete frame? How is a Go suffix replacement applied without rewriting earlier bytes? |
| 07 · Runtime | When may a peer reply 204 to transport? When may the API return 200 to a client write? Why does a client read through the log? |
| 08 · Gate | What would the experiment miss if you killed the writer in every isolation test? Which observations tell you that the saved prefix was preserved? |
| 09 · Fencing | When can the old worker still write? How do a new grant, a renewal, and a restart affect token order? |
| 10 · Placement | When a virtual point is inserted, which keys can move? What does a histogram of keys per member leave out about load? |

## Trace from memory

A leads in term 1. The only entry, at index 1, is committed and present on all three peers. A starts an append for a client after its peer links fail in both directions. Its writer puts only the header into the file and dies. B and C elect B in term 2. B appends a no-op and then a client value. A restarts with its original log and the links heal.

1. Draw each durable and in-memory log after A's crash, after B's client receives success, and after A catches up.
2. Label what A can report while it is still alone. State which event makes B's client value safe to apply.
3. Change the schedule so A fully synchronizes its local write before crashing. Predict the repaired file and the later logical suffix replacement.
4. Describe the disk check and the client check that distinguish your two schedules.

<details>
<summary>Check your trace</summary>

A initially preserves index 1 and repairs its incomplete tail. While alone, it cannot give a quorum-confirmed answer. B can commit the no-op and new value after durable acknowledgment from C. A learns B's prefix after the links heal, stores it, and applies the missing entries.

With a complete synchronized frame, Rust keeps the old record when A restarts. The Raft leader can later replace that uncommitted suffix by appending a new logical replacement record. The torn run reports trimmed bytes. The complete-local run leaves those bytes valid but still must report no client success while isolated. After heal, client reads agree on the committed application state.

</details>
