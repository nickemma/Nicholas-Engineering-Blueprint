# Rust Bridge learning record

Complete after [TEACHING.md](TEACHING.md). Use your own words and attach tests or compiler output.

1. What is the difference between a Rust source file, a Cargo package, and a running process?
2. Show the record layout and explain why writer and reader must agree on field width and byte order.
3. What does the length limit protect? Why must it be checked before allocating memory?
4. What was the borrow-checker error you produced? Draw who owned the bytes and who borrowed them. Why would the invalid reference outlive its owner?
5. What error does Result represent, and how does your program report it?
6. What does CRC32C detect? What security guarantee does it not provide?
7. What does Arc provide in the counter? What does Mutex provide?
8. What is the connection between a Vec, process virtual memory, and file bytes?

| Claim | Evidence | Result |
|---|---|---|
| A record encodes and decodes correctly | test name and result | |
| Truncation and corruption are rejected | test names and result | |
| Oversized records fail before allocation | test name or code path | |
| Rust prevents the unsafe borrow | compiler error and explanation | |
| Shared counter uses safe synchronization | source and repeated test | |

## Kestrel transfer

Close this guide and the sample code. In Kestrel, define a record format from a written byte-level contract and implement the encoder/decoder from scratch. You may use Rust documentation.

- Which layout did I choose, and how will I evolve it?
- How does the reader reject malformed bytes?
- Which values are owned, and which are borrowed?
- What did I change after seeing the compiler error?
- What differs from this exercise and why?
- What do I understand now that I could not explain before?
- What remains unclear?
