ARG RUNTIME_BASE
ARG SYMPHONY_RELEASE_IMAGE
FROM ${SYMPHONY_RELEASE_IMAGE} AS release
FROM ${RUNTIME_BASE} AS runtime

WORKDIR /app
COPY --from=release /release/ /app/
COPY docker/orchestrator/entrypoint.sh /usr/local/bin/orchestrator-entrypoint.sh
RUN if [ -x /app/bin/symphony_elixir ] && [ ! -e /app/bin/symphony ]; then \
      ln -s /app/bin/symphony_elixir /app/bin/symphony; \
    fi
RUN chown -R symphony:symphony /app
RUN chmod 0755 /usr/local/bin/orchestrator-entrypoint.sh

USER symphony
EXPOSE 4000

ENTRYPOINT ["/usr/local/bin/orchestrator-entrypoint.sh"]
