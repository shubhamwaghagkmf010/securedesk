# SecureDesk server image.
# Build from the repository root:   docker build -f docker/Dockerfile -t securedesk .
#
# Stage 1 builds the web app from this source tree.
# Stage 2 fetches the stock agent packages (Content folder) of the upstream release this fork is based on.
# docker/overlay/Content (optional) is copied on top: the Windows session clients and installer built by
# build/Build-WindowsClients.ps1 (they carry the SecureDesk look and can have your server URL built in).

ARG UPSTREAM_VERSION=2022.08.02.0428

FROM mcr.microsoft.com/dotnet/sdk:6.0-bookworm-slim AS build
ARG UPSTREAM_VERSION
WORKDIR /src
COPY . .
RUN dotnet publish Server/Server.csproj -c Release -r linux-x64 --self-contained false -p:Version=${UPSTREAM_VERSION} -p:FileVersion=${UPSTREAM_VERSION} -p:LibraryRestore=false -p:TypeScriptCompileBlocked=true -o /out

FROM alpine:3.19 AS upstream-content
ARG UPSTREAM_VERSION
RUN apk add --no-cache curl unzip ca-certificates
RUN curl -fsSL -o /tmp/server.zip "https://github.com/immense/Remotely/releases/download/v${UPSTREAM_VERSION}/Remotely_Server_Linux-x64.zip" && unzip -q /tmp/server.zip 'wwwroot/Content/*' -d /upstream

FROM mcr.microsoft.com/dotnet/aspnet:6.0-bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends wget ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /var/www/remotely
COPY --from=build /out/ ./
COPY --from=upstream-content /upstream/wwwroot/Content/ ./wwwroot/Content/
# optional: SecureDesk Windows clients (see build/Build-WindowsClients.ps1)
COPY docker/overlay/ ./wwwroot/

RUN mkdir -p /remotely-data && sed -i 's/DataSource=Remotely.db/DataSource=\/remotely-data\/Remotely.db/' appsettings.json

COPY docker/entrypoint.sh /DockerMain.sh
RUN sed -i 's/\r$//' /DockerMain.sh && chmod 755 /DockerMain.sh

ENV ASPNETCORE_URLS=http://*:5000
ENV ASPNETCORE_ENVIRONMENT=Production
# settings saved from the web UI live in the data volume behind a symlink: poll so changes are picked up
ENV DOTNET_USE_POLLING_FILE_WATCHER=true

LABEL org.opencontainers.image.title="SecureDesk"
LABEL org.opencontainers.image.description="SecureDesk remote support server (rebranded Remotely, GPL-3.0). Default login: admin@securedesk.local / SecureDesk@123 - change it after the first login."
LABEL org.opencontainers.image.licenses="GPL-3.0-only"
LABEL securedesk.default-login="admin@securedesk.local / SecureDesk@123"

EXPOSE 5000
VOLUME ["/remotely-data"]
ENTRYPOINT ["/DockerMain.sh"]
