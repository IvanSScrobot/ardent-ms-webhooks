#!/bin/bash

# Retell Webhook Microservice Deployment Script

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
IMAGE_NAME="retell-webhook-microservice"
IMAGE_TAG="latest"
NAMESPACE="retell-webhooks"

echo -e "${GREEN}🚀 Deploying Retell Webhook Microservice${NC}"

# Check if required tools are installed
command -v docker >/dev/null 2>&1 || { echo -e "${RED}❌ Docker is required but not installed.${NC}" >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo -e "${RED}❌ kubectl is required but not installed.${NC}" >&2; exit 1; }

# Function to prompt for secrets
prompt_for_secrets() {
    echo -e "${YELLOW}📝 Please provide the following secrets:${NC}"
    
    read -p "Enter your Retell API Key: " -s RETELL_API_KEY
    echo
    read -p "Enter your webhook hash: " WEBHOOK_HASH
    read -p "Enter your forward endpoint URL: " FORWARD_ENDPOINT
    read -p "Enter your site name (optional, default: localhost): " SITE_NAME
    
    SITE_NAME=${SITE_NAME:-localhost}
    
    # Encode secrets to base64
    RETELL_API_KEY_B64=$(echo -n "$RETELL_API_KEY" | base64 -w 0)
    WEBHOOK_HASH_B64=$(echo -n "$WEBHOOK_HASH" | base64 -w 0)
    FORWARD_ENDPOINT_B64=$(echo -n "$FORWARD_ENDPOINT" | base64 -w 0)
    
    echo -e "${GREEN}✅ Secrets encoded successfully${NC}"
}

# Function to update secrets file
update_secrets() {
    echo -e "${YELLOW}📝 Updating secrets file...${NC}"
    
    # Create temporary secrets file
    cat > k8s/secrets-temp.yaml << EOF
apiVersion: v1
kind: Secret
metadata:
  name: retell-webhook-secrets
  namespace: retell-webhooks
type: Opaque
data:
  retell-api-key: ${RETELL_API_KEY_B64}
  webhook-hash: ${WEBHOOK_HASH_B64}
  forward-endpoint: ${FORWARD_ENDPOINT_B64}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: retell-webhook-config
  namespace: retell-webhooks
data:
  SITE_NAME: "${SITE_NAME}"
  PORT: "3000"
  NODE_ENV: "production"
EOF
    
    mv k8s/secrets-temp.yaml k8s/secrets.yaml
    echo -e "${GREEN}✅ Secrets file updated${NC}"
}

# Function to build Docker image
build_image() {
    echo -e "${YELLOW}🔨 Building Docker image...${NC}"
    
    # Build TypeScript
    npm run build
    
    # Build Docker image
    docker build -t ${IMAGE_NAME}:${IMAGE_TAG} .
    
    echo -e "${GREEN}✅ Docker image built successfully${NC}"
}

# Function to deploy to Kubernetes
deploy_k8s() {
    echo -e "${YELLOW}☸️  Deploying to Kubernetes...${NC}"
    
    # Apply all manifests
    kubectl apply -f k8s/
    
    # Wait for deployment to be ready
    echo -e "${YELLOW}⏳ Waiting for deployment to be ready...${NC}"
    kubectl wait --for=condition=available --timeout=300s deployment/retell-webhook-service -n ${NAMESPACE}
    
    echo -e "${GREEN}✅ Deployment completed successfully${NC}"
}

# Function to show deployment status
show_status() {
    echo -e "${GREEN}📊 Deployment Status:${NC}"
    echo
    
    echo -e "${YELLOW}Pods:${NC}"
    kubectl get pods -n ${NAMESPACE}
    echo
    
    echo -e "${YELLOW}Services:${NC}"
    kubectl get svc -n ${NAMESPACE}
    echo
    
    echo -e "${YELLOW}Ingress:${NC}"
    kubectl get ingress -n ${NAMESPACE}
    echo
    
    echo -e "${GREEN}🎉 Webhook endpoint will be available at:${NC}"
    echo "POST /webhook/${WEBHOOK_HASH}"
    echo
    
    echo -e "${YELLOW}To view logs:${NC}"
    echo "kubectl logs -f deployment/retell-webhook-service -n ${NAMESPACE}"
    echo
    
    echo -e "${YELLOW}To test health endpoint:${NC}"
    echo "kubectl port-forward svc/retell-webhook-service 8080:80 -n ${NAMESPACE}"
    echo "curl http://localhost:8080/health"
}

# Main deployment flow
main() {
    echo -e "${GREEN}Starting deployment process...${NC}"
    echo
    
    # Check if this is a fresh deployment or update
    if kubectl get namespace ${NAMESPACE} >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠️  Namespace ${NAMESPACE} already exists. This will update the existing deployment.${NC}"
        read -p "Continue? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo -e "${RED}❌ Deployment cancelled${NC}"
            exit 1
        fi
    fi
    
    # Prompt for secrets
    prompt_for_secrets
    
    # Update secrets file
    update_secrets
    
    # Build Docker image
    build_image
    
    # Deploy to Kubernetes
    deploy_k8s
    
    # Show status
    show_status
    
    echo -e "${GREEN}🎉 Deployment completed successfully!${NC}"
}

# Run main function
main "$@"