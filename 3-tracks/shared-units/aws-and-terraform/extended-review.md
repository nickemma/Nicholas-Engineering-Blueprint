# AWS and Terraform · Extended review

More questions on this module, beyond the [self-check](self-check.md). Answer from memory, then check yourself against the lessons. Write each "predict" answer before running anything.

## Questions

### The whole module

1. What does `terraform plan` compare? What is the state file for?
2. Public and private subnets: which resources go in which here, and why?
3. Execution role vs task role.
4. Map each AWS service to the part of the local stack it replaces, and name one thing you had to rebuild.
5. Why does SQS not need the attempt header? How does the adapter delay a retry?
6. Roughly what does this configuration cost a day, and what protects you from forgetting it?

## Evidence worksheet

Fill this in as you go, with evidence: commands and their output, test names, captures. Keep your filled-in copy in your own repository.

### Explain it

| Lesson | Question | My answer | Evidence |
|---|---|---|---|
| — | What does `terraform plan` compare, and with what? | | |
| — | Execution role vs task role: what does each allow? | | |
| — | Which part of the local stack does each AWS resource replace, and what did you have to rebuild? | | |

### Evidence checklist

| Claim | Command, test or capture | Result |
|---|---|---|
| An offline Terraform plan | | |

### Rebuild from memory

- What I rebuilt without help:
- What I had to look up:
- How my design differs from the lessons, and why:
- What is still unclear:
