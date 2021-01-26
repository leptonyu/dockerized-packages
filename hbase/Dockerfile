FROM adoptopenjdk/openjdk11-openj9:jdk-11.0.9_11_openj9-0.23.0-alpine-slim

ENV VERSION=2.4.0
ENV URL=https://mirrors.bfsu.edu.cn/apache/hbase/$VERSION/hbase-$VERSION-bin.tar.gz
ENV HBASE_HOME=/opt/hbase-$VERSION

RUN apk add --no-cache curl ca-certificates bash \
 && curl -L $URL | tar -zxf - -C /opt


ENV PATH=$PATH:$HBASE_HOME/bin:$HBASE_HOME/sbin

