FROM elixir:1.19.1

ENV MIX_ENV=prod
WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-client \
    git \
    curl \
    bash \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force

ARG SYMPHONY_REPO=https://github.com/jasonmorganson/symphony.git
RUN if [ ! -f mix.exs ]; then \
      git clone --depth=1 "${SYMPHONY_REPO}" /tmp/symphony-src && \
      cp -R /tmp/symphony-src/. /app/ ; \
    fi

RUN if [ -f /app/mix.exs ]; then \
      ln -sfn /app /opt/symphony-src; \
    elif [ -f /app/elixir/mix.exs ]; then \
      ln -sfn /app/elixir /opt/symphony-src; \
    else \
      echo "Unable to locate mix.exs in /app or /app/elixir" >&2; \
      exit 1; \
    fi

WORKDIR /opt/symphony-src

RUN mix deps.get --only prod
RUN mix deps.compile
RUN mix compile
RUN mix release
RUN rel_dir="$(find _build/prod/rel -mindepth 1 -maxdepth 1 -type d | head -n1)" \
    && test -n "$rel_dir" \
    && mkdir -p /release \
    && cp -R "$rel_dir"/. /release/
