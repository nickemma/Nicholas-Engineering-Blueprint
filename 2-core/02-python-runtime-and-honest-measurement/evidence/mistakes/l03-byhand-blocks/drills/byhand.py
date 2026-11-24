"""Lesson 03: an event loop by hand, from generators and selectors.

One thread runs an echo server and three clients at once. Each task is a
generator that yields what it is waiting for; the loop resumes it when that
has happened.
"""

import heapq
import selectors
import socket
import time
from collections import deque

START = time.monotonic()


def log(message: str) -> None:
    print(f"{time.monotonic() - START:5.2f} s  {message}")


class Loop:
    def __init__(self) -> None:
        self.ready: deque = deque()  # tasks that can run now
        self.timers: list = []  # (when, number, task), soonest first
        self.selector = selectors.DefaultSelector()
        self.number = 0

    def spawn(self, task) -> None:
        self.ready.append(task)

    def run(self) -> None:
        while self.ready or self.timers or self.selector.get_map():
            if not self.ready:
                self.wait()
                continue
            task = self.ready.popleft()
            try:
                what, arg = next(task)  # run the task until it yields
            except StopIteration:
                continue  # the task has finished
            if what == "sleep":
                self.number += 1
                heapq.heappush(self.timers, (time.monotonic() + arg, self.number, task))
            elif what == "read":
                self.selector.register(arg, selectors.EVENT_READ, task)
            elif what == "write":
                self.selector.register(arg, selectors.EVENT_WRITE, task)

    def wait(self) -> None:
        """Nothing can run: sleep in the kernel until a socket is ready or a timer is due."""
        timeout = None
        if self.timers:
            timeout = max(0.0, self.timers[0][0] - time.monotonic())
        for key, _ in self.selector.select(timeout):
            self.selector.unregister(key.fileobj)
            self.ready.append(key.data)
        while self.timers and self.timers[0][0] <= time.monotonic():
            self.ready.append(heapq.heappop(self.timers)[2])


def server(loop: Loop, listener: socket.socket, connections: int):
    for _ in range(connections):
        yield "read", listener  # wait for a connection
        conn, _ = listener.accept()
        conn.setblocking(False)
        loop.spawn(echo(conn))
    listener.close()


def echo(conn: socket.socket):
    while True:
        yield "read", conn
        data = conn.recv(65536)
        if not data:
            conn.close()
            return
        yield "write", conn
        conn.send(data)  # small replies: one send is enough here


def client(name: str, port: int, lines: int, pause: float):
    sock = socket.socket()
    sock.setblocking(False)
    sock.connect_ex(("127.0.0.1", port))  # returns at once; the connection completes later
    yield "write", sock  # writable means connected
    for i in range(lines):
        sock.send(f"{name} {i}\n".encode())
        reply = b""
        while not reply.endswith(b"\n"):
            yield "read", sock
            reply += sock.recv(65536)
        log(f"{name} got back {reply!r}")
        time.sleep(pause)
    sock.close()


if __name__ == "__main__":
    listener = socket.create_server(("127.0.0.1", 0))
    listener.setblocking(False)
    port = listener.getsockname()[1]
    loop = Loop()
    loop.spawn(server(loop, listener, connections=3))
    for name in ("a", "b", "c"):
        loop.spawn(client(name, port, lines=3, pause=0.1))
    loop.run()
    log("all tasks finished, in one thread")
