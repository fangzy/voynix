# Stage 1: Build (xray download only — no certs: FC gateway does TLS, inbound is plain gRPC)
# APK_MIRROR: default dl-cdn.alpinelinux.org (fast on CI / non-CN); local CN builds pass
#   --build-arg APK_MIRROR=mirrors.aliyun.com  (dl-cdn is unreachable/slow in CN)
FROM alpine:3.20 AS builder

ARG XRAY_VERSION=v26.2.6
ARG TARGETARCH
ARG APK_MIRROR=dl-cdn.alpinelinux.org

RUN sed -i "s|dl-cdn.alpinelinux.org|${APK_MIRROR}|g" /etc/apk/repositories \
    && apk update \
    && apk add --no-cache curl ca-certificates unzip \
    && ARCH=$(case "${TARGETARCH}" in \
         amd64) echo "64" ;; \
         arm64) echo "arm64-v8a" ;; \
         *) echo "64" ;; \
       esac) \
    && curl -L -o /tmp/xray.zip \
        "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-${ARCH}.zip" \
    && unzip /tmp/xray.zip -d /usr/local/bin/ \
    && rm /tmp/xray.zip \
    && chmod +x /usr/local/bin/xray

# Stage 2: Runtime (geoip.dat kept — geoip:private needs it; geosite.dat dropped — no geosite rules; no certs — inbound is plain gRPC)
FROM alpine:3.20

ARG APK_MIRROR=dl-cdn.alpinelinux.org

RUN sed -i "s|dl-cdn.alpinelinux.org|${APK_MIRROR}|g" /etc/apk/repositories \
    && apk update \
    && apk add --no-cache ca-certificates gettext \
    && addgroup -S xray && adduser -S xray -G xray \
    && mkdir -p /etc/xray /var/log/xray

COPY --from=builder /usr/local/bin/xray /usr/local/bin/xray
COPY --from=builder /usr/local/bin/geoip.dat /usr/local/bin/geoip.dat

COPY config.template.json /etc/xray/config.template.json
COPY entrypoint.sh /entrypoint.sh
COPY healthcheck.sh /healthcheck.sh

RUN chmod +x /entrypoint.sh /healthcheck.sh \
    && chown -R xray:xray /etc/xray /var/log/xray

EXPOSE 8089

HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
  CMD /healthcheck.sh || exit 1

USER xray
ENTRYPOINT ["/entrypoint.sh"]
