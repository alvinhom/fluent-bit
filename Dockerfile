#FROM debian:bookworm-slim as builder
FROM debian:bullseye-slim as builder
#FROM debian:stretch as builder
#FROM debian:buster-slim as builder

# Fluent Bit version
ENV FLB_MAJOR 1
ENV FLB_MINOR 2
ENV FLB_PATCH 0
ENV FLB_VERSION 1.2.0

ENV DEBIAN_FRONTEND noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      cmake \
      make \
      wget \
      unzip \
#      libssl1.0-dev \
      libssl-dev \
#      libasl-dev \
      libsasl2-dev \
      pkg-config \
      libsystemd-dev \
      libsystemd0 \
      zlib1g-dev \
      flex \
      bison \
      && apt-get clean \
      && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /fluent-bit/bin /fluent-bit/etc /fluent-bit/log /tmp/src/
COPY . /tmp/src/
RUN rm -rf /tmp/src/build/*

WORKDIR /tmp/src/build/
RUN cmake -DFLB_DEBUG=Off \
          -DFLB_TRACE=Off \
          -DFLB_JEMALLOC=On \
          -DFLB_BUFFERING=On \
          -DFLB_TLS=On \
          -DFLB_SHARED_LIB=Off \
          -DFLB_EXAMPLES=Off \
          -DFLB_HTTP_SERVER=On \
          -DFLB_IN_SYSTEMD=On \
          -DFLB_OUT_KAFKA=On ..

RUN make -j $(getconf _NPROCESSORS_ONLN)
RUN install bin/fluent-bit /fluent-bit/bin/

# Configuration files
COPY conf/fluent-bit.conf \
     conf/parsers.conf \
     conf/parsers_java.conf \
     conf/parsers_extra.conf \
     conf/parsers_openstack.conf \
     conf/parsers_cinder.conf \
     conf/plugins.conf \
     /fluent-bit/etc/

# Simple example of how to properly extract packages for reuse in distroless
# Taken from: https://github.com/GoogleContainerTools/distroless/issues/863
FROM debian:bullseye-slim as deb-extractor

# We download all debs locally then extract them into a directory we can use as the root for distroless.
# We also include some extra handling for the status files that some tooling uses for scanning, etc.
WORKDIR /tmp
RUN apt-get update && \
    apt-get download \
        libssl1.1 \
        libsasl2-2 \
        pkg-config \
        libpq5 \
        libsystemd0 \
        zlib1g \
        ca-certificates \
        libatomic1 \
        libgcrypt20 \
        libzstd1 \
        liblz4-1 \
        libgssapi-krb5-2 \
        libldap-2.4-2 \
        libgpg-error0 \
        libkrb5-3 \
        libk5crypto3 \
        libcom-err2 \
        libkrb5support0 \
        libgnutls30 \
        libkeyutils1 \
        libp11-kit0 \
        libidn2-0 \
        libunistring2 \
        libtasn1-6 \
        libnettle8 \
        libhogweed6 \
        libgmp10 \
        libffi7 \
        liblzma5 \
        libyaml-0-2 && \
    mkdir -p /dpkg/var/lib/dpkg/status.d/ && \
    for deb in *.deb; do \
        package_name=$(dpkg-deb -I ${deb} | awk '/^ Package: .*$/ {print $2}'); \
        echo "Processing: ${package_name}"; \
        dpkg --ctrl-tarfile $deb | tar -Oxf - ./control > /dpkg/var/lib/dpkg/status.d/${package_name}; \
        dpkg --extract $deb /dpkg || exit 10; \
    done

# Remove unnecessary files extracted from deb packages like man pages and docs etc.
RUN find /dpkg/ -type d -empty -delete && \
    rm -r /dpkg/usr/share/doc/

FROM gcr.io/distroless/cc-debian11
MAINTAINER Eduardo Silva <eduardo@treasure-data.com>
LABEL Description="Fluent Bit docker image" Vendor="Fluent Organization" Version="1.1"

#COPY --from=builder /usr/lib/x86_64-linux-gnu/*sasl* /usr/lib/x86_64-linux-gnu/
#COPY --from=builder /usr/lib/x86_64-linux-gnu/libz* /usr/lib/x86_64-linux-gnu/
#COPY --from=builder /lib/x86_64-linux-gnu/libz* /lib/x86_64-linux-gnu/
#COPY --from=builder /usr/lib/x86_64-linux-gnu/libssl.so* /usr/lib/x86_64-linux-gnu/
#COPY --from=builder /usr/lib/x86_64-linux-gnu/libcrypto.so* /usr/lib/x86_64-linux-gnu/
# These below are all needed for systemd
#COPY --from=builder /lib/x86_64-linux-gnu/libsystemd* /lib/x86_64-linux-gnu/
#COPY --from=builder /lib/x86_64-linux-gnu/libselinux.so* /lib/x86_64-linux-gnu/
#COPY --from=builder /lib/x86_64-linux-gnu/liblzma.so* /lib/x86_64-linux-gnu/
#COPY --from=builder /usr/lib/x86_64-linux-gnu/liblz4.so* /usr/lib/x86_64-linux-gnu/
#COPY --from=builder /lib/x86_64-linux-gnu/libgcrypt.so* /lib/x86_64-linux-gnu/
#COPY --from=builder /lib/x86_64-linux-gnu/libpcre.so* /lib/x86_64-linux-gnu/
#COPY --from=builder /lib/x86_64-linux-gnu/libgpg-error.so* /lib/x86_64-linux-gnu/

# Copy the libraries from the extractor stage into root
COPY --from=deb-extractor /dpkg /

# Copy certificates
COPY --from=builder /etc/ssl/certs /etc/ssl/certs

COPY --from=builder /fluent-bit /fluent-bit

#
EXPOSE 2020

USER 1000

# Entry point
CMD ["/fluent-bit/bin/fluent-bit", "-c", "/fluent-bit/etc/fluent-bit.conf"]
