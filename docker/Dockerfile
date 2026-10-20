# SecureDesk server image.
# Build from the repository root:   docker build -f docker/Dockerfile -t securedesk .
#
# Stage 1 builds the web app from this source tree.
# Stage 2 builds the Linux and macOS agent packages (and the Linux session client with the SecureDesk look) from this source tree.
# Stage 3 fetches the remaining files of the Content folder (install scripts, Windows agent packages) of the Remotely release SecureDesk builds on.
# docker/overlay/Content (optional) is copied on top: the Windows session clients and installer built by
# build/Build-WindowsClients.ps1 (they carry the SecureDesk look and can have your server URL built in).

ARG UPSTREAM_VERSION=2022.08.02.0428

FROM mcr.microsoft.com/dotnet/sdk:6.0-bookworm-slim AS build
ARG UPSTREAM_VERSION
WORKDIR /src
COPY . .
RUN dotnet publish Server/Server.csproj -c Release -r linux-x64 --self-contained false -p:Version=${UPSTREAM_VERSION} -p:FileVersion=${UPSTREAM_VERSION} -p:LibraryRestore=false -p:TypeScriptCompileBlocked=true -o /out

FROM mcr.microsoft.com/dotnet/sdk:6.0-bookworm-slim AS unix-clients
ARG UPSTREAM_VERSION
RUN apt-get update && apt-get install -y --no-install-recommends zip && rm -rf /var/lib/apt/lists/*
WORKDIR /src
# only what the Linux/macOS clients need, so changes to the Server do not rebuild them
COPY Shared ./Shared
COPY Desktop.Core ./Desktop.Core
COPY Agent ./Agent
COPY Desktop.XPlat ./Desktop.XPlat
RUN rm -f Desktop.XPlat/nuget.config
# Linux: agent + session client (Desktop folder), self-contained like the upstream package
RUN dotnet publish Agent/Agent.csproj -c Release -r linux-x64 --self-contained true -p:Version=${UPSTREAM_VERSION} -p:FileVersion=${UPSTREAM_VERSION} -o /pub/linux-x64
RUN dotnet publish Desktop.XPlat/Desktop.XPlat.csproj -c Release -r linux-x64 --self-contained true -p:Version=${UPSTREAM_VERSION} -p:FileVersion=${UPSTREAM_VERSION} -o /pub/linux-x64/Desktop
RUN dotnet publish Desktop.XPlat/Desktop.XPlat.csproj -c Release -r linux-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeAllContentForSelfExtract=true -p:EnableCompressionInSingleFile=true -p:Version=${UPSTREAM_VERSION} -p:FileVersion=${UPSTREAM_VERSION} -o /pub/linux-single
# macOS: agent only (the install script starts it with the installed dotnet runtime), Intel and Apple silicon
RUN dotnet publish Agent/Agent.csproj -c Release -r osx-x64 --self-contained false -p:Version=${UPSTREAM_VERSION} -p:FileVersion=${UPSTREAM_VERSION} -o /pub/osx-x64
RUN dotnet publish Agent/Agent.csproj -c Release -r osx-arm64 --self-contained false -p:Version=${UPSTREAM_VERSION} -p:FileVersion=${UPSTREAM_VERSION} -o /pub/osx-arm64
RUN mkdir -p /content/Linux-x64 \
 && cp /pub/linux-single/Remotely_Desktop /content/Linux-x64/Remotely_Desktop \
 && (cd /pub/linux-x64 && zip -qr /content/Remotely-Linux.zip .) \
 && (cd /pub/osx-x64 && zip -qr /content/Remotely-MacOS-x64.zip .) \
 && (cd /pub/osx-arm64 && zip -qr /content/Remotely-MacOS-arm64.zip .)

FROM alpine:3.19 AS upstream-content
ARG UPSTREAM_VERSION
RUN apk add --no-cache curl unzip ca-certificates
RUN curl -fsSL --http1.1 --retry 8 --retry-all-errors --retry-delay 5 -o /tmp/server.zip "https://github.com/immense/Remotely/releases/download/v${UPSTREAM_VERSION}/Remotely_Server_Linux-x64.zip" && unzip -q /tmp/server.zip 'wwwroot/Content/*' -d /upstream
# Linux / macOS install scripts: SecureDesk folder and log names, migration of older installations
COPY docker/patch-install-scripts.sh /tmp/patch-install-scripts.sh
RUN sed -i 's/\r$//' /tmp/patch-install-scripts.sh \
 && sh /tmp/patch-install-scripts.sh /upstream/wwwroot/Content \
 && sed -i 's/The Remotely agent used for remote access/The SecureDesk agent used for remote access/' /upstream/wwwroot/Content/Install-*.sh

FROM mcr.microsoft.com/dotnet/aspnet:6.0-bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends wget ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /var/www/remotely
COPY --from=build /out/ ./
COPY --from=upstream-content /upstream/wwwroot/Content/ ./wwwroot/Content/
# Linux and macOS agent packages built from this source tree (replace the stock ones)
COPY --from=unix-clients /content/ ./wwwroot/Content/
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
LABEL org.opencontainers.image.description="SecureDesk remote support server (built on the open-source Remotely project, GPL-3.0). Default login: admin@securedesk.local / SecureDesk@123 - change it after the first login."
LABEL org.opencontainers.image.licenses="GPL-3.0-only"
LABEL securedesk.default-login="admin@securedesk.local / SecureDesk@123"

EXPOSE 5000
VOLUME ["/remotely-data"]
ENTRYPOINT ["/DockerMain.sh"]
