# Rust Bridge: what I learned

Fill this in as you go, with evidence: compiler output, test names, hex dumps, experiment transcripts.

## Explain it

| Step | Question | My answer | Evidence |
|---|---|---|---|
| 1 | Why is immutability the default? What does returning `Option` force the caller to do? | | |
| 2 | State the three ownership rules. Explain move, `&` and `&mut` with an example of each | | |
| 2 | Why does "many readers or one writer" rule out data races? | | |
| 2 | Why does `join` take `Vec<String>` but `longest_word` take `&str`? | | |
| 3 | What does `?` do, exactly? Why use `checked_mul`? | | |
| 3 | `Debug` vs `Display`: who is each for? | | |
| 4 | Why a length prefix? Why say little-endian explicitly? | | |
| 4 | What can a CRC detect, and what can't it? Why did only the known-answer test catch the wrong polynomial? | | |
| 5 | When is a write durable? What does `fsync` cost? | | |
| 5 | Why can only the last record be torn? What can klog's recovery *not* tell apart? | | |
| 5 | Why refuse to open after mid-file corruption? | | |
| 6 | Define `Send` and `Sync`. Why does `Mutex<T>` contain its data? | | |
| 6 | Explain the deadlock from Step 6's break-it | | |

## Evidence checklist

| Claim | Evidence | Result |
|---|---|---|
| The five compiler errors produced and understood | | |
| The CRC-32C known answer matches | | |
| A hex dump decoded by hand | | |
| A torn write recovered | | |
| Mid-file corruption refused | | |
| 100 records from 4 threads, all intact | | |

## Rebuild from memory

- What I rebuilt without help:
- What I had to look up:
- What is still unclear:
