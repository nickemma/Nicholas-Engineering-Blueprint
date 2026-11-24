# 00 Before you start

> Caching · Setup · Builds on Core 03 Docker and Postgres

Use Go 1.26.6 or later, Bash, and Python 3. The live gate also needs Docker. It starts its own Redis and PostgreSQL containers on loopback.

From the Blueprint checkout, check the tools and enter a new directory. Docker should report a client and server version.

~~~bash
go version
python3 --version
docker version
export blueprint="$PWD"
scratch=$(mktemp -d)
cd "$scratch"
~~~

The lab stores a job ID, status, and revision in PostgreSQL. You will cache the read path and compare the number of database reads under different workloads. The [gate](../gate/README.md) can build the whole module from this repository.
