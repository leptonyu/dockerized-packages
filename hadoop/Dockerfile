FROM adoptopenjdk/openjdk11-openj9:jdk-11.0.9_11_openj9-0.23.0-alpine-slim

ENV HADOOP_VERSION=3.2.2
ENV HADOOP_HOME=/opt/hadoop-$HADOOP_VERSION
ENV PATH=$PATH:$HADOOP_HOME/bin:$HADOOP_HOME/sbin
ENV HDFS_NAMENODE_USER=root
ENV HDFS_DATANODE_USER=root
ENV HDFS_SECONDARYNAMENODE_USER=root

VOLUME /namenode
VOLUME /datanode

RUN apk add --no-cache curl ca-certificates openssh-client pdsh bash \
 && curl -L https://downloads.apache.org/hadoop/common/hadoop-3.2.2/hadoop-3.2.2.tar.gz | tar -zxf - -C /opt \
 && ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N '' \
 && mv /root/.ssh/id_ed25519.pub /root/.ssh/authorized_keys
COPY ./etc/* $HADOOP_HOME/etc/hadoop/
COPY ./ssh/config /root/.ssh/

RUN echo "export JAVA_HOME=$JAVA_HOME" >> $HADOOP_HOME/etc/hadoop/hadoop-env.sh \
 && chmod 700 /root/.ssh \
 && chmod 600 /root/.ssh/*

VOLUME $HADOOP_HOME/logs

WORKDIR $HADOOP_HOME