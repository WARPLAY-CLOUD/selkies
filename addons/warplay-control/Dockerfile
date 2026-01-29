# Build warplay-linux-control (Rust) from sibling repo warplay-srs-server/.
#
# Expected build context: repository root (parent of selkies/), so that warplay-srs-server/ is available.

FROM rust:1-bookworm AS builder

# Native libs for X11 input injection (enigo) during link.
RUN apt-get update && apt-get install -y --no-install-recommends \
    pkg-config \
    libx11-dev \
    libxdo-dev \
    libxtst-dev \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /src

COPY warplay-srs-server/Cargo.toml warplay-srs-server/Cargo.lock ./warplay-srs-server/
COPY warplay-srs-server/src ./warplay-srs-server/src

WORKDIR /src/warplay-srs-server
RUN cargo build --release

FROM debian:bookworm-slim
WORKDIR /opt
COPY --from=builder /src/warplay-srs-server/target/release/warplay-linux-control /opt/warplay-linux-control
