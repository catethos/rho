# syntax=docker/dockerfile:1
#
# Two-stage build for the Rho umbrella.
# Builds the `rho_web` release (which pulls in all in_umbrella deps).

# ─── Build stage ─────────────────────────────────────────────────────────
FROM hexpm/elixir:1.19.4-erlang-28.3-ubuntu-noble-20251013 AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      cmake \
      git \
      curl \
      python3 \
      python3-dev \
      python3-pip \
      python3-venv \
      python-is-python3 \
    && rm -rf /var/lib/apt/lists/*

ENV MIX_ENV=prod
ENV LANG=C.UTF-8
# Pin HOME so compile-time `Path.expand("~/...")` expressions (e.g.
# Rho.Tape.Store's @tapes_dir) bake in a path the runtime `elixir` user
# can write to — /app is chowned to elixir in the runtime stage.
ENV HOME=/app

RUN mix local.hex --force && mix local.rebar --force

WORKDIR /app

# Copy umbrella mix files first for dep caching.
COPY mix.exs mix.lock ./
COPY config config
COPY apps/rho/mix.exs            ./apps/rho/mix.exs
COPY apps/rho_stdlib/mix.exs     ./apps/rho_stdlib/mix.exs
COPY apps/rho_baml/mix.exs       ./apps/rho_baml/mix.exs
COPY apps/rho_python/mix.exs     ./apps/rho_python/mix.exs
COPY apps/rho_embeddings/mix.exs ./apps/rho_embeddings/mix.exs
COPY apps/rho_frameworks/mix.exs ./apps/rho_frameworks/mix.exs
COPY apps/rho_web/mix.exs        ./apps/rho_web/mix.exs

RUN mix deps.get --only prod
RUN mix deps.compile

# Copy full source.
COPY apps ./apps

RUN mix compile
RUN mix release rho_web

# ─── Runtime stage ───────────────────────────────────────────────────────
FROM ubuntu:noble-20251013 AS app

RUN apt-get update && apt-get install -y --no-install-recommends \
      openssl \
      libstdc++6 \
      libncurses6 \
      locales \
      ca-certificates \
      python3 \
      libpython3.12 \
    && rm -rf /var/lib/apt/lists/* \
    && locale-gen en_US.UTF-8

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV PHX_SERVER=true
ENV MIX_ENV=prod

RUN groupadd -g 1001 elixir && \
    useradd -u 1001 -g elixir -s /bin/bash -m elixir

WORKDIR /app
RUN chown elixir:elixir /app
USER elixir

COPY --from=build --chown=elixir:elixir /app/_build/prod/rel/rho_web ./

# Runtime config & skill files. `.rho.exs` is loaded via Path.expand(".rho.exs")
# against CWD at boot; `.agents/skills/` holds the markdown files the :skills
# plugin reads at request time.
COPY --chown=elixir:elixir .rho.exs ./
COPY --chown=elixir:elixir .agents ./.agents

EXPOSE 8080

CMD ["./bin/rho_web", "start"]
