# Livebook for the attached `make iex` runtime (see the Livebook comments in the Makefile).
# Livebook only attaches to a node on the same Elixir minor version: keep this FROM in step with
# .tool-versions, and bump the image tag in services/iex_livebook.yml whenever this file changes.
FROM docker.io/hexpm/elixir:1.20.2-erlang-28.5.0.5-debian-trixie-20260713-slim@sha256:bb7e7e58d2aefb9835872c0c3b69338cfaec804cc015b97f1fdc5b2a07e6388f
ARG LIVEBOOK_VERSION=0.19.10
ENV MIX_HOME=/opt/mix HEX_HOME=/opt/hex
RUN mix local.hex --force && mix local.rebar --force && \
    mix escript.install --force hex livebook ${LIVEBOOK_VERSION}
ENV PATH=/opt/mix/escripts:$PATH
CMD ["livebook", "server"]
