ARG VM_VERSION=v1.150.0

FROM golang:1.26.6-bookworm AS builder
ARG VM_VERSION
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    gcc-x86-64-linux-gnu \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /work
RUN git clone --depth 1 --branch "${VM_VERSION}" https://github.com/VictoriaMetrics/VictoriaMetrics.git /src
COPY overlay /overlay
COPY scripts/apply-overlay.sh /apply-overlay.sh
RUN chmod +x /apply-overlay.sh && /apply-overlay.sh /src /overlay
WORKDIR /src
RUN CGO_ENABLED=1 GOOS=linux GOARCH=amd64 CC=x86_64-linux-gnu-gcc \
    go test ./app/vmalert/config/fsurl ./app/vmalert && \
    CGO_ENABLED=1 GOOS=linux GOARCH=amd64 CC=x86_64-linux-gnu-gcc \
    go build \
      -trimpath \
      -buildvcs=false \
      -tags 'netgo osusergo' \
      -ldflags "-extldflags '-static' -X 'github.com/VictoriaMetrics/VictoriaMetrics/lib/buildinfo.Version=vmalert-${VM_VERSION}-custom'" \
      -o /out/vmalert-prod \
      ./app/vmalert

FROM alpine:3.24.1 AS certs
RUN apk update && apk upgrade && apk --update --no-cache add ca-certificates

FROM alpine:3.24.1
COPY --from=certs /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=builder /out/vmalert-prod /vmalert-prod
EXPOSE 8880
ENTRYPOINT ["/vmalert-prod"]
