FROM alpine:3.10

ARG ver

ENV GHC_VERSION=$ver
ENV GHC_INSTALL_PATH=/opt/ghc
ENV GHC_XZ=ghc-${GHC_VERSION}-x86_64-unknown-linux-musl.tar.xz

RUN cd /tmp \
 && wget https://github.com/redneb/ghc-alt-libc/releases/download/ghc-${GHC_VERSION}-musl/${GHC_XZ} \
 && tar xf ${GHC_XZ} \
 && apk --no-cache add bash perl alpine-sdk ncurses xz-dev gmp-dev postgresql-dev zlib-dev cabal \
 && cd /tmp/ghc-${GHC_VERSION} \
 && ./configure --prefix=${GHC_INSTALL_PATH} \
 && make install \
 && ln -s /opt/ghc/bin/ghc-${GHC_VERSION} /bin/ghc \
 && ln -s /opt/ghc/bin/ghc-pkg-${GHC_VERSION} /bin/ghc-pkg \
 && ln -s /opt/ghc/bin/ghci-${GHC_VERSION} /bin/ghci \
 && rm -rf /tmp/ghc-${GHC_VERSION}
