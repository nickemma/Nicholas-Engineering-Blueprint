# Exercises: Set up your machine

## Exercise 1: a second machine, from your notes

1. **What you're building:** the same working setup on a second environment, without this lesson open. It proves you can set up a machine you'll actually use at work, where nobody hands you the steps.
2. **The finished result:** a second environment (a second computer, a fresh WSL distribution such as `wsl --install -d Debian`, or a cloud VM) with Git configured, Go 1.26 or newer, and your `day1` program in its Linux home folder.
3. **A sample session:** on the new environment, the gate's output matches the pass shown in [gate/README.md](gate/README.md), with that machine's own CPU count.
4. **Done when:**
   1. You wrote your own setup notes first, in your own words, and used only them.
   2. The gate passes on the second environment.
   3. You verified the Go download's checksum there.
   4. Your notes record anything that differed from this lesson, and why.
5. **Stretch goals:** write your notes as a shell script that does steps 1–3 by itself, then run it on a third fresh environment.
6. **Hints:** if the gate fails, read its FAIL line before anything else; `PATH` and the module folder cause most problems.
