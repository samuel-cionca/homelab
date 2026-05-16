# Official images lack linux/arm64; build from release binary + smartmontools.
FROM debian:bookworm-slim

ARG SMARTCTL_EXPORTER_VERSION=0.14.0
ARG TARGETARCH

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl smartmontools \
  && case "${TARGETARCH}" in \
    amd64) EXPORTER_ARCH=amd64 ;; \
    arm64) EXPORTER_ARCH=arm64 ;; \
    *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
  esac \
  && curl -fsSL -o /tmp/smartctl_exporter.tgz \
    "https://github.com/prometheus-community/smartctl_exporter/releases/download/v${SMARTCTL_EXPORTER_VERSION}/smartctl_exporter-${SMARTCTL_EXPORTER_VERSION}.linux-${EXPORTER_ARCH}.tar.gz" \
  && tar -xzf /tmp/smartctl_exporter.tgz -C /usr/local/bin --strip-components=1 \
    "smartctl_exporter-${SMARTCTL_EXPORTER_VERSION}.linux-${EXPORTER_ARCH}/smartctl_exporter" \
  && chmod 0755 /usr/local/bin/smartctl_exporter \
  && rm -f /tmp/smartctl_exporter.tgz \
  && apt-get purge -y curl \
  && apt-get autoremove -y \
  && rm -rf /var/lib/apt/lists/*

EXPOSE 9633
ENTRYPOINT ["/usr/local/bin/smartctl_exporter"]
CMD ["--smartctl.device=/dev/nvme0"]
