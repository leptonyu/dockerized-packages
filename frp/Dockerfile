FROM golang:alpine as builder

ARG name

ENV CGO_ENABLED=0

COPY src /go/src

RUN apk add upx make \
 && cd /go/src \
 && go build -a -ldflags '-s -w' -o /main ./cmd/$name \
 && upx /main

FROM scratch
COPY --from=builder /main /main
ENTRYPOINT ["/main"]
