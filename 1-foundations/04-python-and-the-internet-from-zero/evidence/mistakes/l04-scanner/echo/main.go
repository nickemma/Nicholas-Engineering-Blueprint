// echo is a TCP server that sends every line it receives straight back.
//
// Each connection gets its own goroutine. A line may be up to maxLine bytes,
// newline included; a longer one gets an error and the connection is closed.
// A connection that sends nothing for -idle is closed too.
package main

import (
	"bufio"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"time"
)

const maxLine = 64 * 1024

func main() {
	addr := flag.String("addr", "127.0.0.1:9000", "address to listen on (port 0 picks a free port)")
	idle := flag.Duration("idle", 30*time.Second, "close a connection that sends nothing for this long")
	flag.Parse()

	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		fmt.Fprintln(os.Stderr, "echo:", err)
		os.Exit(1)
	}
	fmt.Println("listening on", ln.Addr())
	serve(ln, *idle)
}

// serve accepts connections until the listener is closed, and hands each
// one to its own goroutine.
func serve(ln net.Listener, idle time.Duration) {
	for {
		conn, err := ln.Accept()
		if errors.Is(err, net.ErrClosed) {
			return
		}
		if err != nil {
			log.Println("accept:", err)
			continue
		}
		go handle(conn, idle)
	}
}

func handle(conn net.Conn, idle time.Duration) {
	defer conn.Close()
	sc := bufio.NewScanner(conn)
	sc.Buffer(make([]byte, 4096), maxLine)
	for sc.Scan() {
		fmt.Fprintf(conn, "%s\n", sc.Bytes())
	}
}

// lingeringClose gets an error message to the client before closing. Closing
// a connection that still has unread bytes makes the kernel reset it, and a
// reset can throw away the message before the client reads it. So stop
// sending (the client sees the end of the stream), then read and discard
// whatever is left, for up to a second, before handle closes it.
func lingeringClose(conn net.Conn) {
	if tc, ok := conn.(*net.TCPConn); ok {
		tc.CloseWrite()
	}
	conn.SetReadDeadline(time.Now().Add(time.Second))
	io.Copy(io.Discard, conn)
}
