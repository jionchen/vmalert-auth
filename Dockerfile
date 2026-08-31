ARG VM_VERSION=v1.150.0

FROM golang:1.26.6-bookworm AS builder
ARG VM_VERSION
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates python3 && rm -rf /var/lib/apt/lists/*
WORKDIR /work
RUN git clone --depth 1 --branch "${VM_VERSION}" https://github.com/VictoriaMetrics/VictoriaMetrics.git /src
COPY overlay /overlay
COPY scripts/apply-overlay.sh /apply-overlay.sh
RUN chmod +x /apply-overlay.sh && /apply-overlay.sh /src /overlay
WORKDIR /src
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go test ./app/vmalert/config/fsurl ./app/vmalert && \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' -o /out/vmalert ./app/vmalert

FROM scratch
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=builder /out/vmalert /vmalert
ENTRYPOINT ["/vmalert"]
