#!/bin/bash

# Function to print log messages with timestamp and log level
log_info() {
    echo "$(date +%Y-%m-%d_%H:%M:%S) [INFO] $1"
}

log_error() {
    echo "$(date +%Y-%m-%d_%H:%M:%S) [ERROR] $1" >&2
}

# Check if the required parameters are provided
if [ "$#" -ne 3 ]; then
    log_error "Usage: $0 <service-account-name> <namespace> <admin/read-only>"
    exit 1
fi

# Set variables from the provided parameters
SERVICE_ACCOUNT_NAME=$1
NAMESPACE=$2
PERMISSION_TYPE=$3

# Validate permission type
if [ "${PERMISSION_TYPE}" != "admin" ] && [ "${PERMISSION_TYPE}" != "read-only" ]; then
    log_error "Permission type must be either 'admin' or 'read-only'"
    exit 1
fi

# Define variables for cluster role and kubeconfig file
CLUSTER_ROLE_NAME="${SERVICE_ACCOUNT_NAME}-${PERMISSION_TYPE}-cluster-role"
CLUSTER_ROLE_BINDING_NAME="${SERVICE_ACCOUNT_NAME}-${PERMISSION_TYPE}-cluster-rolebinding"
KUBECONFIG_FILE="${SERVICE_ACCOUNT_NAME}-kubeconfig"

# Debug information
log_info "Service Account Name: ${SERVICE_ACCOUNT_NAME}"
log_info "Namespace: ${NAMESPACE}"
log_info "Permission Type: ${PERMISSION_TYPE}"
log_info "Cluster Role Name: ${CLUSTER_ROLE_NAME}"
log_info "Cluster Role Binding Name: ${CLUSTER_ROLE_BINDING_NAME}"
log_info "Kubeconfig File: ${KUBECONFIG_FILE}"

# 1. Create Service Account
log_info "Creating Service Account..."
if ! kubectl create serviceaccount ${SERVICE_ACCOUNT_NAME} -n ${NAMESPACE}; then
    log_error "Failed to create Service Account: ${SERVICE_ACCOUNT_NAME} in namespace: ${NAMESPACE}"
    exit 1
fi

# 2. Create ClusterRole based on permission type (admin or read-only)
if [ "${PERMISSION_TYPE}" == "admin" ]; then
    log_info "Assigning admin permissions..."
    cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${CLUSTER_ROLE_NAME}
rules:
- apiGroups: ["*"]
  resources: ["*"]
  verbs: ["*"]
EOF
    if [ $? -ne 0 ]; then
        log_error "Failed to create ClusterRole for admin permissions."
        exit 1
    fi
else
    log_info "Assigning read-only permissions..."
    cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${CLUSTER_ROLE_NAME}
rules:
- apiGroups: [""]
  resources: ["pods", "services"]
  verbs: ["get", "list"]
EOF
    if [ $? -ne 0 ]; then
        log_error "Failed to create ClusterRole for read-only permissions."
        exit 1
    fi
fi

# 3. Bind the ClusterRole to the Service Account
log_info "Creating ClusterRoleBinding..."
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${CLUSTER_ROLE_BINDING_NAME}
subjects:
- kind: ServiceAccount
  name: ${SERVICE_ACCOUNT_NAME}
  namespace: ${NAMESPACE}
roleRef:
  kind: ClusterRole
  name: ${CLUSTER_ROLE_NAME}
  apiGroup: rbac.authorization.k8s.io
EOF
if [ $? -ne 0 ]; then
    log_error "Failed to create ClusterRoleBinding."
    exit 1
fi

# 4. Manually create a Secret for the Service Account
log_info "Creating Secret for Service Account..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SERVICE_ACCOUNT_NAME}-token
  annotations:
    kubernetes.io/service-account.name: "${SERVICE_ACCOUNT_NAME}"
  namespace: ${NAMESPACE}
type: kubernetes.io/service-account-token
EOF
if [ $? -ne 0 ]; then
    log_error "Failed to create secret for Service Account."
    exit 1
fi

# 5. Wait for the Secret to be created and fetch the Service Account Token
log_info "Fetching Service Account Token..."
SECRET_NAME="${SERVICE_ACCOUNT_NAME}-token"
USER_TOKEN=""
while [ -z "${USER_TOKEN}" ]; do
    log_info "Waiting for token..."
    USER_TOKEN=$(kubectl get secret ${SECRET_NAME} -n ${NAMESPACE} -o jsonpath="{.data.token}" | base64 --decode)
    if [ $? -ne 0 ]; then
        log_error "Failed to fetch the Service Account Token."
        exit 1
    fi
    [ -z "${USER_TOKEN}" ] && sleep 2
done
log_info "User Token: ${USER_TOKEN}"

# 6. Get Minikube CA certificate
log_info "Fetching Minikube CA certificate..."
CA_CRT_PATH=$(minikube kubectl -- config view --raw -o jsonpath="{.clusters[0].cluster.certificate-authority}")
CLUSTER_CA=$(cat ${CA_CRT_PATH} | base64 | tr -d '\n')
if [ $? -ne 0 ]; then
    log_error "Failed to fetch CA certificate."
    exit 1
fi
log_info "CA certificate fetched successfully."

# 7. Fetch Kubernetes API server information
log_info "Fetching Kubernetes API server information..."
CLUSTER_NAME=$(kubectl config view --minify -o jsonpath="{.clusters[0].name}")
CLUSTER_SERVER=$(kubectl config view --minify -o jsonpath="{.clusters[0].cluster.server}")

if [ -z "${CLUSTER_NAME}" ] || [ -z "${CLUSTER_SERVER}" ]; then
    log_error "Failed to fetch Kubernetes API server information."
    exit 1
fi

log_info "Cluster Name: ${CLUSTER_NAME}"
log_info "Cluster Server: ${CLUSTER_SERVER}"
log_info "Cluster CA: ${CLUSTER_CA}"

# 8. Manually create kubeconfig file
log_info "Creating kubeconfig file..."
cat <<EOF > ${KUBECONFIG_FILE}
apiVersion: v1
kind: Config
clusters:
- name: ${CLUSTER_NAME}
  cluster:
    server: ${CLUSTER_SERVER}
    certificate-authority-data: ${CLUSTER_CA}
users:
- name: ${SERVICE_ACCOUNT_NAME}
  user:
    token: ${USER_TOKEN}
contexts:
- name: ${SERVICE_ACCOUNT_NAME}-context
  context:
    cluster: ${CLUSTER_NAME}
    user: ${SERVICE_ACCOUNT_NAME}
    namespace: ${NAMESPACE}
current-context: ${SERVICE_ACCOUNT_NAME}-context
EOF

if [ $? -ne 0 ]; then
    log_error "Failed to create kubeconfig file."
    exit 1
fi

log_info "kubeconfig file created at ${KUBECONFIG_FILE}"

# 9. Validate permissions with the new kubeconfig
log_info "Validating permissions..."
kubectl auth can-i get pods --kubeconfig=${KUBECONFIG_FILE}
if [ $? -ne 0 ]; then
    log_error "Permission validation failed."
    exit 1
fi
