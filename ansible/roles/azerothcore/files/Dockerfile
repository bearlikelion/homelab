# The runtime stage of upstream apps/docker/Dockerfile. The binaries are not
# copied in: compose bind mounts them from the build artifacts.
FROM ubuntu:24.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      libmysqlclient21 libreadline8 libicu74 libncurses5-dev gettext-base default-mysql-client \
    && rm -rf /var/lib/apt/lists/*

ENV PATH="/azerothcore/env/dist/bin:$PATH"
WORKDIR /azerothcore
# dbimport writes its temporary SQL files into the working directory.
RUN chown ubuntu:ubuntu /azerothcore
