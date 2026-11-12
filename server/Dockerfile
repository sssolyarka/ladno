FROM docker.io/library/dart:3.13.7 AS build
WORKDIR /app/server
COPY packages/ladno_sync /app/packages/ladno_sync
COPY server/pubspec.yaml server/pubspec.lock ./
RUN dart pub get --enforce-lockfile
COPY server ./
RUN dart compile exe bin/server.dart -o /app/ladno-server

FROM docker.io/library/debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-0 ca-certificates libstdc++6 && rm -rf /var/lib/apt/lists/* \
    && groupadd -g 10001 ladno && useradd -u 10001 -g ladno -M ladno && mkdir /data && chown ladno:ladno /data
COPY --from=build /app/ladno-server /usr/local/bin/ladno-server
USER 10001:10001
ENV DATA_DIR=/data PORT=8080
WORKDIR /data
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/ladno-server"]
