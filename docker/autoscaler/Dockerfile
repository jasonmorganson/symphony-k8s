ARG CONTROL_PLANE_BUILD
FROM ${CONTROL_PLANE_BUILD} AS control-plane-build

FROM scratch
COPY --from=control-plane-build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=control-plane-build /src/target/release/symphony-autoscaler /symphony-autoscaler
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/symphony-autoscaler"]
