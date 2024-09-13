#!/bin/bash

# 변수 설정
SERVICE_ACCOUNT_NAME="restricted-user"
NAMESPACE="default"
CLUSTER_ROLE_NAME="restricted-cluster-role"
CLUSTER_ROLE_BINDING_NAME="restricted-cluster-rolebinding"
KUBECONFIG_FILE="restricted-user-kubeconfig"

# 디버그 정보 출력
echo "Service Account Name: ${SERVICE_ACCOUNT_NAME}"
echo "Namespace: ${NAMESPACE}"
echo "Cluster Role Name: ${CLUSTER_ROLE_NAME}"
echo "Cluster Role Binding Name: ${CLUSTER_ROLE_BINDING_NAME}"
echo "Kubeconfig File: ${KUBECONFIG_FILE}"

# 1. Service Account 생성
echo "Service Account 생성 중..."
kubectl create serviceaccount ${SERVICE_ACCOUNT_NAME} -n ${NAMESPACE}

# 2. ClusterRole 생성 (모든 네임스페이스에 대한 조회 권한 부여)
echo "ClusterRole 생성 중..."
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

# 3. ClusterRoleBinding 생성 (Service Account에 ClusterRole을 바인딩)
echo "ClusterRoleBinding 생성 중..."
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

# 4. Secret을 수동으로 생성
echo "Service Account용 Secret 수동 생성 중..."
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

# 5. Service Account Token 가져오기 (Secret 생성될 때까지 대기)
echo "Service Account Token을 가져오는 중..."
SECRET_NAME="${SERVICE_ACCOUNT_NAME}-token"
USER_TOKEN=""
while [ -z "${USER_TOKEN}" ]; do
  echo "Token 생성 대기 중..."
  USER_TOKEN=$(kubectl get secret ${SECRET_NAME} -n ${NAMESPACE} -o jsonpath="{.data.token}" | base64 --decode)
  [ -z "${USER_TOKEN}" ] && sleep 2
done
echo "User Token: ${USER_TOKEN}"

# 6. Minikube의 CA 인증서 가져오기
echo "Minikube CA 인증서 가져오는 중..."
CA_CRT_PATH=$(minikube kubectl -- config view --raw -o jsonpath="{.clusters[0].cluster.certificate-authority}")
CLUSTER_CA=$(cat ${CA_CRT_PATH} | base64 | tr -d '\n')
echo "CA 인증서 가져오기 완료"

# 7. Kubernetes API 서버 정보 가져오기
echo "Kubernetes API 서버 정보 가져오는 중..."
CLUSTER_NAME=$(kubectl config view --minify -o jsonpath="{.clusters[0].name}")
CLUSTER_SERVER=$(kubectl config view --minify -o jsonpath="{.clusters[0].cluster.server}")

echo "Cluster Name: ${CLUSTER_NAME}"
echo "Cluster Server: ${CLUSTER_SERVER}"
echo "Cluster CA: ${CLUSTER_CA}"

# 8. kubeconfig 파일 수동 생성
echo "kubeconfig 파일 수동 생성 중..."
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

echo "kubeconfig 파일이 ${KUBECONFIG_FILE}에 생성되었습니다."

# 9. 권한 확인
echo "권한 확인 중..."
kubectl auth can-i get pods --kubeconfig=${KUBECONFIG_FILE}
