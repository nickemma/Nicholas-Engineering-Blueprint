# Reference postmortem · Gateway pointed at a missing socket

The gateway was restarted with a configuration naming an unavailable Unix socket. The peer cluster and its data remained available. The authorized client's metadata read failed until the operator restored the saved upstream.

## Timeline

| UTC | Observation |
|---|---|
| 02:33:41.695 | Four good external observations established the baseline. |
| 02:33:41.698 | The lab deployed the configuration with the unavailable socket. |
| 02:33:42.829 | The gate recorded the alert, with two good observations in the latest four. |
| 02:33:42.837 | A verified client received HTTP 503 and the configured socket was absent. |
| 02:33:42.855 | The operator restored the previous path. |
| 02:33:44.274 | The alert cleared and an authorized read returned the seeded value. |

## Causes and follow-up

The change accepted a syntactically valid path whose target was absent. The restart made that configuration active. Restart also briefly interrupted the listener, so the external probe could register transport failures as well as 503 responses.

The independent probe and the retained known-good configuration made the fault visible and reversible. Add an authenticated readiness check to a future rollout before it replaces the current path. Check leader changes in a separate drill because this run held the peer configuration fixed. [Raw game-day capture](07-game-day.txt)
