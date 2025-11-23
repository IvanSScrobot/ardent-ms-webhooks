# Retell Webhook Microservice

A Kubernetes-ready Node.js microservice that receives, validates, and forwards Retell webhooks.

## Features

- **Secure Webhook Validation**: Validates incoming webhooks using Retell's signature verification
- **Request Forwarding**: Forwards validated requests to a configurable target endpoint
- **Comprehensive Logging**: Logs all requests, validations, forwards, and errors to stdout
- **Kubernetes Native**: Designed for deployment in Kubernetes with proper health checks and scaling
- **Security Hardened**: Runs as non-root user with minimal privileges

## Architecture

```
Internet → Ingress → Service → Pod(s) → Target Endpoint
                                ↓
                            Logs (stdout)
```

## Environment Variables

The microservice requires the following environment variables (provided via Kubernetes secrets):

- `RETELL_API_KEY`: Your Retell API key for signature validation
- `WEBHOOK_HASH`: Secret hash used in the webhook URL path
- `FORWARD_ENDPOINT`: Target endpoint URL where validated requests are forwarded

Optional configuration (via ConfigMap):

- `SITE_NAME`: Site name for logging (default: localhost)
- `PORT`: Port to listen on (default: 3000)
- `NODE_ENV`: Environment (default: development)
- `ONLY_WHITELISTED_SOURCES`: Enable IP allowlist checking (default: false)
- `RETELL_ALLOWED_IPS`: Comma-separated list of allowed Retell IP addresses
- `LOG_FULL_WEBHOOK_REQUESTS`: Set to `"true"` to log the full incoming webhook (method, path, query, headers, body) before validation (default: `"true"` when unset, set to `"false"` to disable)
- `USE_WEBHOOK_DATA_EXTRACTION`: Set to `"true"` to remove the large `transcript_object` array before forwarding (default: `"true"` when unset, set to `"false"` to forward the complete original body without modifications)

## Webhook Endpoint

The service exposes webhooks at:
```
POST /webhook/<webhook_hash>
```

Where `<webhook_hash>` is read from the `WEBHOOK_HASH` environment variable.

## Request Flow

1. **Receive**: Incoming POST request to webhook endpoint
2. **Log**: Log request details (IP, headers, body size). If `LOG_FULL_WEBHOOK_REQUESTS=true`, also log the full request payload before any validation
3. **IP Check**: If `ONLY_WHITELISTED_SOURCES=true`, verify client IP is in allowlist
4. **Validate**: Verify `x-retell-signature` header using HMAC-SHA256
5. **Process**: If `USE_WEBHOOK_DATA_EXTRACTION=true` (default), remove the large `transcript_object` array to reduce payload size
6. **Forward**: If valid, forward processed or original request to target endpoint
7. **Respond**: Return 204 No Content to acknowledge receipt
8. **Log**: Log all outcomes (success, validation failure, forward failure, IP rejection)

## IP Allowlist Configuration

The microservice supports IP allowlist functionality to restrict webhook access to known Retell IP addresses:

### Configuration

- **`ONLY_WHITELISTED_SOURCES`**: Set to `"true"` to enable IP allowlist checking (default: `"false"`)
- **`RETELL_ALLOWED_IPS`**: Comma-separated list of allowed IP addresses (e.g., `"52.14.14.14,52.15.15.15"`)

### Behavior

- When `ONLY_WHITELISTED_SOURCES=false` (default): All IPs are allowed
- When `ONLY_WHITELISTED_SOURCES=true` and `RETELL_ALLOWED_IPS` is empty: All IPs are allowed
- When `ONLY_WHITELISTED_SOURCES=true` and `RETELL_ALLOWED_IPS` contains IPs: Only listed IPs are allowed

### Example Configuration

```yaml
# In k8s/secrets.yaml ConfigMap
data:
  ONLY_WHITELISTED_SOURCES: "true"
  RETELL_ALLOWED_IPS: "52.14.14.14,52.15.15.15,34.210.210.210"
```

Requests from non-whitelisted IPs will receive a `403 Forbidden` response and be logged.

## Deployment

### Prerequisites

- Kubernetes cluster
- Docker registry access
- kubectl configured

### Build and Deploy

1. **Build Docker image**:
```bash
docker build -t your-registry/retell-webhook-microservice:latest .
docker push your-registry/retell-webhook-microservice:latest
```

2. **Update secrets** in `k8s/secrets.yaml`:
```bash
# Encode your actual values
echo -n "your-actual-retell-api-key" | base64
echo -n "your-actual-webhook-hash" | base64
echo -n "https://your-actual-target-endpoint.com/webhook" | base64
```

3. **Update configuration** in `k8s/secrets.yaml` and `k8s/service.yaml`:
   - Replace base64 encoded values in secrets
   - Update domain name in ingress
   - Update image name in deployment

4. **Deploy to Kubernetes**:
```bash
kubectl apply -f k8s/
```

### Verify Deployment

```bash
# Check pods
kubectl get pods -n retell-webhooks

# Check logs
kubectl logs -f deployment/retell-webhook-service -n retell-webhooks

# Check service
kubectl get svc -n retell-webhooks

# Test health endpoint
kubectl port-forward svc/retell-webhook-service 8080:80 -n retell-webhooks
curl http://localhost:8080/health
```

## Monitoring

The service provides:

- **Health Check**: `GET /health` endpoint for liveness/readiness probes
- **Structured Logging**: JSON formatted logs with timestamps and request IDs
- **Metrics Ready**: CPU/memory metrics for HPA scaling

## Security Features

- Non-root container execution
- Read-only root filesystem
- Dropped capabilities
- Resource limits
- Network policies ready
- Secret-based configuration

## Scaling

The service includes Horizontal Pod Autoscaler (HPA) configuration:
- Min replicas: 2
- Max replicas: 10
- CPU threshold: 70%
- Memory threshold: 80%

## Troubleshooting

### Common Issues

1. **Invalid Signature Errors**:
   - Verify `RETELL_API_KEY` is correct
   - Check webhook URL matches expected format
   - Ensure request body is not modified in transit

2. **Forward Failures**:
   - Verify `FORWARD_ENDPOINT` is accessible
   - Check target endpoint accepts the forwarded format
   - Review network policies and firewall rules

3. **Pod Startup Issues**:
   - Check secret values are properly base64 encoded
   - Verify image is accessible from cluster
   - Review resource limits and node capacity

### Logs

All operations are logged with structured data:

```json
{
  "timestamp": "2024-01-01T12:00:00.000Z",
  "level": "INFO",
  "message": "Incoming webhook request",
  "requestId": "abc123",
  "clientIP": "10.0.0.1",
  "headers": {...},
  "bodySize": 1024
}
```

Set `LOG_FULL_WEBHOOK_REQUESTS=true` to emit a pre-validation log entry with the full request (method, path, query, headers, body) to aid debugging. It defaults to `"true"` when not provided; set `"false"` to disable in production to avoid noisy logs.

## Development

### Local Development

1. Install dependencies:
```bash
npm install
```

2. Set environment variables:
```bash
export RETELL_API_KEY="your-api-key"
export WEBHOOK_HASH="your-hash"
export FORWARD_ENDPOINT="http://localhost:4000/webhook"
```

3. Run in development mode:
```bash
npm run dev
```

### Testing

Test the webhook endpoint:
```bash
curl -X POST http://localhost:3000/webhook/your-hash \
  -H "Content-Type: application/json" \
  -H "x-retell-signature: sha256=valid-signature" \
  -d '{"event": "test", "call": {"call_id": "123"}}'
```

## Signature Validation

The service validates Retell webhooks using HMAC-SHA256:

```javascript
const expectedSignature = crypto
  .createHmac('sha256', RETELL_API_KEY)
  .update(JSON.stringify(requestBody))
  .digest('hex');

const isValid = signature === `sha256=${expectedSignature}`;
```

## License

MIT
