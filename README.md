# Zipper

A microservice for FynnCloud that creates ZIP archives from selected files and folders.

## Features

- Compress single files, multiple files, or entire folders into `.zip` archives.
- Triggered directly from the FynnCloud files context menu.
- Streams files to a temporary staging folder in `/tmp` to avoid keeping large archives in memory.

## Development

```bash
swift build
FYNNCLOUD_API_URL="http://localhost:8080" swift run
```

## Docker

```bash
docker build -t ghcr.io/fynncloudproject/app-zipper:1.0.0 .
docker run -p 8080:8080 -e FYNNCLOUD_API_URL="http://host.docker.internal:8080" ghcr.io/fynncloudproject/app-zipper:1.0.0
```

