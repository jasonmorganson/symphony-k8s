use k8s_openapi::api::{apps::v1::StatefulSet, core::v1::Pod};
use kube::{
    Api,
    api::{Patch, PatchParams},
};
use serde_json::json;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum KubernetesError {
    #[error("Kubernetes request failed: {0}")]
    Request(#[from] kube::Error),
    #[error("Kubernetes returned an invalid replica count")]
    InvalidReplicaCount,
}

pub async fn current_replicas(
    statefulsets: &Api<StatefulSet>,
    name: &str,
) -> Result<u32, KubernetesError> {
    let replicas = statefulsets
        .get_scale(name)
        .await?
        .spec
        .and_then(|spec| spec.replicas)
        .unwrap_or_default();
    u32::try_from(replicas).map_err(|_| KubernetesError::InvalidReplicaCount)
}

pub async fn set_replicas(
    statefulsets: &Api<StatefulSet>,
    name: &str,
    replicas: u32,
) -> Result<(), KubernetesError> {
    let patch = Patch::Merge(json!({ "spec": { "replicas": replicas } }));
    statefulsets
        .patch_scale(name, &PatchParams::default(), &patch)
        .await?;
    Ok(())
}

pub fn pod_ready(pod: &Pod) -> bool {
    pod.metadata.deletion_timestamp.is_none()
        && pod
            .status
            .as_ref()
            .and_then(|status| status.phase.as_deref())
            == Some("Running")
        && pod
            .status
            .as_ref()
            .and_then(|status| status.conditions.as_ref())
            .is_some_and(|conditions| {
                conditions
                    .iter()
                    .any(|condition| condition.type_ == "Ready" && condition.status == "True")
            })
}

#[cfg(test)]
mod tests {
    use std::pin::pin;

    use futures::TryStreamExt;
    use http::{Method, Request, Response};
    use kube::{
        Client,
        client::Body,
        runtime::watcher::{self, Event},
    };
    use serde_json::{Value, json};
    use tower_test::mock;

    use super::*;

    #[tokio::test]
    async fn scale_subresource_uses_get_and_patch() {
        let (service, handle) = mock::pair::<Request<Body>, Response<Body>>();
        let responder = tokio::spawn(async move {
            let mut handle = pin!(handle);

            let (request, response) = handle.next_request().await.unwrap();
            assert_eq!(request.method(), Method::GET);
            assert_eq!(
                request.uri().path(),
                "/apis/apps/v1/namespaces/symphony/statefulsets/symphony-worker/scale"
            );
            response.send_response(json_response(scale(3)));

            let (request, response) = handle.next_request().await.unwrap();
            assert_eq!(request.method(), Method::PATCH);
            assert_eq!(
                request.uri().path(),
                "/apis/apps/v1/namespaces/symphony/statefulsets/symphony-worker/scale"
            );
            response.send_response(json_response(scale(5)));
        });

        let api: Api<StatefulSet> = Api::namespaced(Client::new(service, "symphony"), "symphony");
        assert_eq!(current_replicas(&api, "symphony-worker").await.unwrap(), 3);
        set_replicas(&api, "symphony-worker", 5).await.unwrap();
        responder.await.unwrap();
    }

    #[tokio::test]
    async fn watcher_handles_initial_relist_and_ready_apply_event() {
        let (service, handle) = mock::pair::<Request<Body>, Response<Body>>();
        let responder = tokio::spawn(async move {
            let mut handle = pin!(handle);
            let (request, response) = handle.next_request().await.unwrap();
            assert_eq!(request.method(), Method::GET);
            assert_eq!(request.uri().path(), "/api/v1/namespaces/symphony/pods");
            response.send_response(json_response(json!({
                "apiVersion": "v1",
                "kind": "PodList",
                "metadata": {"resourceVersion": "1"},
                "items": [pod("symphony-worker-0", true)]
            })));

            let (request, response) = handle.next_request().await.unwrap();
            assert_eq!(request.method(), Method::GET);
            assert_eq!(request.uri().path(), "/api/v1/namespaces/symphony/pods");
            assert!(
                request
                    .uri()
                    .query()
                    .unwrap_or_default()
                    .contains("watch=true")
            );
            let event = json!({
                "type": "ADDED",
                "object": pod("symphony-worker-1", true)
            });
            response.send_response(Response::new(Body::from(
                format!("{}\n", serde_json::to_string(&event).unwrap()).into_bytes(),
            )));
        });

        let api: Api<Pod> = Api::namespaced(Client::new(service, "symphony"), "symphony");
        let mut stream = pin!(watcher::watcher(
            api,
            watcher::Config::default().labels("app=symphony-worker")
        ));
        assert!(matches!(
            stream.try_next().await.unwrap(),
            Some(Event::Init)
        ));
        let initial = stream.try_next().await.unwrap().unwrap();
        assert!(matches!(initial, Event::InitApply(ref pod) if pod_ready(pod)));
        assert!(matches!(
            stream.try_next().await.unwrap(),
            Some(Event::InitDone)
        ));
        let applied = stream.try_next().await.unwrap().unwrap();
        assert!(matches!(applied, Event::Apply(ref pod) if pod_ready(pod)));
        responder.await.unwrap();
    }

    fn scale(replicas: u32) -> Value {
        json!({
            "apiVersion": "autoscaling/v1",
            "kind": "Scale",
            "metadata": {"name": "symphony-worker", "namespace": "symphony"},
            "spec": {"replicas": replicas},
            "status": {"replicas": replicas}
        })
    }

    fn pod(name: &str, ready: bool) -> Value {
        json!({
            "apiVersion": "v1",
            "kind": "Pod",
            "metadata": {
                "name": name,
                "namespace": "symphony",
                "resourceVersion": "1"
            },
            "spec": {
                "containers": [{"name": "worker", "image": "worker"}]
            },
            "status": {
                "phase": "Running",
                "conditions": [{
                    "type": "Ready",
                    "status": if ready { "True" } else { "False" }
                }]
            }
        })
    }

    fn json_response(value: Value) -> Response<Body> {
        Response::new(Body::from(serde_json::to_vec(&value).unwrap()))
    }
}
