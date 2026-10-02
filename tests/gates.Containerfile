# tests/gates.Containerfile — the machine 'make gates' runs on when it is not
# CI's runner. Built and driven by tests/in-container.sh; see CONTRIBUTING,
# "Where the gates run".
#
# Ubuntu 24.04 because that is what ubuntu-latest is and what the droplet runs.
# The packages are the ones the suites call, not a convenience set: a tool
# present here and absent on the runner is a gate that passes here for a
# reason CI does not have.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash coreutils findutils grep sed gawk make git ca-certificates \
      jq curl python3 shellcheck nftables iproute2 procps psmisc \
      util-linux passwd login sudo tar gzip xz-utils file less \
      systemd \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /work
