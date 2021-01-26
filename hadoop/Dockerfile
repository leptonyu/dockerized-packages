FROM adoptopenjdk/openjdk11-openj9:jdk-11.0.9_11_openj9-0.23.0-alpine-slim

MAINTAINER Daniel Yu <leptonyu@gmail.com>

ENV HADOOP_VERSION=3.2.2
ENV HADOOP_URL=https://mirrors.bfsu.edu.cn/apache/hadoop/common/hadoop-$HADOOP_VERSION/hadoop-$HADOOP_VERSION.tar.gz

RUN apk add --no-cache curl ca-certificates openssh-client pdsh bash \
 && curl -L $HADOOP_URL | tar -zxf - -C /opt \
 && ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N '' \
 && mv /root/.ssh/id_ed25519.pub /root/.ssh/authorized_keys \
 && ln -s /opt/hadoop-$HADOOP_VERSION/etc/hadoop /etc/hadoop \
 && echo -e "export JAVA_HOME=$JAVA_HOME" >> /etc/hadoop/hadoop-env.sh \
 && echo -e 'Host *\n\
  StrictHostKeyChecking no\n\
  UserKnownHostsFile /dev/null' > /root/.ssh/config

VOLUME $HADOOP_HOME/logs
VOLUME /namenode
VOLUME /datanode

ENV HADOOP_HOME=/opt/hadoop-$HADOOP_VERSION
ENV PATH=$PATH:$HADOOP_HOME/bin:$HADOOP_HOME/sbin
ENV HADOOP_CONF_DIR=/etc/hadoop
ENV HDFS_CONF_dfs_namenode_rpc___bind___host=0.0.0.0
ENV HDFS_CONF_dfs_namenode_servicerpc___bind___host=0.0.0.0
ENV HDFS_CONF_dfs_namenode_http___bind___host=0.0.0.0
ENV HDFS_CONF_dfs_namenode_https___bind___host=0.0.0.0
ENV HDFS_CONF_dfs_client_use_datanode_hostname=true
ENV HDFS_CONF_dfs_datanode_use_datanode_hostname=true
ENV HDFS_CONF_dfs_namenode_name_dir=/namenode
ENV HDFS_CONF_dfs_datanode_data_dir=/datanode
ENV HDFS_CONF_dfs_namenode_datanode_registration_ip___hostname___check=false
ENV YARN_CONF_yarn_resourcemanager_bind___host=0.0.0.0
ENV YARN_CONF_yarn_nodemanager_bind___host=0.0.0.0
ENV YARN_CONF_yarn_timeline___service_bind___host=0.0.0.0
ENV MAPRED_CONF_yarn_nodemanager_bind___host=0.0.0.0

COPY ./entrypoint.sh /entrypoint.sh

WORKDIR $HADOOP_HOME

ENTRYPOINT ["/entrypoint.sh"]