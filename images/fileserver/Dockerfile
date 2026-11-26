# fileserver: one static Go binary, four modes (see README.md), no third-party dependencies. The final image is scratch
# plus CA certificates (the rotator talks TLS to the Kubernetes API), so there is no OS to patch.
FROM mirror.gcr.io/library/golang:1.27-alpine@sha256:70bd7ddea8b6cbe5d6943cde279d6b67feb10cc924fb9100d1d8757c1575b280 AS build
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go test ./... && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/fileserver .

FROM scratch
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=build /out/fileserver /fileserver
USER 65532:65532
ENTRYPOINT ["/fileserver"]
