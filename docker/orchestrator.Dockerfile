ARG RUNTIME_BASE
FROM elixir:1.19.1 AS build

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

COPY . .

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

# These are pragmatic release steps for Symphony's Elixir implementation.
# Adjust commands if the release name or build pipeline changes upstream.
RUN mix deps.get --only prod
RUN mix deps.compile
RUN mix compile
RUN mix release
RUN rel_dir="$(find _build/prod/rel -mindepth 1 -maxdepth 1 -type d | head -n1)" \
    && test -n "$rel_dir" \
    && cp -R "$rel_dir" /tmp/symphony-release

FROM ${RUNTIME_BASE} AS runtime

WORKDIR /app
COPY --from=build /tmp/symphony-release /app
COPY docker/orchestrator-entrypoint.sh /usr/local/bin/orchestrator-entrypoint.sh
RUN if [ -x /app/bin/symphony_elixir ] && [ ! -e /app/bin/symphony ]; then \
      ln -s /app/bin/symphony_elixir /app/bin/symphony; \
    fi
RUN chown -R symphony:symphony /app
RUN chmod 0755 /usr/local/bin/orchestrator-entrypoint.sh

USER symphony
EXPOSE 4000

ENTRYPOINT ["/usr/local/bin/orchestrator-entrypoint.sh"]
