FROM docker.io/library/dart:3.13.7 AS build
WORKDIR /app/server
COPY packages/ladno_sync /app/packages/ladno_sync
COPY server/pubspec.yaml server/pubspec.lock ./
RUN dart pub get --enforce-lockfile
COPY server ./
RUN dart compile exe bin/server.dart -o /app/ladno-server

FROM docker.io/library/debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-0 ca-certificates libstdc++6 tini \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -m -d /home/container -s /bin/bash container
COPY --from=build /app/ladno-server /usr/local/bin/ladno-server
COPY --chmod=755 deploy/pterodactyl/entrypoint.sh /entrypoint.sh
ENV USER=container HOME=/home/container DATA_DIR=/home/container/data
USER container
WORKDIR /home/container
ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
CMD ["/entrypoint.sh"]
