#!/bin/bash
# Deploy pgAdmin to Cloud Run with IAP
# Reference: ../ugs-ucrc-asset-management/CLOUD_RUN_DEPLOYMENT.md

set -e

# Configuration
export PROJECT_ID="ut-dnr-ugs-mappingdb-prod"
export REGION="us-central1"
export SERVICE_NAME="pgadmin"

# VPC Configuration (from shared infrastructure)
VPC_NETWORK="projects/ut-dnr-shared-vpc-prod/global/networks/ut-dnr-shared-vpc-prod-vpc"
VPC_SUBNET="projects/ut-dnr-shared-vpc-prod/regions/us-central1/subnetworks/ut-dnr-shared-vpc-prod-subnet-uscent1"

# Get project number
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format='value(projectNumber)')

echo "=== pgAdmin Cloud Run Deployment ==="
echo "Project: $PROJECT_ID"
echo "Region: $REGION"
echo "Service: $SERVICE_NAME"
echo ""

# Step 1: Create secrets (run once)
create_secrets() {
    echo "Creating secrets in Secret Manager..."

    read -p "Enter pgAdmin admin email: " PGADMIN_EMAIL
    read -sp "Enter pgAdmin admin password: " PGADMIN_PASSWORD
    echo ""

    # Create secrets (regional for org policies)
    echo -n "$PGADMIN_EMAIL" | gcloud secrets create pgadmin-email \
        --data-file=- \
        --replication-policy=user-managed \
        --locations=$REGION \
        --project=$PROJECT_ID 2>/dev/null || echo "Secret pgadmin-email already exists"

    echo -n "$PGADMIN_PASSWORD" | gcloud secrets create pgadmin-password \
        --data-file=- \
        --replication-policy=user-managed \
        --locations=$REGION \
        --project=$PROJECT_ID 2>/dev/null || echo "Secret pgadmin-password already exists"

    # Grant access to compute service account
    for SECRET in pgadmin-email pgadmin-password; do
        gcloud secrets add-iam-policy-binding $SECRET \
            --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
            --role="roles/secretmanager.secretAccessor" \
            --project=$PROJECT_ID
    done

    echo "Secrets created successfully!"
}

# Step 2: Create GCS bucket for persistent data
create_storage() {
    echo "Creating GCS bucket for pgAdmin data..."

    BUCKET_NAME="pgadmin-data-${PROJECT_ID}"

    gcloud storage buckets create gs://${BUCKET_NAME} \
        --location=$REGION \
        --project=$PROJECT_ID 2>/dev/null || echo "Bucket already exists"

    # Grant access to compute service account
    gcloud storage buckets add-iam-policy-binding gs://${BUCKET_NAME} \
        --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
        --role="roles/storage.objectAdmin"

    echo "Storage bucket created: gs://${BUCKET_NAME}"
}

# Step 3: Deploy to Cloud Run
deploy() {
    echo "Deploying pgAdmin to Cloud Run..."

    BUCKET_NAME="pgadmin-data-${PROJECT_ID}"

    gcloud run deploy $SERVICE_NAME \
        --image=dpage/pgadmin4:latest \
        --region=$REGION \
        --platform=managed \
        --network=$VPC_NETWORK \
        --subnet=$VPC_SUBNET \
        --vpc-egress=all-traffic \
        --set-secrets="PGADMIN_DEFAULT_EMAIL=pgadmin-email:latest,PGADMIN_DEFAULT_PASSWORD=pgadmin-password:latest" \
        --set-env-vars="PGADMIN_LISTEN_PORT=8080,PGADMIN_CONFIG_SERVER_MODE=True,PGADMIN_CONFIG_MASTER_PASSWORD_REQUIRED=False" \
        --add-volume=name=pgadmin-data,type=cloud-storage,bucket=$BUCKET_NAME \
        --add-volume-mount=volume=pgadmin-data,mount-path=/var/lib/pgadmin \
        --port=8080 \
        --memory=512Mi \
        --cpu=1 \
        --min-instances=0 \
        --max-instances=2 \
        --timeout=300 \
        --execution-environment=gen2 \
        --project=$PROJECT_ID

    echo "Deployment complete!"
}

# Step 4: Enable IAP
enable_iap() {
    echo "Enabling IAP on Cloud Run service..."

    # Enable IAP
    gcloud beta run services update $SERVICE_NAME \
        --region=$REGION \
        --iap \
        --project=$PROJECT_ID

    # Grant IAP service agent invoker permission
    gcloud run services add-iam-policy-binding $SERVICE_NAME \
        --region=$REGION \
        --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-iap.iam.gserviceaccount.com" \
        --role=roles/run.invoker \
        --project=$PROJECT_ID

    echo "IAP enabled!"
}

# Step 5: Grant user access via IAP
grant_access() {
    if [ -z "$1" ]; then
        echo "Usage: $0 grant-access user@utah.gov"
        exit 1
    fi

    USER_EMAIL=$1

    echo "Granting IAP access to $USER_EMAIL..."

    gcloud beta iap web add-iam-policy-binding \
        --resource-type=cloud-run \
        --service=$SERVICE_NAME \
        --region=$REGION \
        --member="user:$USER_EMAIL" \
        --role="roles/iap.httpsResourceAccessor" \
        --project=$PROJECT_ID

    echo "Access granted to $USER_EMAIL"
}

# Step 6: Get service URL
get_url() {
    URL=$(gcloud run services describe $SERVICE_NAME \
        --region=$REGION \
        --project=$PROJECT_ID \
        --format='value(status.url)')

    echo "Service URL: $URL"
}

# Main command handling
case "${1:-}" in
    "secrets")
        create_secrets
        ;;
    "storage")
        create_storage
        ;;
    "deploy")
        deploy
        ;;
    "iap")
        enable_iap
        ;;
    "grant-access")
        grant_access "$2"
        ;;
    "url")
        get_url
        ;;
    "full")
        create_secrets
        create_storage
        deploy
        enable_iap
        get_url
        ;;
    *)
        echo "Usage: $0 {secrets|storage|deploy|iap|grant-access|url|full}"
        echo ""
        echo "Commands:"
        echo "  secrets      - Create secrets in Secret Manager"
        echo "  storage      - Create GCS bucket for persistent data"
        echo "  deploy       - Deploy to Cloud Run"
        echo "  iap          - Enable IAP on the service"
        echo "  grant-access - Grant user access (e.g., $0 grant-access user@utah.gov)"
        echo "  url          - Get the service URL"
        echo "  full         - Run all steps (secrets, storage, deploy, iap)"
        exit 1
        ;;
esac
