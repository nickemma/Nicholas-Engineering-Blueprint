# 00 Before you start

> Tenancy and abuse control · Setup · Builds on Core 03 Docker and Postgres and Core 08 Shipping safely

You will build a small Switchyard jobs API shared by two tenant fixtures. A tenant is a customer or organizational boundary. Clients in the lab belong to one tenant and have an explicit role. The gate checks authentication, access to tenant data, and how much request capacity each tenant can consume.

Use Go 1.26.6 or later, Bash, and Python 3. Docker is needed for the live gate. From the repository root, check the tools and create a scratch directory.

~~~bash
go version
python3 --version
docker version
export blueprint="$PWD"
scratch=$(mktemp -d)
cd "$scratch"
~~~

The Docker command should report both a client and a running server. The live gate binds all lab services to loopback and provisions disposable PostgreSQL and Redis data. Use generated fixture credentials in the [manual lab](../gate/README.md#try-the-api-manually).
