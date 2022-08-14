FROM docker:20.10.17-dind

ENV JAVA_HOME /opt/openjdk-14
ENV PATH $JAVA_HOME/bin:$PATH

# https://jdk.java.net/
ENV JAVA_VERSION 14-ea+15
ENV JAVA_URL https://download.java.net/java/early_access/alpine/15/binaries/openjdk-14-ea+15_linux-x64-musl_bin.tar.gz
ENV JAVA_SHA256 76091da1b6ed29788f0cf85454d23900a4134286e5feb571247e5861f618d3cd
# "For Alpine Linux, builds are produced on a reduced schedule and may not be in sync with the other platforms."

RUN set -eux; \
  \
  wget -O /openjdk.tgz "$JAVA_URL"; \
  echo "$JAVA_SHA256 */openjdk.tgz" | sha256sum -c -; \
  mkdir -p "$JAVA_HOME"; \
  tar --extract --file /openjdk.tgz --directory "$JAVA_HOME" --strip-components 1; \
  rm /openjdk.tgz; \
  \
# https://github.com/docker-library/openjdk/issues/212#issuecomment-420979840
# https://openjdk.java.net/jeps/341
  java -Xshare:dump; \
  \
# basic smoke test
  java --version; \
  javac --version

# https://docs.oracle.com/javase/10/tools/jshell.htm
# https://docs.oracle.com/javase/10/jshell/
# https://en.wikipedia.org/wiki/JShell
CMD ["jshell"]

CMD ["gradle"]

ENV GRADLE_HOME /opt/gradle
ENV GRADLE_VERSION 5.6.2

ARG GRADLE_DOWNLOAD_SHA256=32fce6628848f799b0ad3205ae8db67d0d828c10ffe62b748a7c0d9f4a5d9ee0
RUN set -o errexit -o nounset \
  && echo "Installing dependencies" \
  && apk add --no-cache \
    bash \
    libstdc++ \
  \
  && echo "Installing build dependencies" \
  && apk add --no-cache --virtual .build-deps \
    ca-certificates \
    openssl \
    unzip \
  \
  && echo "Downloading Gradle" \
  && wget -O gradle.zip "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip" \
  \
  && echo "Checking download hash" \
  && echo "${GRADLE_DOWNLOAD_SHA256} *gradle.zip" | sha256sum -c - \
  \
  && echo "Installing Gradle" \
  && unzip gradle.zip \
  && rm gradle.zip \
  && mv "gradle-${GRADLE_VERSION}" "${GRADLE_HOME}/" \
  && ln -s "${GRADLE_HOME}/bin/gradle" /usr/bin/gradle \
  \
  && apk del .build-deps \
  \
  && echo "Adding gradle user and group" \
  && addgroup -S -g 1000 gradle \
  && adduser -D -S -G gradle -u 1000 -s /bin/ash gradle \
  && mkdir /home/gradle/.gradle \
  && chown -R gradle:gradle /home/gradle

# Create Gradle volume
USER gradle
VOLUME "/home/gradle/.gradle"
WORKDIR /home/gradle

RUN set -o errexit -o nounset \
  && echo "Testing Gradle installation" \
  && gradle --version