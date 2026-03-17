#!/bin/bash
# LiteLLM 部署脚本：本地构造镜像，导出并通过 SSH 部署到远程服务器
# 目标主机: rmbook

set -euo pipefail

# 获取脚本所在目录并切换到项目根目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# 加载环境变量
GLOBAL_ENV_FILE="${PROJECT_ROOT}/../.env"
LOCAL_ENV_FILE="${SCRIPT_DIR}/.env"
if [ -f "$GLOBAL_ENV_FILE" ]; then
  echo "加载全局环境变量 $GLOBAL_ENV_FILE ..."
  set -a; source <(sed 's/\r//' "$GLOBAL_ENV_FILE"); set +a
fi
if [ -f "$LOCAL_ENV_FILE" ]; then
  echo "加载项目环境变量 .env ..."
  set -a; source <(sed 's/\r//' "./.env"); set +a
fi

IMAGES=(
  "docker.litellm.ai/berriai/litellm:main-stable"
  "docker.io/library/postgres:16"
  "docker.io/prom/prometheus:latest"
  "docker.io/library/nginx:alpine"
)

REMOTE_HOST="rmbook"
DEPLOY_DIR="~/litellm-deploy"

echo "1. 检查并准备本地镜像 ..."
for img in "${IMAGES[@]}"; do
  if docker image inspect "$img" >/dev/null 2>&1; then
    echo "镜像 $img 已存在。"
  else
    if [[ "$img" == *"litellm"* ]]; then
      echo "镜像 $img 不存在，开始本地构造 LiteLLM 镜像 ..."
      docker build --provenance=false -t "$img" -f Dockerfile .
    else
      echo "镜像 $img 不存在，开始拉取镜像 ..."
      docker pull "$img"
    fi
  fi
done

echo "1.5 检查远程主机的 Podman 网络后端 ..."
NETWORK_BACKEND=$(ssh "$REMOTE_HOST" "podman info --format '{{.Host.NetworkBackend}}'" 2>/dev/null || echo "unknown")

if [ "$NETWORK_BACKEND" != "netavark" ]; then
  echo "错误: 远程主机 ${REMOTE_HOST} 的 Podman 网络后端当前为 '$NETWORK_BACKEND'。"
  echo "LiteLLM 的部署需要使用 'netavark' 后端以确保容器网络正常工作。"
  echo ""
  echo "安装与配置帮助:"
  echo "1. 安装 netavark:"
  echo "   - RHEL/CentOS/Fedora: sudo dnf install netavark"
  echo "   - Ubuntu/Debian: sudo apt install netavark"
  echo "2. 切换后端: 在 /etc/containers/containers.conf 或 ~/.config/containers/containers.conf 的 [network] 部分设置:"
  echo "   network_backend = \"netavark\""
  echo "3. 重置 Podman 网络 (警告: 这会清空现有的所有容器和镜像): podman system reset"
  exit 1
fi

echo "2. 将镜像导入 ${REMOTE_HOST} (podman save & load) ..."
for img in "${IMAGES[@]}"; do
  if ssh "$REMOTE_HOST" "podman image inspect $img >/dev/null 2>&1"; then
    echo "远程主机 ${REMOTE_HOST} 已存在镜像 $img，跳过导入步骤。"
  else
    echo "远程主机缺少镜像 $img，将其导出并通过 ssh 的标准输入直接载入远程节点 ..."
    docker save "$img" | ssh "$REMOTE_HOST" "podman load"
  fi
done

echo "3. 准备部署文件 ..."
ssh "$REMOTE_HOST" "mkdir -p ${DEPLOY_DIR}"

echo "同步配置文件到远程主机 ..."
scp "${PROJECT_ROOT}/prometheus.yml" "$REMOTE_HOST:${DEPLOY_DIR}/"
scp "${SCRIPT_DIR}/litellm_conf.yml" "$REMOTE_HOST:${DEPLOY_DIR}/config.yaml"
scp "${SCRIPT_DIR}/docker-compose.yml" "$REMOTE_HOST:${DEPLOY_DIR}/"
scp "${SCRIPT_DIR}/litellm_admin_ng.conf" "$REMOTE_HOST:${DEPLOY_DIR}/"

echo "4. 在远程服务器初始化与启动服务 ..."
ssh "$REMOTE_HOST" "mkdir -p ${DEPLOY_DIR}"

echo "=> 生成 .env 文件 ..."
ssh "$REMOTE_HOST" "cat <<EOF > ${DEPLOY_DIR}/.env
LITELLM_MASTER_KEY=${LITELLM_MASTER_KEY}
EOF"

echo "=> 检查并创建 local-llm-service 网络 ..."
ssh "$REMOTE_HOST" "podman network inspect local-llm-service >/dev/null 2>&1 || podman network create local-llm-service"

echo '=> 重新启动 litellm 服务 ...'
ssh -t "$REMOTE_HOST" "
  export PATH=\"~/.local/bin:\$PATH\"
  cd ${DEPLOY_DIR}
  podman-compose down > /dev/null 2>&1 || true
  podman-compose up -d
"

echo ""
echo "🎉 LiteLLM 部署完成！"
echo "----------------------------------------------------"
echo "🖥️  远程主机: ${REMOTE_HOST}"
echo "📁  部署目录: ${DEPLOY_DIR}"
echo "🖼️  镜像列表: ${IMAGES[*]}"
echo "🔗  管理后台: http://${REMOTE_HOST}:4000/ui"
echo "🛠️  LLM 访问: 容器需加入网络 'local-llm-service'，Endpoint: http://litellm-gateway:8081/v1"
echo "----------------------------------------------------"
