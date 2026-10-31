# Template for a govengers service (govengers/standards templates/service).
# Build context is the repository root: docker build -f docker/server.Dockerfile .
# One Dockerfile per executable, named after it (DEP-006). Base images are pinned by digest with a readable
# tag (DEP-004); Dependabot proposes the bumps.

# The frontend (DEP-001). A service without a UI deletes this stage and the COPY --from=ui line below.
FROM --platform=$BUILDPLATFORM oven/bun:1@sha256:1d22548f177f4ff38e0c15baa3c2c46c6c2060ba2d1bc573bb4720b407548f1d AS ui
WORKDIR /src
COPY ui/package.json ui/bun.lock ./
RUN bun install --frozen-lockfile
COPY ui/ ./
RUN bun run build

# The builder runs on the build platform and cross-compiles, so the arm64 image needs no emulation.
FROM --platform=$BUILDPLATFORM golang:1.26@sha256:670bb5aa5349ae03b8516764718486f4f16399134bdc9acd0c46a23f043ab05c AS build
WORKDIR /src
# Dependencies in their own layer, before the source (DEP-002): a code change does not download them again.
# A layer, not a cache mount: CI's layer cache keeps layers, but not cache mounts.
COPY go.mod go.sum ./
RUN go mod download
COPY cmd/ cmd/
COPY internal/ internal/
COPY --from=ui /src/dist/spa internal/web/html
ARG VERSION=dev
ARG TARGETOS
ARG TARGETARCH
# The compile cache mount speeds up local rebuilds; in CI it starts empty and costs nothing.
RUN --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags="-s -w -X main.version=${VERSION}" -o /out/server ./cmd/server

# No shell, no package manager, not root (DEP-003). The user is numeric (distroless "nonroot" is 65532), so a
# pod with runAsNonRoot: true can verify it; a user name cannot be verified and fails the pod.
FROM gcr.io/distroless/static-debian13:nonroot@sha256:18f4cc26c9ffa7f20a359298be7deadac5c607c8e03a02b8119f1a5fc2f82c99
COPY --from=build /out/server /server
USER 65532:65532
# 8080 serves the API, 9090 the internal listener for /metrics (MET-001).
EXPOSE 8080 9090
ENTRYPOINT ["/server"]
