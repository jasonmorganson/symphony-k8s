FROM elixir:1.19.5-otp-28

ENV MIX_ENV=prod
ENV SYMPHONY_RELEASE_FORMAT=otp
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
ARG SYMPHONY_COMMIT=bebfcea85208df81d1692b868e79195e0ddad3fb
RUN if [ ! -f mix.exs ]; then \
      git clone --filter=blob:none --no-checkout "${SYMPHONY_REPO}" /tmp/symphony-src && \
      git -C /tmp/symphony-src fetch --depth=1 origin "${SYMPHONY_COMMIT}" && \
      git -C /tmp/symphony-src checkout --detach FETCH_HEAD && \
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
RUN mix run --no-start -e 'releases = Mix.Project.config() |> Keyword.fetch!(:releases); release = releases |> Keyword.fetch!(:symphony) |> Keyword.put(:steps, [:assemble]); Mix.ProjectStack.merge_config(releases: Keyword.put(releases, :symphony, release)); Mix.Task.run("release", ["symphony", "--overwrite", "--path", "/release"])'
