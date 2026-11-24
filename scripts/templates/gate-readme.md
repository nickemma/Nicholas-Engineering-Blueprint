# Gate: <module name>

## What it checks

The failure it injects, and what must hold afterwards. A numbered list of pass conditions.

## Run it

~~~bash
bash gate/run.sh /path/to/your/code
~~~

What it needs (tools, services) and how long it takes.

## A pass looks like

The real output of a passing run.

## A fail looks like

The real output of a failing run, and what each kind of failure usually means. The gate was checked both ways: it passes on the reference build and fails on a deliberately broken one.
