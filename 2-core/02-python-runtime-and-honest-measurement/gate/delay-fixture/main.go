// Command target is the core 02 gate's server. Every request takes a known
// time (-delay), and the server logs when each one really arrived, so the
// gate can check a load generator's numbers against the truth.
//
// Log lines: arrival and finish times in nanoseconds since the Unix epoch,
// the method, and the request number taken from an Idempotency-Key ending
// in "-N" (or -1 when there's none).
package main

import (
	"bufio"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

type arrival struct {
	start, end int64
	method     string
	number     int
}

func main() {
	addr := flag.String("addr", "127.0.0.1:0", "address to listen on")
	delay := flag.Duration("delay", 5*time.Millisecond, "how long every request takes")
	logPath := flag.String("log", "arrivals.log", "where to write one line per request")
	flag.Parse()

	var mu sync.Mutex
	var seen []arrival
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		time.Sleep(*delay)
		number := -1
		if key := r.Header.Get("Idempotency-Key"); key != "" {
			if n, err := strconv.Atoi(key[strings.LastIndex(key, "-")+1:]); err == nil {
				number = n
			}
		}
		w.Header().Set("Content-Type", "application/json")
		if r.Method == http.MethodPost {
			w.WriteHeader(http.StatusCreated)
		}
		fmt.Fprintln(w, `{"status":"ok"}`)
		end := time.Now()
		mu.Lock()
		seen = append(seen, arrival{start.UnixNano(), end.UnixNano(), r.Method, number})
		mu.Unlock()
	})

	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("listening on %s\n", ln.Addr())
	server := &http.Server{Handler: handler, ReadHeaderTimeout: 5 * time.Second}
	go server.Serve(ln)

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
	<-stop
	server.Close()
	f, err := os.Create(*logPath)
	if err != nil {
		log.Fatal(err)
	}
	out := bufio.NewWriter(f)
	mu.Lock()
	for _, a := range seen {
		fmt.Fprintf(out, "%d %d %s %d\n", a.start, a.end, a.method, a.number)
	}
	mu.Unlock()
	out.Flush()
	f.Close()
}
