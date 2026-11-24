# A Rust storage engine · Evidence

The reference used Rust 1.94.1 on Linux. The CLI ran against separate temporary engine directories for each interrupted operation.

| Fixture | Observed result |
|---|---|
| WAL repair | Recovered through sequence 3 after trimming a three-byte tail. Refused a complete corrupt frame and preserved its bytes. |
| Indexed lookup | Reopened two blocks plus an active WAL at sequence 34. The WAL deletion hid key 15. |
| Bloom filter | On 512 absent keys, logical block probes fell from 960 to 10, with 11 false-positive table checks. All present-key and absent-key results agreed with the bypass. |
| MVCC | Kept 7, 3, then 2 versions as pins were released. The first compaction wrote 242 output bytes from 437 input bytes. The last wrote 139 from 162. |
| Interrupted flush | Every schedule recovered sequence 5. The covered sequence was 2 before publication and 5 after publication. |
| Interrupted compaction | Every schedule recovered sequence 6 from tables plus the active WAL. The covered sequence remained 5. |
| In-flight writes | The write stopped before WAL append stayed absent. The write stopped after WAL sync survived. Neither was acknowledged. |
| Model and control | All 480 mutations across four seeds matched the ordered reference model. The newest-only compaction variant changed a pinned result and failed the expected assertion. |

The probe counts measure requested data frames. The compaction counts measure on-disk SSTable bytes. The interruptions exercise process termination on the local filesystem.

- [Gate transcript](gate.txt)
- [Clean lesson replay](replay.txt)
