# Base for capturing lesson outputs: a fresh Ubuntu 24.04 with the tools Foundations
# installs, and an ordinary user "ada" (uid 1000) who can use sudo. Go is installed
# by each capture script, the way the lessons do it.
FROM ubuntu:24.04
RUN sed -i 's#http://archive.ubuntu.com/ubuntu#http://mirrors.edge.kernel.org/ubuntu#; s#http://security.ubuntu.com/ubuntu#http://mirrors.edge.kernel.org/ubuntu#' /etc/apt/sources.list.d/ubuntu.sources \
 && apt-get update -qq \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sudo build-essential curl git unzip time ca-certificates shellcheck xxd lsof >/dev/null \
 && rm -rf /var/lib/apt/lists/* \
 && userdel -r ubuntu \
 && useradd -m -u 1000 -s /bin/bash ada \
 && echo "ada ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ada
