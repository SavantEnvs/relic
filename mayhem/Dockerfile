# Build Stage
FROM --platform=linux/amd64 ubuntu:22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y cmake clang build-essential

COPY . /src
WORKDIR /src

# Build and install relic (instrumented: ASAN + fuzzer-no-link)
RUN mkdir /build_inst && cd /build_inst && \
    cmake /src \
        -DCMAKE_C_COMPILER=clang \
        -DRAND=HASHD \
        -DSHLIB=off \
        -DSTBIN=off \
        -DTESTS=0 \
        -DBENCH=0 \
        -DALLOC=DYNAMIC \
        -DARCH=X64 \
        -DCHECK=on \
        -DQUIET=on \
        -DCMAKE_INSTALL_PREFIX=/install_inst \
        -DCMAKE_C_FLAGS="-fsanitize=address,fuzzer-no-link -fno-omit-frame-pointer" && \
    make -j$(nproc) relic_s && \
    make install

# Build instrumented fuzzer (libfuzzer + ASAN)
RUN clang -fsanitize=address,fuzzer -fno-omit-frame-pointer \
    -I/install_inst/include \
    /src/mayhem/fuzz_bn.c \
    /install_inst/lib/librelic_s.a \
    -o /fuzz_bn

# Build and install relic (non-instrumented)
RUN mkdir /build_plain && cd /build_plain && \
    cmake /src \
        -DCMAKE_C_COMPILER=clang \
        -DRAND=HASHD \
        -DSHLIB=off \
        -DSTBIN=off \
        -DTESTS=0 \
        -DBENCH=0 \
        -DALLOC=DYNAMIC \
        -DARCH=X64 \
        -DCHECK=on \
        -DQUIET=on \
        -DCMAKE_INSTALL_PREFIX=/install_plain && \
    make -j$(nproc) relic_s && \
    make install

# Build non-instrumented (standalone) fuzzer
RUN clang -DSTANDALONE \
    -I/install_plain/include \
    /src/mayhem/fuzz_bn.c \
    /install_plain/lib/librelic_s.a \
    -o /fuzz_bn_no_inst

# Package Stage
FROM ubuntu:22.04
COPY --from=builder /fuzz_bn /fuzz_bn_no_inst /
