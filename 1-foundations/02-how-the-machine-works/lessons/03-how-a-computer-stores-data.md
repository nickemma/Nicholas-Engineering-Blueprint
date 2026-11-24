# 03 How a computer stores data

> Module: How the machine works · Time: ~4 h · Builds on: 02

## The problem

Sooner or later a number wraps round to a huge negative value, a name shows up as `Ã©`, or a program is fast on your laptop and slow on a server. Each of those has the same root: a computer stores everything, numbers, text, programs, as **bits**, in places that differ wildly in speed. If you can look at the raw bytes and know roughly how long it takes to reach them, those bugs stop being mysteries.

## The mental model

~~~text
 one bit:   0 or 1
 one byte:  8 bits            01000001  = 65 = 0x41 = the letter A
 a number:  8 bytes (64 bits) on today's machines

 how far away the data is (rough times to reach it):
   CPU register / cache     about 1 nanosecond
   RAM (memory)             about 100 nanoseconds
   SSD                      about 100 microseconds   (1,000 times RAM)
   network, another region  tens of milliseconds
~~~

The table of [latency numbers](../../../system-design/fundamentals/latency-numbers.md) has the full list. The point is the ratios: every step down is roughly a thousand times slower than the one above.

## The pattern

**Everything is bytes; meaning comes from how you read them.** The same byte, `0x41`, is the number 65 to one program and the letter `A` to another.

## Build it

### Step 1: Binary and hexadecimal

A byte holds 8 bits, so it can hold 2⁸ = 256 different values, 0 to 255. Writing bits out is long, so people use **hexadecimal** (base 16): the digits `0`–`9` and then `a`–`f` for 10 to 15. One hex digit is exactly 4 bits, so a byte is always two hex digits, `00` to `ff`. The shell can convert:

~~~bash
echo $((2#1010))
echo $((2#11111111))
echo $((0xff))
printf "%x\n" 255
printf "%d\n" 0x41
~~~

<!-- run: [ $((2#1010)) = 10 ] && [ $((0xff)) = 255 ] && [ "$(printf '%x' 255)" = ff ] && [ "$(printf '%d' 0x41)" = 65 ] -->

~~~text
10
255
255
ff
65
~~~

`$(( ... ))` is the shell's arithmetic; `2#` means "the next digits are base 2" and `0x` means base 16. `printf` formats a value: `%x` as hex, `%d` as a decimal number.

### Step 2: Numbers have limits

The shell, like Go later, stores a whole number in 64 bits. That has a largest value:

~~~bash
echo $((2**62))
echo $((2**63 - 1))
echo $((2**63))
echo $((9223372036854775807 + 1))
~~~

<!-- run: [ $((2**63)) = -9223372036854775808 ] -->

~~~text
4611686018427387904
9223372036854775807
-9223372036854775808
-9223372036854775808
~~~

`9223372036854775807` is the largest 64-bit signed number. Add one and it **wraps** to the most negative one: no error, no warning. One bit of the 64 records the sign, and adding one to the largest positive pattern flips it. Real systems have been broken by exactly this, from game scores to rocket guidance. Go behaves the same way, and you'll see it again in Foundations 03.

### Step 3: Text is numbers

`xxd` shows the bytes in a file or a stream. Ubuntu may not have it yet:

~~~bash
printf A | xxd
~~~

~~~text
bash: line 1: xxd: command not found
~~~

Install it (`sudo apt install -y xxd`; macOS already has it), then:

~~~bash
printf A | xxd
printf "Hi\n" | xxd
~~~

~~~text
00000000: 41                                       A
00000000: 4869 0a                                  Hi.
~~~

Each line shows a position (in hex), the bytes in hex, then the same bytes as text, with `.` for anything unprintable. `A` is the byte `0x41`; `H` is `0x48`, `i` is `0x69`, and the newline that ends a line is `0x0a`. This mapping is **ASCII**, and it covers only English letters, digits and punctuation, 128 characters in all.

Everything else uses **UTF-8**, which spends one byte on ASCII characters and two to four on the rest:

~~~bash
printf "é" | xxd
printf "café" | wc -c
printf "café" | wc -m
~~~

<!-- run: [ "$(printf 'é' | wc -c | tr -d ' ')" = 2 ] -->

~~~text
00000000: c3a9                                     ..
5
4
~~~

`é` is two bytes, `c3 a9`. So "café" is 5 bytes (`wc -c`) but 4 characters (`wc -m`). When a program reads those two bytes as if each were a character on its own, you get `Ã©` on screen: that's the bug from the opening paragraph. (If `wc -m` prints 5, your shell isn't set to UTF-8; `echo $LANG` should end in `UTF-8`.)

### Step 4: Files are bytes too

Your Go source file is text:

~~~bash
xxd ~/blueprint/day1/main.go | head -3
~~~

~~~text
00000000: 7061 636b 6167 6520 6d61 696e 0a0a 696d  package main..im
00000010: 706f 7274 2028 0a09 2266 6d74 220a 0922  port (.."fmt".."
00000020: 7275 6e74 696d 6522 0a29 0a0a 6675 6e63  runtime".)..func
~~~

The program Go builds from it is not text. Build it and look:

~~~bash
cd ~/blueprint/day1 && go build -o day1 . && xxd day1 | head -2 && ls -l day1
cd ~/blueprint/machine
~~~

~~~text
00000000: 7f45 4c46 0201 0100 0000 0000 0000 0000  .ELF............
00000010: 0200 3e00 0100 0000 00f8 4700 0000 0000  ..>.......G.....
-rwxrwxr-x 1 ada ada 2359414 Nov 18 16:47 day1
~~~

The first four bytes, `7f 45 4c 46` (`.ELF`), are a **magic number**: they tell Linux this is a program in ELF format, its format for programs. The rest is machine instructions and data, about 2.3 million bytes of it. (On macOS the program starts with `cf fa ed fe`, the magic number of Apple's format, Mach-O.)

### Step 5: Memory is faster than disk

When you read a file, Linux keeps a copy of it in spare RAM, the **page cache**, so the next read never touches the disk. Make a 512 MB file of random bytes:

~~~bash
dd if=/dev/urandom of=big.bin bs=1048576 count=512 2>/dev/null && ls -l big.bin
~~~

~~~text
-rw-rw-r-- 1 ada ada 536870912 Nov 18 16:47 big.bin
~~~

(`dd` copies bytes in blocks: here 512 blocks of 1 MiB, from `/dev/urandom`, a source of random bytes. `2>/dev/null` hides its summary of what it copied.)

Empty the cache, so the first read has to come from the disk, then time two reads. Emptying the cache is an administrator's job, so it needs `sudo`; on macOS the command is `sudo purge`.

~~~bash
sync && echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
time cat big.bin > /dev/null
time cat big.bin > /dev/null
~~~

~~~text

real	0m0.360s
user	0m0.000s
sys	0m0.281s

real	0m0.057s
user	0m0.004s
sys	0m0.050s
~~~

The first read came from the disk: 0.36 seconds. The second came from RAM: 0.06 seconds, six times faster. (`sync` writes anything still pending to disk first; `/dev/null` is a file that throws away whatever's written to it, so `cat` only reads.) Your times will differ. On a fast SSD the gap is smaller than the latency table suggests, because the disk reads big blocks in order and Linux reads ahead; random reads of small pieces show the full difference.

Delete the big file: `rm big.bin`.

## Check it

~~~bash
printf "%x\n" 200 && printf "€" | xxd
~~~

Before you run it, write down what you expect: 200 in hex, and how many bytes `€` takes in UTF-8. (It's `c8`, and three bytes: `e2 82 ac`.) If you predicted both, you can read bytes. That doesn't yet tell you how a program lays out structured data in memory; Go from zero shows you that.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `xxd: command not found` | Not installed | `sudo apt install -y xxd` |
| `wc -m` counts the same as `wc -c` for "café" | Your shell isn't using UTF-8 | `echo $LANG` should end `UTF-8`; on Ubuntu run `sudo update-locale LANG=C.UTF-8` and open a new terminal |
| `tee: /proc/sys/vm/drop_caches: Permission denied` | You left out `sudo` | Put `sudo` before `tee`, not before `echo` |
| Both reads are equally fast | The cache wasn't emptied, or the file is still cached | Run the `sync && echo 3 ...` line again, straight before the first `time` |
