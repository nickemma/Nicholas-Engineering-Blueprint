# Build and test the first short-link design

Use Python 3 and SQLite to run three decisions from [Your first system design](first-design.md). This lab runs a local model of the request path. The redirect call returns the destination URL as a string so you can observe database access without running an HTTP server.

## 1. Predict the paths

A create records the short code and the request key in one transaction. A redirect looks up the code. A cache can serve subsequent public, immutable redirects.

Before running, predict the origin reads for 100 requests to the same code. Predict what changes if another code evicts it. Decide what the second create should return if the server committed the first create but its response never reached the client.

Create `short_links.py`.

<!-- file: short_links.py -->
~~~~python
import sqlite3
from collections import OrderedDict


class Origin:
    def __init__(self):
        self.database = sqlite3.connect(":memory:")
        self.database.executescript("""
            CREATE TABLE links (code TEXT NOT NULL, url TEXT NOT NULL);
            CREATE TABLE requests (key TEXT PRIMARY KEY, url TEXT NOT NULL, code TEXT NOT NULL);
        """)
        self.reads = 0

    def lookup(self, code):
        self.reads += 1
        row = self.database.execute("SELECT url FROM links WHERE code = ?", (code,)).fetchone()
        return row[0] if row else None

    def plan(self):
        return self.database.execute(
            "EXPLAIN QUERY PLAN SELECT url FROM links WHERE code = ?", ("demo",)
        ).fetchone()[-1]

    def create(self, key, code, url):
        with self.database:
            prior = self.database.execute(
                "SELECT url, code FROM requests WHERE key = ?", (key,)
            ).fetchone()
            if prior is not None:
                if url != prior[0]:
                    raise ValueError("idempotency key reused for a different URL")
                return prior[1]
            self.database.execute("INSERT INTO links VALUES (?, ?)", (code, url))
            self.database.execute("INSERT INTO requests VALUES (?, ?, ?)", (key, url, code))
        return code


class Edge:
    def __init__(self, origin, limit):
        self.origin = origin
        self.limit = limit
        self.cache = OrderedDict()

    def redirect(self, code):
        if code in self.cache:
            self.cache.move_to_end(code)
            return self.cache[code]
        url = self.origin.lookup(code)
        if url is not None:
            self.cache[code] = url
            if len(self.cache) > self.limit:
                self.cache.popitem(last=False)
        return url


def main():
    origin = Origin()
    before = origin.plan()
    assert "SCAN links" in before, before
    origin.database.execute("CREATE UNIQUE INDEX links_code ON links(code)")
    after = origin.plan()
    assert "SEARCH links USING INDEX links_code" in after, after
    print(f"query before: {before}\nquery after:  {after}")

    url = "https://example.test/manual"
    origin.create("request-1", "demo", url)
    # The first write committed. Pretend its response was lost.
    assert origin.create("request-1", "second-attempt", url) == "demo"
    count = origin.database.execute("SELECT count(*) FROM links").fetchone()[0]
    assert count == 1, count
    try:
        origin.create("request-1", "second-attempt", "https://example.test/other")
    except ValueError:
        pass
    else:
        raise AssertionError("conflicting replay was accepted")

    try:
        origin.create("request-2", "demo", "https://example.test/other")
    except sqlite3.IntegrityError:
        pass
    else:
        raise AssertionError("duplicate short code was accepted")
    assert origin.create("request-2", "different", "https://example.test/other") == "different"
    print("lost response: retry returns the prior code; collisions reject atomically")

    edge = Edge(origin, limit=1)
    assert all(edge.redirect("demo") == url for _ in range(100))
    assert origin.reads == 1, origin.reads
    print("100 repeat redirects: 1 origin read")
    edge.redirect("different")
    assert edge.redirect("demo") == url
    assert origin.reads == 3
    print("eviction: switching back to demo reaches the origin again")


if __name__ == "__main__":
    main()
~~~~

## 2. Run and read the evidence

The unique index supports both the key lookup and the collision rule. A retry with the original request key reads the completed response, even if it proposes a different code. Reusing the key for a different URL fails. The cache tracks a fixed number of entries and counts what would reach the origin.

<!-- run: python3 short_links.py -->
~~~~bash
python3 short_links.py
~~~~

~~~~text
query before: SCAN links
query after:  SEARCH links USING INDEX links_code (code=?)
lost response: retry returns the prior code; collisions reject atomically
100 repeat redirects: 1 origin read
eviction: switching back to demo reaches the origin again
~~~~

## 3. Break the build and extend the design

Disable the cache hit path and run the same check. The repeat-read assertion should see 100 database reads. Next, remove the unique constraint while retaining the lookup index and follow the duplicate-code assertion. Restore both changes.

Give the design a new requirement that forces one decision at a time.

| New requirement | Follow the request and explain the choice |
|---|---|
| Ten times the traffic, with one server allowed to fail | Estimate the cache hit rate, size healthy replicas and draw where the load balancer and gateway sit. Explain what rate limit stops one tenant exhausting the budget. |
| Redirect clients far from the origin | Decide how a CDN caches immutable redirects, what changes when editing is allowed, and which signals distinguish an edge hit from an origin hit. |
| Multiple data locations | Compare a relational schema with a key-value access path. Choose a replication policy, then decide if sharding or consistent hashing would help. Walk a create and redirect across a partition and describe the consistency promise. |
| Analytics and audit each need redirect events | Give each subscriber independent progress. Name the broker's delivery guarantee, the idempotency key, retry budget, backlog bound, and when a circuit breaker fires. Explain whether analytics warrants its own service. |

Continue with the [20 building blocks](../fundamentals/README.md#20-system-design-building-blocks), the [full design](url-shortener.md), and the [event-streams build](../../3-tracks/shared-units/event-streams/README.md) to test the broker and consumer side.
