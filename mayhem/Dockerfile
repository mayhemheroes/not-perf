# Build Stage
FROM ghcr.io/evanrichter/cargo-fuzz:latest as builder

## Add source code to the build stage.
ADD . /src
WORKDIR /src
RUN cd cli && \
    env RUSTFLAGS="-g -Cdebug-assertions=on" cargo +nightly -Z sparse-registry build --release && \
    mv /src/target/release/nperf /

# Package Stage
FROM rustlang/rust:nightly

COPY --from=builder /nperf /
RUN mkdir /testsuite
COPY --from=builder /src/test-data/artifacts/ /testsuite/
