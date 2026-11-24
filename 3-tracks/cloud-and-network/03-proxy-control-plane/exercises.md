# Proxy control-plane exercises

## 1. Recover after restarting the proxy

Build a controller that stores its desired snapshot durably before publication. Stop the proxy after it applies a generation and start it against the same two origins.

- Show that status initially returns generation zero after restart.
- Reconcile the same desired snapshot and verify the expected route with an origin response.
- Interrupt the controller after the snapshot reaches the proxy but before the controller records the acknowledgement. On retry, require the original generation and digest to be acknowledged.

## 2. Measure how long a health sample stays useful

Build two local origins and a controller that records probe time and duration against each candidate. Hold a healthy probe, then time an origin shutdown between the health response and the route update.

- Record the time from health success to application. Show a run in which publication succeeds and the first application request still fails.
- Compare changing the configured freshness threshold with adding an immediate follow-up probe. Save both timelines and explain the interval each leaves between probe and use.
- State what observation should prompt rollback and verify the route afterward.

## 3. Rotate signing credentials with a bounded overlap

Build a receiver whose key registry accepts the current and immediately previous version for a short overlap, then retires the previous version.

- Deliver one event immediately before rotation and retry it during overlap. Require one stored receipt.
- Verify delivery with the current version throughout. After overlap, refuse a fresh event signed with the retired version.
- Use a controlled clock and inspect the receipt count after each run.
