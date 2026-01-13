#! /bin/bash
set -e

function wait_for_deployment() {
    local deployment=$1
    local namespace=$2
    local timeout=300
    local interval=25
    local elapsed=0
    local ready=0

    while [ $elapsed -lt $timeout ]; do
        ready=$(oc get deployment -n "$namespace" "$deployment" -o jsonpath='{.status.readyReplicas}')
        if [ "$ready" == "1" ]; then
            echo "Operator $deployment is ready"
            return 0
        fi
        echo "Operator $deployment is not yet ready, waiting another $interval seconds"
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    echo "Operator $deployment is not ready after $timeout seconds"
    return 1
}

function wait_for_phase() {
    local dsc=$1
    local objtype=$2
    local status=$3
    local timeout=900
    local interval=30
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        sleep $interval
        elapsed=$((elapsed + interval))
        statusReady=$(oc get "$objtype" "$dsc" -o=jsonpath='{.status.conditions[?(@.type=="'$status'")].status}')
        if [ "$statusReady" == "True" ]; then
            echo "$objtype $dsc is $status"
            return 0
        fi
        echo "$objtype $dsc is not yet $status, waiting another $interval seconds"
    done

	echo "$objtype $dsc is not $status after $timeout seconds"
    return 1
}

echo "################################################"
echo "Starting the script. Many of the following commands"
echo "will periodically check on OCP for operations to"
echo "complete, so it's normal to see errors."
echo "If this scripts completes successfully, you will"
echo "see a final message confirming installation went"
echo "well."

echo "This script will:"
echo " - Check the podvm root disk size to ensure enough space for the notebook"
echo " - Install Openshift AI, Servicemesh and Serverless in the cluster"
echo " - Create a new namespace and deploy CoCo fraud-detection notebook"
echo "################################################"

echo ""

echo "############################ Check root disk size #############"
NAMESPACE="openshift-sandboxed-containers-operator"
CONFIGMAP="peer-pods-cm"

# Get current value (empty if not set)
CURRENT_VALUE=$(oc get cm "${CONFIGMAP}" -n "${NAMESPACE}" \
  -o jsonpath='{.data.ROOT_VOLUME_SIZE}' 2>/dev/null || true)

# Default to 0 if empty or non-numeric
if [[ -z "${CURRENT_VALUE}" || ! "${CURRENT_VALUE}" =~ ^[0-9]+$ ]]; then
  CURRENT_VALUE=0
fi

echo "Current ROOT_VOLUME_SIZE=${CURRENT_VALUE}"

if (( CURRENT_VALUE > 19 )); then
  echo "ROOT_VOLUME_SIZE is already >= 20."
else
  echo "You need to update ROOT_VOLUME_SIZE in peer-pods-cm to at least 20"
  echo "Remember to restart the OSC caa daemonset after this change:"
  echo '# oc set env ds/osc-caa-ds -n openshift-sandboxed-containers-operator REBOOT="$(date)"'
  exit 1

  # oc patch cm "${CONFIGMAP}" -n "${NAMESPACE}" \
  #   --type merge \
  #   -p '{"data":{"ROOT_VOLUME_SIZE":"20"}}'

  # echo "Update complete."
fi

echo "###############################################################"

echo "############################ Install OAI ########################"
oc apply -f-<<EOF
---
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-serverless
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: serverless-operators
  namespace: openshift-serverless
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: serverless-operator
  namespace: openshift-serverless
spec:
  channel: stable
  name: serverless-operator
  installPlanApproval: Automatic
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

oc apply -f-<<EOF
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: servicemeshoperator
  namespace: openshift-operators
spec:
  channel: stable
  name: servicemeshoperator
  installPlanApproval: Automatic
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

oc apply -f-<<EOF
---
apiVersion: v1
kind: Namespace
metadata:
  name: redhat-ods-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhods-operator
  namespace: redhat-ods-operator
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhods-operator
  namespace: redhat-ods-operator
spec:
  name: rhods-operator
  installPlanApproval: Automatic
  channel: stable
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

echo "############################ Wait for Serverless ########################"
wait_for_deployment knative-openshift openshift-serverless || exit 1

echo "############################ Wait for Service Mesh ########################"
wait_for_deployment istio-operator openshift-operators || exit 1

echo "############################ Wait for OAI ########################"
wait_for_phase default-dsci DSCInitialization Available || exit 1

oc apply -f-<<EOF
---
apiVersion: datasciencecluster.opendatahub.io/v1
kind: DataScienceCluster
metadata:
  name: default-dsc
  labels:
    app.kubernetes.io/created-by: rhods-operator
    app.kubernetes.io/instance: default-dsc
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: datasciencecluster
    app.kubernetes.io/part-of: rhods-operator
spec:
  components:
    codeflare:
      managementState: Managed
    kserve:
      nim:
        managementState: Managed
      rawDeploymentServiceConfig: Headless
      serving:
        ingressGateway:
          certificate:
            type: OpenshiftDefaultIngress
        managementState: Managed
        name: knative-serving
      managementState: Managed
    modelregistry:
      registriesNamespace: rhoai-model-registries
      managementState: Managed
    feastoperator:
      managementState: Removed
    trustyai:
      eval:
        lmeval:
          permitCodeExecution: deny
          permitOnline: deny
      managementState: Managed
    ray:
      managementState: Managed
    kueue:
      defaultClusterQueueName: default
      defaultLocalQueueName: default
      managementState: Managed
    workbenches:
      workbenchNamespace: rhods-notebooks
      managementState: Managed
    dashboard:
      managementState: Managed
    modelmeshserving:
      managementState: Managed
    llamastackoperator:
      managementState: Removed
    datasciencepipelines:
      argoWorkflowsControllers:
        managementState: Managed
      managementState: Managed
    trainingoperator:
      managementState: Managed
EOF

echo "############################ Wait for OAI DSC ########################"
wait_for_phase default-dsc DataScienceCluster Ready || exit 1

# Disable local registry
oc patch configs.imageregistry.operator.openshift.io cluster \
  --type=merge \
  -p '{"spec":{"managementState":"Removed"}}'

# oc adm policy add-cluster-role-to-user cluster-admin admin
oc adm policy add-cluster-role-to-user cluster-admin "kube:admin"

ARO_RESOURCE_GROUP=$(oc get infrastructure/cluster -o jsonpath='{.status.platformStatus.azure.resourceGroupName}')
CLUSTER_ID=${ARO_RESOURCE_GROUP#aro-}

CLOUD_CONF=$(oc get configmap cloud-conf \
  -n openshift-cloud-controller-manager \
  -o jsonpath='{.data.cloud\.conf}')
ARO_REGION=$(echo "$CLOUD_CONF" | jq -r '.location')
OAI_NS=fraud-detection
OAI_NAME=fraud-detection
BRANCH_NAME=coco_workshop_aro

oc get secret pull-secret -n openshift-config -o yaml \
  | sed "s/namespace: openshift-config/namespace: ${OAI_NS}/" \
  | oc apply -n "${OAI_NS}" -f -

oc secrets link default pull-secret --for=pull -n ${OAI_NS}

oc apply -f-<<EOF
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  labels:
    opendatahub.io/dashboard: "true"
    opendatahub.io/project-sharing: "true"
  name: rhods-rb-${OAI_NAME}
  namespace: ${OAI_NS}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: admin
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: User
  name: admin
EOF

# TODO: image-registry.openshift-image-registry.svc:5000/redhat-ods-applications/s2i-minimal-notebook:2025.2
# TODO: default-dockercfg-bgsjr
oc apply -f-<<EOF
---
apiVersion: kubeflow.org/v1
kind: Notebook
metadata:
  annotations:
    notebooks.opendatahub.io/inject-oauth: "true"
    opendatahub.io/image-display-name: "CoCo | Jupyter | Data Science | CPU | Python 3.12"
    notebooks.opendatahub.io/oauth-logout-url: https://rhods-dashboard-redhat-ods-applications.apps.${CLUSTER_ID}.${ARO_REGION}.aroapp.io/projects/${OAI_NS}?notebookLogout=${OAI_NAME}
    opendatahub.io/accelerator-name: ''
    openshift.io/description: ${OAI_NAME}
    openshift.io/display-name: fraud-detection-coco-notebook
    notebooks.opendatahub.io/last-image-selection: s2i-generic-data-science-notebook:2025.2
    notebooks.opendatahub.io/last-image-version-git-commit-selection: d3137ca
    notebooks.opendatahub.io/last-size-selection: Small
    backstage.io/kubernetes-id: ${OAI_NAME}
  generation: 1
  labels:
    app: ${OAI_NAME}
    opendatahub.io/dashboard: "true"
    opendatahub.io/odh-managed: "true"
  name: ${OAI_NAME}
  namespace: ${OAI_NS}
spec:
  template:
    spec:
      runtimeClassName: kata-remote
      imagePullSecrets:
        - name: pull-secret
      affinity: {}
      initContainers:
        - name: git-clone
          image: docker.io/alpine/git:latest
          env:
          - name: BRANCH_NAME
            value: "coco_workshop_aro"
          workingDir: /opt/app-root/src
          command: ["/bin/sh", "-c"]
          args:
          - "git clone https://github.com/confidential-devhub/fraud-detection-on-cvms.git && cd fraud-detection-on-cvms && git checkout $BRANCH_NAME"
          volumeMounts:
          - name: app-root
            mountPath: /opt/app-root/src
      containers:
      - env:
        - name: NOTEBOOK_ARGS
          value: |-
            --ServerApp.port=8888
            --ServerApp.token=''
            --ServerApp.password=''
            --ServerApp.base_url=/notebook/${OAI_NS}/${OAI_NAME}
            --ServerApp.quit_button=False
            --ServerApp.tornado_settings={"user":"stratus","hub_host":"https://rhods-dashboard-redhat-ods-applications.apps.${CLUSTER_ID}.${ARO_REGION}.aroapp.io/projects/${OAI_NS}?notebookLogout=${OAI_NAME}","hub_prefix":"/projects/${OAI_NS}"}
        - name: JUPYTER_IMAGE
          value: registry.redhat.io/rhoai/odh-workbench-jupyter-minimal-cpu-py312-rhel9@sha256:a8cfef07ffc89d99acfde08ee879cc87aaa08e9a369e0cf7b36544b61b3ee3c7
        image: registry.redhat.io/rhoai/odh-workbench-jupyter-minimal-cpu-py312-rhel9@sha256:a8cfef07ffc89d99acfde08ee879cc87aaa08e9a369e0cf7b36544b61b3ee3c7
        imagePullPolicy: Always
        livenessProbe:
          failureThreshold: 3
          httpGet:
            path: /notebook/${OAI_NS}/${OAI_NAME}/api
            port: notebook-port
            scheme: HTTP
          initialDelaySeconds: 10
          periodSeconds: 5
          successThreshold: 1
          timeoutSeconds: 1
        name: ${OAI_NAME}
        ports:
        - containerPort: 8888
          name: notebook-port
          protocol: TCP
        readinessProbe:
          failureThreshold: 3
          httpGet:
            path: /notebook/${OAI_NS}/${OAI_NAME}/api
            port: notebook-port
            scheme: HTTP
          initialDelaySeconds: 10
          periodSeconds: 5
          successThreshold: 1
          timeoutSeconds: 1
        volumeMounts:
        - mountPath: /opt/app-root/src
          name: app-root
        - mountPath: /dev/shm
          name: shm
        - name: azure-secret
          mountPath: "/sealed/azure-value"
        - name: dataset-key
          mountPath: "/sealed/decryption"
        workingDir: /opt/app-root/src
      - args:
        - --provider=openshift
        - --https-address=:8443
        - --http-address=
        - --openshift-service-account=${OAI_NAME}
        - --cookie-secret-file=/etc/oauth/config/cookie_secret
        - --cookie-expire=24h0m0s
        - --tls-cert=/etc/tls/private/tls.crt
        - --tls-key=/etc/tls/private/tls.key
        - --upstream=http://localhost:8888
        - --upstream-ca=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        - --email-domain=*
        - --skip-provider-button
        - --openshift-sar={"verb":"get","resource":"notebooks","resourceAPIGroup":"kubeflow.org","resourceName":"${OAI_NAME}","namespace":"${OAI_NS}"}
        - --logout-url=https://rhods-dashboard-redhat-ods-applications.apps.one.ocp4.x86experts.com/projects/${OAI_NS}?notebookLogout=${OAI_NAME}
        image: registry.redhat.io/openshift4/ose-oauth-proxy@sha256:4bef31eb993feb6f1096b51b4876c65a6fb1f4401fee97fa4f4542b6b7c9bc46
        imagePullPolicy: Always
        livenessProbe:
          failureThreshold: 3
          httpGet:
            path: /oauth/healthz
            port: oauth-proxy
            scheme: HTTPS
          initialDelaySeconds: 30
          periodSeconds: 5
          successThreshold: 1
          timeoutSeconds: 1
        name: oauth-proxy
        ports:
        - containerPort: 8443
          name: oauth-proxy
          protocol: TCP
        readinessProbe:
          failureThreshold: 3
          httpGet:
            path: /oauth/healthz
            port: oauth-proxy
            scheme: HTTPS
          initialDelaySeconds: 5
          periodSeconds: 5
          successThreshold: 1
          timeoutSeconds: 1
        resources:
          limits:
            cpu: 100m
            memory: 64Mi
          requests:
            cpu: 100m
            memory: 64Mi
        volumeMounts:
        - mountPath: /etc/oauth/config
          name: oauth-config
        - mountPath: /etc/tls/private
          name: tls-certificates
      enableServiceLinks: false
      serviceAccountName: ${OAI_NAME}
      volumes:
      - name: azure-secret
        secret:
          secretName: sealed-azure-sas
      - name: dataset-key
        secret:
          secretName: sealed-dataset-key
      - name: app-root
        emptyDir: {}
      - emptyDir:
          medium: Memory
        name: shm
      - name: oauth-config
        secret:
          defaultMode: 420
          secretName: ${OAI_NAME}-oauth-config
      - name: tls-certificates
        secret:
          defaultMode: 420
          secretName: ${OAI_NAME}-tls
EOF

oc project $OAI_NS
wait_for_phase $OAI_NAME-0 Pod Ready || exit 1

# pod_name=$(oc get pods --selector=app=$OAI_NAME -o jsonpath='{.items[0].metadata.name}' -n $OAI_NS)

# oc exec $pod_name -n $OAI_NS -- /bin/bash -c "git clone https://github.com/confidential-devhub/fraud-detection-on-cvms.git && cd fraud-detection-on-cvms && git checkout $BRANCH_NAME"

oc project default

echo "################################################"
echo "Configuration complete. Enjoy testing CoCo on OAI!"
echo ""
echo "Access the RHOAI Dashboard at:"
echo "https://rhods-dashboard-redhat-ods-applications.apps.${CLUSTER_ID}.${ARO_REGION}.aroapp.io/projects/${OAI_NS}?section=workbenches"
echo ""
echo "Access the Notebook at:"
echo "https://${OAI_NAME}-${OAI_NS}.apps.${CLUSTER_ID}.${ARO_REGION}.aroapp.io/notebook/${OAI_NS}/${OAI_NAME}/lab"
echo "################################################"