"""The first Python program: print, variables, a list and a loop."""

name = "Kestrel"
latencies_ms = [12, 15, 11, 250, 14]

print(f"Hello, {name}!")
print(f"{len(latencies_ms)} requests")
for latency in latencies_ms:
    if latency > 100:
        print(f"slow: {latency} ms")
