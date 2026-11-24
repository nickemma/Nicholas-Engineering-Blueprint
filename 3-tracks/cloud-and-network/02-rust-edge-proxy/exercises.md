# Rust edge proxy exercises

## 1. Choose a pool budget for a small origin

Build a loopback experiment with one HTTP/1.1 origin and three loads. Run serial requests, a burst of 16 parallel requests, then another serial train after an idle gap. Count both accepted sockets and requests at the origin.

- Compare disabled reuse, an idle limit of one, and an idle limit of eight with the same requests and responses.
- Run the idle gap once inside and once beyond a short configured pool TTL. Repeat each condition and save the raw counts.
- Verify full response bytes and explain which part of the burst a larger idle pool can help. Use the measured connection count to justify a budget.

## 2. Route with an explicit precedence rule

Build a router and two local origins. Route `/assets/private` and its descendants to one origin, and the rest of `/assets` to the other. Keep the full path and query on the selected hop.

- Show that `/assets/private`, `/assets/private/a?x=1&x=2`, and `/assets/privateer` have the intended outcomes and that an unrelated path returns 404.
- Run the route tests with the input route table in both orders. The selected origin must be the same.
- Use each origin's count to prove that an unmatched request produces no upstream work.

## 3. Find the limit of your load generator

Use the reference object and record direct and proxied performance across at least five offered rates. Keep worker count, payload, connection settings, and duration fixed.

- For each run, account for every arrival as a success, HTTP failure, timeout, I/O error, mismatch, or driver-cap drop.
- Repeat two rates around your first sustained increase in tail latency or failures. Compare launch lag with service time from actual dispatch.
- Write a short report that explains which rates support a proxy comparison and which expose a limit in the load generator or the shared setup. Include the direct baseline and the configuration.
