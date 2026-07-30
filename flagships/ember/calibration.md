# <FLAGSHIP> — calibration

Every prediction this build makes, scored. Rows are added at kickoff from charter points
4, 10 and 11 with **Actual** blank, and from session prediction gates as they occur.

Fill both columns in one sitting — never leave a half-finished row.

| # | Prediction | Source | Predicted | Actual | Delta | Why I was off |
|---|---|---|---|---|---|---|
| 1 | 2nd client while 1st open | charter 4 |"refused" | hangs in backlog | wrong mechanism | Confused listen() backlog with accept(). Kernel completes the handshake and queues it — my code just never calls accept() again. |

**Source** is `charter N` for a charter claim or `session N gate` for an in-session
prediction. Charter rows are scored at level exit; session rows the same day.
