# Phase 8 learning record

Use your final report, reproduced run, scan output, and failure demo to answer.

1. List your strongest three claims and the evidence for each.
2. Which claim did you narrow after testing? What was too broad about its first wording?
3. What does the threat model assume? Which attacker or failure remains outside it?
4. Which identity, authorization, storage, and operational controls did you verify?
5. What did govulncheck and the image scanner find? How did you judge reachability and fix status?
6. What does your SBOM contain? How would a reader verify the signed artifact, if you signed one?
7. Which failure or bypass did you demonstrate? What data remained protected?
8. Could a second person reproduce the main result from a clean checkout? What differed on reproduction?
9. What negative result belongs in the report?
10. What new evidence would most change your design?

| Gate | Evidence | Result |
|---|---|---|
| Clean build | commands, versions, commit | |
| Main experiment reproduced | manifest, output comparison | |
| Security review | threat model and tested controls | |
| Failure demo | runbook and observed recovery | |
| Public report is accurate | claim/evidence table and limitations | |

## Final Kestrel transfer

- What did I explain from evidence rather than from memory?
- Which system boundary was most important to understand?
- Where does the system fail safely, and where does it stop making progress?
- What should a reviewer not conclude from this project?
- Which career direction gained evidence, and which still needs real-world practice?
- What remains unresolved and why?
