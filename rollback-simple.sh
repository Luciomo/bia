#!/bin/bash

# Rollback Simples - Projeto BIA
# Rollback para versão específica baseada em commit hash

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

# Rollback para versão específica
rollback() {
    local target_tag="$1"
    [[ -z "$target_tag" ]] && error "Especifique a tag: $0 <commit-hash>"
    
    local account=$(aws sts get-caller-identity --query Account --output text)
    local ecr_uri="$account.dkr.ecr.$REGION.amazonaws.com/$ECR_REPO"
    
    log "Verificando se imagem existe..."
    aws ecr describe-images --repository-name $ECR_REPO --region $REGION --image-ids imageTag=$target_tag >/dev/null || error "Imagem $target_tag não encontrada"
    
    log "Fazendo rollback para: $target_tag"
    
    # Nova task definition com imagem antiga
    local temp_file=$(mktemp)
    aws ecs describe-task-definition --task-definition $TASK_FAMILY --region $REGION --query 'taskDefinition' > "$temp_file"
    
    local new_temp_file=$(mktemp)
    jq --arg img "$ecr_uri:$target_tag" '
        .containerDefinitions[0].image = $img |
        del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .placementConstraints, .compatibilities, .registeredAt, .registeredBy)
    ' "$temp_file" > "$new_temp_file"
    
    local revision=$(aws ecs register-task-definition --region $REGION --cli-input-json file://"$new_temp_file" --query 'taskDefinition.revision' --output text)
    
    rm -f "$temp_file" "$new_temp_file"
    
    # Update service
    log "Atualizando serviço..."
    aws ecs update-service --region $REGION --cluster $CLUSTER --service $SERVICE --task-definition $TASK_FAMILY:$revision >/dev/null
    
    success "Rollback concluído!"
    success "Versão atual: $target_tag (revision: $revision)"
}

# Listar versões para rollback
list() {
    log "Versões disponíveis para rollback:"
    aws ecr describe-images --repository-name $ECR_REPO --region $REGION --query 'imageDetails[*].{Tags:imageTags,Date:imagePushedAt}' --output table
}

# Main
case "${1:-}" in
    "list"|"l")
        list
        ;;
    "")
        echo "Rollback Simples - Projeto BIA"
        echo
        echo "Uso: $0 <commit-hash>"
        echo "     $0 list    # Listar versões disponíveis"
        echo
        echo "Exemplo: $0 abc1234"
        ;;
    *)
        rollback "$1"
        ;;
esac
