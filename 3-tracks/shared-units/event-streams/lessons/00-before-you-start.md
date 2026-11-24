# 00 Before you start

> Event streams · Setup · Builds on Core 03's PostgreSQL transactions and the Messaging and resilience worker

The previous worker could commit a job effect and then crash before publishing its completion. Here you will record the event as part of the job transaction, send it to a retained Kafka log, and build a read model from that log. The lab uses a dedicated job history and a count per job so you can inspect each write.

Use Go 1.26.6 or later, Bash, and Python 3. The full gate also uses Docker. From the Blueprint checkout, save its path and enter a scratch directory.

~~~bash
go version
python3 --version
docker version
export blueprint="$PWD"
scratch=$(mktemp -d)
cd "$scratch"
~~~

`docker version` should report both client and server. The live gate brings up its own Kafka and PostgreSQL containers. The Go tests can run without those services.
