FROM golang:1.24-alpine AS builder

WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -a -ldflags '-s -w' -o /bridge . \
 && apk add upx \
 && upx /bridge

FROM h4ckf0r0day/obscura:0.1.9

COPY --from=builder /bridge /bridge

EXPOSE 8191

ENTRYPOINT ["/bridge"]
