# Production ownership

Use this tabletop after Core 08. Practice carrying an incident from the first user-impact signal through recovery and a verifiable follow-up. Use the [Core 08 game day](../2-core/08-shipping-safely/lessons/07-run-a-game-day-and-defend-the-decision.md) and the [edge proxy reload capture](../3-tracks/cloud-and-network/04-capstone-programmable-edge-proxy/evidence/reference/managed/Reload-1.json). Run the exercise against the recorded local fixtures.

## Work the incident

1. **Declare and scope.** In the Core 08 fixture, a deployment changes the gateway's upstream socket. The listener still accepts TLS but eligible requests fail. Write an update with the affected client operation, first bad observation, and current owner. Use the client success ratio across the complete observation window. Include refused and timed-out attempts in the denominator.
2. **Triage.** Check the client symptom, gateway status, and upstream reachability. Compare a completed TLS handshake followed by HTTP 503 with an authentication failure. Confirm which configuration changed and whether the previously working upstream is available.
3. **Mitigate and verify.** State when you would restore the known-good configuration and who authorizes it. Keep observing the same client operation through the change. Require the ratio to return to at least three good observations out of four and check that a recovered read returns the expected value. [Core 08 runbook](../2-core/08-shipping-safely/runbook.md)
4. **Hand off.** Record current impact, mitigation, next check, evidence, and the next owner. Give the receiving operator a condition for reopening the incident. Distinguish a rejected deployment from a continuing outage by checking the live data path and active configuration.
5. **Review.** Record the trigger, timeline, impact, why the signals behaved as they did, and actions with owners and verification criteria. [Reference postmortem](../2-core/08-shipping-safely/evidence/postmortem.md)

## Check your decisions

- In Core 08, compare the reference probe with the deliberate control that omitted failures. The control failed to alert. An action for the telemetry owner is to preserve failed attempts in the denominator and prove it by rerunning the gate with an unavailable upstream. [Game-day transcript](../2-core/08-shipping-safely/evidence/07-game-day.txt)
- In the edge proxy capture, generation three was rejected, generation two stayed active, and all 240 timed requests succeeded. The supported operator decision is to pause the candidate rollout and investigate the failed health check while the healthy route serves. Record the distinct signal that would prompt restoring a previous route, such as failed client requests after a successful publication. [Reload evidence](../3-tracks/cloud-and-network/04-capstone-programmable-edge-proxy/evidence/README.md)

Finish with five artifacts: a one-paragraph incident update, an evidence-linked timeline, a mitigation and rollback decision, a handoff note, and a postmortem with an owner and an observable completion check for each action.

<details>
<summary>Compare with a worked tabletop</summary>

**Incident update.** The lab's authorized metadata read began failing after an upstream configuration change at 02:33:41.698 UTC. At 02:33:42.829, the external probe alerted with two good observations in the latest four. The incident lead owns the response and the gateway operator is checking the previous upstream.

**Timeline and decision.** A verified client received HTTP 503 at 02:33:42.837 and the configured socket was absent. Once the gateway operator verified the last good socket, the incident lead authorized rollback. The previous path was restored at 02:33:42.855. At 02:33:44.274 the alert cleared and the seeded value was readable again. [Reference timeline](../2-core/08-shipping-safely/evidence/postmortem.md)

**Handoff.** The next operator should watch the same authorized read and probe window, keep the restored configuration active, and reopen if success falls below three of four or the returned value changes. Save the failed candidate and probe output so the rollout owner can reproduce the failure.

**Follow-up.** The gateway owner adds an authenticated read check before activation and verifies that an unavailable upstream leaves the old configuration serving. The telemetry owner reruns the failed-attempt control and proves that an incomplete denominator makes the alert test fail. Each action closes when the corresponding gate result is attached to the review.

</details>
