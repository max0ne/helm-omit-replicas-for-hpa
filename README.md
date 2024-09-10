# helm-omit-replicas-for-hpa.sh

This script solves the field ownership problem between Helm and HorizontalPodAutoscaler when converting a Deployment from static replicas count to autoscaled replicas count.


### Problem

When a Helm managed Deployemnt used to have a static replica count and it is later converted to using a HorizontalPodAutoscaler, Helm still owns the replica count field in the Deployment manifest.

If the replicas field is directly removed from the Deployment manifest, it'll trigger the Deployment to scale down to 1 replica.

If the replicas field is left in the Deployment manifest, it'll override the replica count set by the HorizontalPodAutoscaler and trigger an unintentional scale up or down during every Helm upgrade.

This field conflict is the classic field ownership problem, even used as example in [Kubernetes Server Side Apply documentation](https://kubernetes.io/docs/reference/using-api/server-side-apply/#transferring-ownership).
However since Helm does not support Server Side Apply and has its own way of tracking managed fields, this problem needs a custom Helm solution.

Upstream issues:
* https://github.com/helm/helm/issues/12650
* https://github.com/helm/helm/issues/12486

#### Problem Example

The `demo-chart` directory contains an example chart.

1. Install the demo chart with replicas hardcode to 10:

    ```sh
    helm upgrade -i helm-hpa-test ./demo-chart --set staticReplicas=true
    ```

    Observe a Deployment with 10 replicas is created:

    ```sh
    kubectl get deploy,hpa
    NAME                              READY   UP-TO-DATE   AVAILABLE   AGE
    deployment.apps/helm-hpa-test-1   10/10   10           10          7s
    ```

2. (**Undesired behavior**) Attempt to release without replicas field, this shows the previously mentioned problem

    ```sh
    helm upgrade -i helm-hpa-test ./demo-chart --set staticReplicas=false
    ```

    Observe the Deployment replicas is unintentionally dropped to 1. Although the HPA is created, it won't immediately scale the Deployment:
    ```sh
    kubectl get deploy,hpa
    NAME                              READY   UP-TO-DATE   AVAILABLE   AGE
    deployment.apps/helm-hpa-test-1   1/1     1            1           48s

    NAME                                                  REFERENCE                    TARGETS         MINPODS   MAXPODS   REPLICAS   AGE
    horizontalpodautoscaler.autoscaling/helm-hpa-test-1   Deployment/helm-hpa-test-1   <unknown>/70%   10        16        0          12s
    ```


### Solution

This script patches the Helm history secret to remove the replicas field from the Deployment manifest so all future Helm upgrades will no longer attempt to modify the replica count.

### Usage

1. Run the script to remove the `replicas` field from the Deployment manifest in the Helm history secret.

    ```bash
    helm-omit-replicas-for-hpa.sh --namespace <namespace> --helm-release <release-name> --deployment <deployment-name>
    ```

    If you have multiple Deployments in your Helm release, run the script multiple times with different Deployment names.

    Note running this script does not do anything to your real Deployment, it only modifies the Helm history Secret object, which is used by Helm to keep track of fields it manages.

2. Verify the Deployment in Helm history secret no longer has the `replicas` field.

    ```bash
    helm get manifest <release-name> -n <namespace>
    ```

3. Remove the `replicas` field from your Helm chart templates.

4. Upgrade your Helm release to apply the changes. In this upgrade, Helm should no longer attempt to modify the replica count.


### Example Usage

We'll keep using the `demo-chart`

1. Install the demo chart with replicas hardcode to 10:

    ```sh
    helm upgrade -i helm-hpa-test ./demo-chart --set staticReplicas=true
    ```

    Observe a Deployment with 10 replicas is created:

    ```sh
    kubectl get deploy,hpa
    NAME                              READY   UP-TO-DATE   AVAILABLE   AGE
    deployment.apps/helm-hpa-test-1   10/10   10           10          7s
    ```

    Observe in Helm history that replicas are hardcoded to 10:

    ```sh
    helm get manifest helm-hpa-test | grep replicas:
      replicas: 10
    ```

2. Run the script to remove the replicas field from the Deployment manifest:
    ```sh
    helm-omit-replicas-for-hpa.sh --namespace default --helm-release helm-hpa-test --deployment helm-hpa-test-1
    ...
    Helm manifest diff:
      8d7
      <   replicas: 10


    Do you want to apply the changes? [y/N] y
    secret/sh.helm.release.v1.helm-hpa-test.v1 patched
    ```

    Observe in Helm history that replicas are removed:
    ```sh
    helm get manifest helm-hpa-test | grep replicas:
    ```

3. Release the chart with HPA enabled and replicas no longer hardcoded:
    ```sh
    helm upgrade -i helm-hpa-test ./demo-chart --set staticReplicas=false
    ```

    Observe the Deployment is still running with 10 replicas:
    ```sh
    kubectl get deploy,hpa
    NAME                              READY   UP-TO-DATE   AVAILABLE   AGE
    deployment.apps/helm-hpa-test-1   10/10   10           10          2m10s

    NAME                                                  REFERENCE                    TARGETS         MINPODS   MAXPODS   REPLICAS   AGE
    horizontalpodautoscaler.autoscaling/helm-hpa-test-1   Deployment/helm-hpa-test-1   <unknown>/70%   10        16        0          4s
    ```
    
    The HPA should eventually start to manage the Deployment replicas after metrics are ready.
