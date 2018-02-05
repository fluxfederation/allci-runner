FROM ubuntu:16.04

ARG http_proxy

RUN echo "deb mirror://mirrors.ubuntu.com/mirrors.txt xenial main restricted universe multiverse" > /etc/apt/sources.list && \
	echo "deb mirror://mirrors.ubuntu.com/mirrors.txt xenial-updates main restricted universe multiverse" >> /etc/apt/sources.list && \
	echo "deb mirror://mirrors.ubuntu.com/mirrors.txt xenial-security main restricted universe multiverse" >> /etc/apt/sources.list && \
	DEBIAN_FRONTEND=noninteractive apt-get update && \
	DEBIAN_FRONTEND=noninteractive apt-get -y upgrade && \
	DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends install ruby2.3 docker.io git-core openssh-client && \
	apt-get clean -y && \
	rm -rf /var/cache/apt/archives/* /var/lib/apt/lists/*

RUN gem install bundler

WORKDIR /app
COPY *.rb /app/

ARG GIT_SSH_COMMAND="/usr/bin/ssh -o StrictHostKeyChecking=no"
ENV GIT_SSH_COMMAND=$GIT_SSH_COMMAND

CMD /app/runner.rb
