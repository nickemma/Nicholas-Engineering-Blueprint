# Rust inference gateway · Self-check

1. Why can a read end inside a UTF-8 character, a CRLF pair, or an SSE event? Which state must survive that read?
2. When do multiple data lines become a dispatchable event? How are incomplete events handled at EOF?
3. What is reserved before generation and when is that reservation charged? Which timestamp drives refill?
4. What failures cause 422, 429, and 503? Which one reflects a full set of active slots?
5. Which object holds the slot after the handler returns? What stops the upstream body on downstream disconnect?
6. Why do the upstream idle timer and connection lifetime guard different waits?
7. What distinguishes first content from first transport data? Which conditions allow the gateway to send the success marker?
8. What additional measurement would show that a real model host reclaimed generation capacity after cancellation?

## From memory

Draw the client, gateway, and model server. Mark where the permit and token reservation begin and end. Predict the status and final SSE event for saturation, quota exhaustion, disconnect, and successful completion, then compare with the gate.
