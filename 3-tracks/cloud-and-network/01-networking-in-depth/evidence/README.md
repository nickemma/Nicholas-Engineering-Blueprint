# Networking in depth · Evidence

The reference used WSL2 Linux 6.18.58.1, Go 1.26.6, and iperf3 3.16. Both live containers ran with external networking disabled. The raw archive contains the kernel and controller inventory, socket state, per-trial qdisc counters, ping output, and per-object completion times.

| Fixture | Observed result |
|---|---|
| Link calibration | The programmed 20 Mbit/s path delivered 18.92 Mbit/s with median idle RTT of 40.4 ms. |
| Small buffer and loss | The 16 KiB socket-buffer trial delivered 4.62 Mbit/s with zero sender retransmissions. The three 1% programmed-loss trials delivered 4.11–4.62 Mbit/s with 6–9 retransmissions. |
| Controllers and sharing | The kernel exposed Reno and CUBIC. Both made progress in the concurrent run, at 15.53 and 3.07 Mbit/s respectively. BBR was unavailable. |
| Queue comparison | The median of three loaded-RTT medians fell from 121.5 ms with FIFO to 40.5 ms with FQ-CoDel. Receiver goodput was 18.92–18.94 Mbit/s and 18.49 Mbit/s respectively. |
| Verified HTTP objects | All 24 runs returned matching object hashes. With the 1% loss setting, cold completion was 206–207 ms for HTTP/2 and 129–132 ms for HTTP/3 in the three trials. |
| Edge paths | The timed direct, proxy, and warm-cache batches took 92.0, 95.3, and 52.3 ms. The warm cache kept the origin count at 327. |
| Partial partition | The forward UDP probe arrived and the reverse probe timed out. The job path went from HTTP 200 to 502 and returned to 200 after healing. The first successful job request after healing took 6.50 s. |
| Route model | Withdrawing the preferred site changed the selected route to `[1 2]`. The model settled in six rounds, including its confirmation round. |

- [Portable and live gate transcript](gate.txt)
- [Clean lesson replay](replay.txt)
- [Live measurements](summary.json)
- [Raw trial outputs](networking-in-depth-raw.tar.gz)

The protocols use independent loss draws on the same configured path. Queue comparisons use the same rate and nominal RTT. The route experiment reports model rounds.
