#!/bin/bash

# Deploy Simples - Projeto BIA
# Rotina de deploy com versionamento baseado em commit hash
# Não sobrepõe o deploy-ecs.sh existente

set -e

# Configurações
REGION="us-east-1"
ECR_REPO="bia"
CLUSTER="cluster-bia"
SERVICE="service-bia"
TASK_FAMILY="task-def-bia"

# Cores
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Obter commit hash
get_commit() {
    git rev-parse --short=7 HEAD 2>/dev/null || error "Não é um repositório Git"
}

# Verificar pré-requisitos
check_deps() {
    command -v aws >/dev/null || error "AWS CLI não encontrado"
    command -v docker >/dev/null || error "Docker não encontrado"
    command -v jq >/dev/null || error "jq não encontrado"
}

# Preview do que será feito
preview() {
    local commit=$(get_commit)
    local account=$(aws sts get-caller-identity --query Account --output text)
    local ecr_uri="$account.dkr.ecr.$REGION.amazonaws.com/$ECR_REPO"
    
    echo
    echo "=== PREVIEW DO DEPLOY ==="
    echo "Commit Hash: $commit"
    echo "Imagem: $ecr_uri:$commit"
    echo "Cluster: $CLUSTER"
    echo "Service: $SERVICE"
    echo "Task Family: $TASK_FAMILY"
    echo "========================="
    echo
    
    read -p "Continuar com o deploy? (y/N): " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]] || { warn "Deploy cancelado"; exit 0; }
}

# Deploy principal
deploy() {
    local commit=$(get_commit)
    local account=$(aws sts get-caller-identity --query Account --output text)
    local ecr_uri="$account.dkr.ecr.$REGION.amazonaws.com/$ECR_REPO"
    
    log "Iniciando deploy - commit: $commit"
    
    # ECR Login
    log "Login no ECR..."
    aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $account.dkr.ecr.$REGION.amazonaws.com
    
    # Build
    log "Build da imagem..."
    docker build -t $ecr_uri:$commit -t $ecr_uri:latest .
    
    # Push
    log "Push para ECR..."
    docker push $ecr_uri:$commit
    docker push $ecr_uri:latest
    
    # Nova task definition
    log "Criando task definition..."
    local temp_file=$(mktemp)
    aws ecs describe-task-definition --task-definition $TASK_FAMILY --region $REGION --query 'taskDefinition' > "$temp_file"
    
    local new_temp_file=$(mktemp)
    jq --arg img "$ecr_uri:$commit" '
        .containerDefinitions[0].image = $img |
        del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .placementConstraints, .compatibilities, .registeredAt, .registeredBy)
    ' "$temp_file" > "$new_temp_file"
    
    local revision=$(aws ecs register-task-definition --region $REGION --cli-input-json file://"$new_temp_file" --query 'taskDefinition.revision' --output text)
    
    rm -f "$temp_file" "$new_temp_file"
    
    # Update service
    log "Atualizando serviço..."
    aws ecs update-service --region $REGION --cluster $CLUSTER --service $SERVICE --task-definition $TASK_FAMILY:$revision >/dev/null
    
    success "Deploy concluído!"
    success "Versão: $commit (revision: $revision)"
}

# Listar versões
list() {
    log "Versões disponíveis no ECR:"
    aws ecr describe-images --repository-name $ECR_REPO --region $REGION --query 'imageDetails[*].{Tags:imageTags,Date:imagePushedAt}' --output table
}

# Main
case "${1:-}" in
    "preview"|"p")
        check_deps
        preview
        deploy
        ;;
    "deploy"|"d")
        check_deps
        deploy
        ;;
    "list"|"l")
        check_deps
        list
        ;;
    *)
        echo "Deploy Simples - Projeto BIA"
        echo
        echo "Uso: $0 [comando]"
        echo
        echo "Comandos:"
        echo "  preview, p    Preview + deploy (recomendado)"
        echo "  deploy, d     Deploy direto"
        echo "  list, l       Listar versões no ECR"
        echo
        echo "Exemplo: $0 preview"
        ;;
esac
