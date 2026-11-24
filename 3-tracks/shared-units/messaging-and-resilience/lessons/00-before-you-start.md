# 00 Before you start

Use Go 1.26.6 or later, Bash, and Python 3. The live lab also needs Docker. It starts its own RabbitMQ and PostgreSQL and binds their ports to loopback.

You will build a producer and a worker around a small durable job-recording effect. The worker uses a separate PostgreSQL ledger so you can observe when the effect commits relative to a RabbitMQ acknowledgment.

From the Blueprint checkout, save the repository path and enter a scratch directory for the code you build in these lessons.

~~~bash
export blueprint="$PWD"
scratch=$(mktemp -d)
cd "$scratch"
~~~
