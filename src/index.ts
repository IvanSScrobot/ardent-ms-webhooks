import express, { Request, Response } from 'express';
import axios from 'axios';
import { RetellClient } from 'retell-sdk';
import { transcode } from 'buffer';

const app = express();
app.use(express.json({ limit: '50mb' }));

const RETELL_API_KEY = process.env.RETELL_API_KEY;
const DISABLE_RETELL_SIGNATURE_VERIFICATION = process.env.DISABLE_RETELL_SIGNATURE_VERIFICATION === 'true' || process.env.DISABLE_RETELL_SIGNATURE_VERIFICATION === 'True';
const WEBHOOK_HASH = process.env.WEBHOOK_HASH;
const FORWARD_ENDPOINT = process.env.FORWARD_ENDPOINT;
const PORT = process.env.PORT || 3000;
const SITE_NAME = process.env.SITE_NAME || 'localhost';
const TARGET_ENDPOINT_TIMEOUT = parseInt(process.env.TARGET_ENDPOINT_TIMEOUT || '600000'); // Default 10 minutes
const LOG_FULL_WEBHOOK_REQUESTS = (() => {
    const value = process.env.LOG_FULL_WEBHOOK_REQUESTS;
    if (value === undefined) {
        return true; // Default to detailed logging when unset
    }
    return value === 'true' || value === 'True';
})();

// IP allowlist configuration
const RETELL_ALLOWED_IPS = process.env.RETELL_ALLOWED_IPS ? process.env.RETELL_ALLOWED_IPS.split(',').map(ip => ip.trim()) : [];
const ONLY_WHITELISTED_SOURCES = process.env.ONLY_WHITELISTED_SOURCES === 'true' || process.env.ONLY_WHITELISTED_SOURCES === 'True';

// const shouldLogSignatures = process.env.LOG_SIGNATURES === 'true' || process.env.LOG_SIGNATURES === 'True';

// Validate required environment variables
if (!RETELL_API_KEY) {
    console.error('RETELL_API_KEY environment variable is required');
    process.exit(1);
}

if (!WEBHOOK_HASH) {
    console.error('WEBHOOK_HASH environment variable is required');
    process.exit(1);
}

if (!FORWARD_ENDPOINT) {
    console.error('FORWARD_ENDPOINT environment variable is required');
    process.exit(1);
}

// Logging utility
const logger = {
    info: (message: string, data?: any) => {
        const timestamp = new Date().toISOString();
        console.log(`[${timestamp}] INFO: ${message}`, data ? JSON.stringify(data, null, 2) : '');
    },
    error: (message: string, data?: any) => {
        const timestamp = new Date().toISOString();
        console.error(`[${timestamp}] ERROR: ${message}`, data ? JSON.stringify(data, null, 2) : '');
    },
    warn: (message: string, data?: any) => {
        const timestamp = new Date().toISOString();
        console.warn(`[${timestamp}] WARN: ${message}`, data ? JSON.stringify(data, null, 2) : '');
    }
};

const logDetailedIncomingRequest = (req: Request, requestId: string) => {
    if (!LOG_FULL_WEBHOOK_REQUESTS) {
        return;
    }

    logger.info('Detailed incoming webhook request (pre-validation)', {
        requestId,
        method: req.method,
        path: req.path,
        url: req.originalUrl,
        query: req.query,
        headers: req.headers,
        body: req.body
    });
};

// IP allowlist checking function
const isIPAllowed = (clientIP: string): boolean => {
    if (!ONLY_WHITELISTED_SOURCES) {
        return true; // If allowlist is disabled, allow all IPs
    }

    if (RETELL_ALLOWED_IPS.length === 0) {
        return true; // If no IPs configured, allow all
    }

    // Check if client IP is in the allowlist
    return RETELL_ALLOWED_IPS.includes(clientIP);
};

// Health check endpoint
app.get('/health', (req: Request, res: Response) => {
    logger.info('Health check requested');
    res.status(200).json({ status: 'healthy', timestamp: new Date().toISOString() });
});

/**
 * Extracts relevant data from the webhook body for processing.
 * @param {Object} body - The webhook request body.
 * @returns {Object} Extracted data including transcript, dynamic variables, survey ID, call ID, and metadata.
 */
function extractWebhookData(body: any) {
    logger.info('Extracting webhook data');

    const { call } = body;

    const extractedData = {
        transcript: call.transcript,
        dynamicVariables: call.retell_llm_dynamic_variables || {},
        surveyId: call.metadata.survey_id,
        callId: call.call_id,
        metadata: {
            event: body.event,
            callType: call.call_type,
            direction: call.direction,
            fromNumber: call.from_number,
            toNumber: call.to_number,
            startTimestamp: call.start_timestamp,
            endTimestamp: call.end_timestamp,
            disconnectionReason: call.disconnection_reason
        }
    };

    logger.info('Webhook data extracted successfully before sending to Retell Processor', {
        surveyId: extractedData.surveyId,
        callId: extractedData.callId,
        transcriptLength: extractedData.transcript.length,
        transcript: extractedData.transcript, //substring(0, 100) + '...', // Log first 100 chars for brevity
        dynamicVariableKeys: Object.keys(extractedData.dynamicVariables),
        event: extractedData.metadata.event,
        callType: extractedData.metadata.callType,
        direction: extractedData.metadata.direction
    });

    return extractedData;
}

// Main webhook endpoint
app.post(`/webhook/${WEBHOOK_HASH}`, async (req: Request, res: Response) => {
    const requestId = Math.random().toString(36).substring(7);
    const clientIP = req.headers['x-original-forwarded-for'] as string || 'unknown';

    logDetailedIncomingRequest(req, requestId);

    logger.info(`Incoming webhook request`, {
        requestId,
        clientIP,
        headers: req.headers,
        bodySize: JSON.stringify(req.body).length
    });

    // Check IP allowlist before processing
    if (!isIPAllowed(clientIP)) {
        logger.warn(`Request from non-whitelisted IP rejected`, {
            requestId,
            clientIP,
            allowedIPs: RETELL_ALLOWED_IPS,
            onlyWhitelistedSources: ONLY_WHITELISTED_SOURCES
        });
        return res.status(403).json({ error: 'IP not allowed' });
    }

    try {
        // Validate Retell signature
        const signature = req.headers['x-retell-signature'] as string;

        if (!signature) {
            logger.warn(`Missing x-retell-signature header`, { requestId });
            return res.status(400).json({ error: 'Missing x-retell-signature header' });
        }

        if (DISABLE_RETELL_SIGNATURE_VERIFICATION) {
            logger.info(`Signature verification is disabled`, { requestId });
            // If signature verification is disabled, proceed without validation
            // return res.status(204).send();
        }
        else {
            // Verify Retell signature using official SDK
            const retellClient = new RetellClient();
            const isValidSignature = retellClient.verify(
                JSON.stringify(req.body),
                RETELL_API_KEY!,
                signature
            );

            if (!isValidSignature) {
                logger.error(`Invalid Retell signature`, {
                    requestId,
                    signature: signature.substring(0, 10) + '...' // Log partial signature for debugging
                });
                return res.status(401).json({ error: 'Invalid signature' });
            }

            logger.info(`Retell signature validation successful`, { requestId });

        }
        // Extract event data
        const { event, call } = req.body;
        logger.info(`Processing webhook event`, {
            requestId,
            eventType: event,
            callId: call?.call_id || 'unknown'
        });
        const { transcript, callId } = extractWebhookData(req.body);

        // Acknowledge the receipt of the event immediately after successful verification
        res.status(204).send();
        logger.info(`Acknowledged webhook to Retell`, { requestId });

        // Forward the request to the target endpoint asynchronously
        setImmediate(async () => {
            try {
                logger.info(`Forwarding request to target endpoint`, {
                    requestId,
                    targetEndpoint: FORWARD_ENDPOINT,
                    timeout: TARGET_ENDPOINT_TIMEOUT
                });

                const forwardResponse = await axios.post(FORWARD_ENDPOINT!, req.body, {
                    headers: {
                        'Content-Type': 'application/json',
                        'X-Original-Signature': signature,
                        'X-Request-ID': requestId,
                        // Forward original headers except host and content-length
                        ...Object.fromEntries(
                            Object.entries(req.headers).filter(([key]) =>
                                !['host', 'content-length', 'connection'].includes(key.toLowerCase())
                            )
                        )
                    },
                    timeout: TARGET_ENDPOINT_TIMEOUT
                });

                logger.info(`Successfully forwarded request`, {
                    requestId,
                    targetStatus: forwardResponse.status,
                    targetStatusText: forwardResponse.statusText
                });

            } catch (forwardError: any) {
                logger.error(`Failed to forward request`, {
                    requestId,
                    error: forwardError.message,
                    targetEndpoint: FORWARD_ENDPOINT,
                    status: forwardError.response?.status,
                    statusText: forwardError.response?.statusText,
                    timeout: TARGET_ENDPOINT_TIMEOUT
                });
            }
        });

    } catch (error: any) {
        logger.error(`Webhook processing failed`, {
            requestId,
            error: error.message,
            stack: error.stack
        });

        res.status(500).json({ error: 'Internal server error' });
    }
});

// Catch-all for invalid webhook paths
app.post('/webhook/*', (req: Request, res: Response) => {
    const requestId = Math.random().toString(36).substring(7);
    logger.warn(`Invalid webhook path accessed`, {
        requestId,
        path: req.path,
        clientIP: req.headers['x-original-forwarded-for'] as string || 'unknown'
    });
    res.status(404).json({ error: 'Invalid path' });
});

// Start server
app.listen(PORT, () => {
    logger.info(`Retell webhook microservice started`, {
        port: PORT,
        siteName: SITE_NAME,
        webhookPath: `/webhook/${WEBHOOK_HASH}`,
        forwardEndpoint: FORWARD_ENDPOINT,
        targetEndpointTimeout: `${TARGET_ENDPOINT_TIMEOUT}ms (${TARGET_ENDPOINT_TIMEOUT / 60000} minutes)`,
        nodeEnv: process.env.NODE_ENV || 'development',
        ipAllowlistEnabled: ONLY_WHITELISTED_SOURCES,
        allowedIPsCount: RETELL_ALLOWED_IPS.length,
        allowedIPs: ONLY_WHITELISTED_SOURCES ? RETELL_ALLOWED_IPS : 'disabled'
    });
});

// Graceful shutdown
process.on('SIGTERM', () => {
    logger.info('SIGTERM received, shutting down gracefully');
    process.exit(0);
});

process.on('SIGINT', () => {
    logger.info('SIGINT received, shutting down gracefully');
    process.exit(0);
});
