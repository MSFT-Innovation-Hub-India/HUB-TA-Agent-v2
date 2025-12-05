# TAB-Agent-Bot Deployment Scripts

This folder contains automated deployment scripts for deploying the TAB-Agent-Bot solution to Azure.

## Prerequisites

1. **Azure CLI** - Must be installed and configured
   ```powershell
   # Verify Azure CLI is installed
   az --version
   
   # Login to Azure
   az login
   
   # Set the target subscription (if you have multiple)
   az account set --subscription "<subscription-name-or-id>"
   ```

2. **Docker Desktop** - Must be installed and running (for Container App deployment)

3. **RBAC Access** - User must have appropriate permissions to:
   - Create Resource Groups
   - Create Storage Accounts
   - Create Container Registries
   - Create Container Apps
   - Create Bot Services
   - Create Application Insights
   - Create and manage Blob Containers
   - Create Entra ID App Registrations

### Azure CLI Extensions

Some scripts require Azure CLI extensions that may not be installed by default. When you run these scripts, you may see prompts like:

```
The command requires the extension application-insights. Do you want to install it now? 
The command will continue to run after the extension is installed. (Y/n): y
```

**Simply press `Y` and Enter to install the extension.** The script will continue automatically.

To avoid these prompts in the future, run this command once:
```powershell
az config set extension.use_dynamic_install=yes_without_prompt
```

This will automatically install any required extensions without prompting.

## Configuration

Before running the deployment scripts, rename `input-config-begin` file to `input-config` file in the `deployment` folder:

```
hub-city=<your-hub-city-name>
az-region=<azure-region>
az-tab-rg=<resource-group-name>
host-entra-tenant-id=<CORP Entra Tenant ID used in Teams>
az-subscription-id=<Your Azure Subscription ID>
```

### Configuration Values

| Config Key | Description | Example |
|------------|-------------|---------|
| `hub-city` | The Innovation Hub city for this deployment | `bengaluru`, `New York`, `Tokyo` |
| `az-region` | Azure region for resource deployment | `southindia`, `eastus`, `westeurope` |
| `az-tab-rg` | Resource Group name for TAB-Agent resources | `tab-agent-rg` |

### Hub City Name Normalization

The hub city name is automatically normalized to match the application logic:
- All spaces and special characters are removed
- Converted to lowercase

Examples:
- `New York` → `newyork`
- `Bengaluru` → `bengaluru`

## Deployment Scripts

Run these scripts in order (01 → 02 → 03 → 04 → 05):

### 01-deploy-blob-storage.ps1

Deploys Azure Blob Storage infrastructure including:
- Creates a new Resource Group
- Creates a Storage Account (Standard_LRS, StorageV2)
- Creates containers: `agenda-docs`, `golden-repo`, `hub-master`, `tab-state`
- Uploads master data and documents to the containers

```powershell
.\01-deploy-blob-storage.ps1
.\01-deploy-blob-storage.ps1 -WhatIf  # Preview mode
```

### 02-deploy-container-registry.ps1

Deploys Azure Container Registry:
- Creates an ACR with admin user enabled
- Saves ACR credentials to input-config

```powershell
.\02-deploy-container-registry.ps1
.\02-deploy-container-registry.ps1 -WhatIf  # Preview mode
```

### 03-deploy-bot-service.ps1

Deploys Azure Bot Service (run BEFORE Container App):
- Creates Microsoft Entra ID App Registration (Single Tenant)
- Creates Service Principal (Enterprise Application) for the App Registration
- Generates client secret (25-day validity)
- Creates Azure Bot resource with placeholder endpoint
- Saves Bot credentials to input-config

```powershell
.\03-deploy-bot-service.ps1
.\03-deploy-bot-service.ps1 -WhatIf  # Preview mode
.\03-deploy-bot-service.ps1 -ForceNewSecret  # Generate new secret
```

### 04-deploy-container-app.ps1

Deploys Azure Container App with Bot credentials:
- Builds and pushes Docker image to ACR
- Creates Log Analytics Workspace
- Creates Container Apps Environment
- Creates Container App with Bot environment variables
- Updates Azure Bot messaging endpoint with Container App URL

```powershell
.\04-deploy-container-app.ps1
.\04-deploy-container-app.ps1 -WhatIf  # Preview mode
.\04-deploy-container-app.ps1 -SkipBuild  # Use existing image
```

### 05-deploy-appinsights.ps1

Deploys Azure Application Insights:
- Creates Application Insights resource linked to Log Analytics
- Saves connection string to input-config

> **Note:** This script may prompt to install the `application-insights` Azure CLI extension. Press `Y` to continue.

```powershell
.\05-deploy-appinsights.ps1
.\05-deploy-appinsights.ps1 -WhatIf  # Preview mode
```

### 06-deploy-azure-openai.ps1

Deploys Azure OpenAI Service:
- Creates Azure OpenAI resource
- Deploys GPT-4o model
- Saves endpoint and deployment name to input-config

```powershell
.\06-deploy-azure-openai.ps1
.\06-deploy-azure-openai.ps1 -WhatIf  # Preview mode
```

### 07-setup-managed-identity.ps1

Sets up Managed Identity and RBAC:
- Enables system-assigned managed identity on Container App
- Assigns Storage Account roles (Contributor, Blob Data Contributor, Blob Data Reader)
- Assigns Azure OpenAI roles (Cognitive Services Contributor, OpenAI Contributor)

```powershell
.\07-setup-managed-identity.ps1
.\07-setup-managed-identity.ps1 -WhatIf  # Preview mode
```

### 08-upload-assistant-document.ps1

Uploads assistant document to Azure OpenAI:
- Uploads `Innovation Hub Agenda Format.docx` to Azure OpenAI Files API
- Saves file ID to input-config for assistant configuration
- Creates `hub_assistant_file_ids` JSON mapping

```powershell
.\08-upload-assistant-document.ps1
.\08-upload-assistant-document.ps1 -WhatIf  # Preview mode
.\08-upload-assistant-document.ps1 -ForceUpload  # Force re-upload even if exists
```

### 09-configure-container-app-env.ps1

Configures all environment variables on the Container App:
- Sets bot credentials (TENANT_ID, CLIENT_ID, CLIENT_SECRET, HOST_TENANT_ID)
- Sets Azure OpenAI settings (endpoint, deployment, API version)
- Sets hub configuration (hub_cities, hub_assistant_file_ids, file_ids)
- Sets blob storage settings (account, containers, resource group)
- Sets logging and monitoring (log_level, Application Insights)

```powershell
.\09-configure-container-app-env.ps1
.\09-configure-container-app-env.ps1 -WhatIf  # Preview mode
```

### Quick Start - Full Deployment

```powershell
cd deployment/deployment-scripts

# Run all scripts in order
.\01-deploy-blob-storage.ps1
.\02-deploy-container-registry.ps1
.\03-deploy-bot-service.ps1
.\04-deploy-container-app.ps1
.\05-deploy-appinsights.ps1
.\06-deploy-azure-openai.ps1
.\07-setup-managed-identity.ps1
.\08-upload-assistant-document.ps1
.\09-configure-container-app-env.ps1
```

### Updating Code After Deployment

When you update the application code and need to redeploy:

```powershell
cd deployment/deployment-scripts

# Rebuild Docker image, push to ACR, and update Container App
.\04-deploy-container-app.ps1

# If environment variables changed, also run:
.\09-configure-container-app-env.ps1
```

The script will:
1. Build a new Docker image with a timestamp tag
2. Push the image to Azure Container Registry
3. Update the Container App with the new image

Use `-SkipBuild` flag to update Container App without rebuilding the image.

### Updating Blob Storage Documents

When you add or modify documents in the `blob-store` folder:

```powershell
# Re-run to upload new/updated files (uses --overwrite)
.\01-deploy-blob-storage.ps1
```

## Folder Structure

```
deployment/
├── input-config              # Configuration file (updated by scripts)
├── blob-store/               # Master data to upload to blob storage
│   ├── agenda-docs/
│   ├── golden-repo/
│   │   └── hub-<city>/
│   │       └── documents/
│   │           └── *.md (agenda documents)
│   ├── hub-master/
│   │   └── hub-<city>.md
│   └── tab-state/
└── deployment-scripts/       # Deployment automation scripts
    ├── README.md
    ├── 01-deploy-blob-storage.ps1
    ├── 02-deploy-container-registry.ps1
    ├── 03-deploy-bot-service.ps1
    ├── 04-deploy-container-app.ps1
    ├── 05-deploy-appinsights.ps1
    ├── 06-deploy-azure-openai.ps1
    ├── 07-setup-managed-identity.ps1
    ├── 08-upload-assistant-document.ps1
    └── 09-configure-container-app-env.ps1
```

## Input Config Reference

The `input-config` file is populated by the scripts. Here are all the keys:

| Config Key | Set By | Description |
|------------|--------|-------------|
| `hub-city` | User | Innovation Hub city name |
| `az-region` | User | Azure region (e.g., `southindia`) |
| `az-tab-rg` | User | Resource Group name |
| `az-tab-storage-account` | Script 01 | Storage Account name |
| `az-tab-acr-name` | Script 02 | Container Registry name |
| `az-tab-acr-login-server` | Script 02 | ACR login server URL |
| `az-tab-acr-username` | Script 02 | ACR admin username |
| `az-tab-acr-password` | Script 02 | ACR admin password |
| `az-tab-bot-name` | Script 03 | Azure Bot name |
| `az-tab-bot-app-id` | Script 03 | Bot App ID (Client ID) |
| `az-tab-bot-tenant-id` | Script 03 | Bot Tenant ID |
| `az-tab-bot-client-secret` | Script 03 | Bot Client Secret |
| `az-tab-log-analytics-name` | Script 04 | Log Analytics Workspace name |
| `az-tab-containerapp-name` | Script 04 | Container App name |
| `az-tab-containerapp-url` | Script 04 | Container App URL |
| `az-tab-bot-messaging-endpoint` | Script 04 | Bot messaging endpoint |
| `az-tab-containerapp-identity-principal-id` | Script 07 | Container App Managed Identity Principal ID |
| `az-tab-appinsights-name` | Script 05 | Application Insights name |
| `az-tab-appinsights-connection-string` | Script 05 | App Insights connection string |
| `az-tab-openai-name` | Script 06 | Azure OpenAI resource name |
| `az-tab-openai-endpoint` | Script 06 | Azure OpenAI endpoint URL |
| `az-tab-openai-key` | Script 06 | Azure OpenAI key |
| `az-tab-openai-deployment` | Script 06 | Azure OpenAI model deployment name |
| `hub-doc-template-fileid` | Script 08 | Azure OpenAI file ID for assistant document |
| `hub_assistant_file_ids` | Script 08 | JSON map of hub city to file IDs |

## Troubleshooting

### Common Issues

1. **Azure CLI Extension Prompts**
   - Some commands require extensions (e.g., `application-insights`)
   - Press `Y` when prompted to install
   - Or run: `az config set extension.use_dynamic_install=yes_without_prompt`

2. **Storage Account Name Already Exists**
   - Storage account names must be globally unique
   - The script uses city name; if collision occurs, choose a different name

3. **Permission Denied**
   - Ensure you have the required RBAC roles on the subscription
   - Verify you're logged into the correct Azure account: `az account show`

4. **Region Not Available**
   - Verify the region name is valid: `az account list-locations -o table`
   - Use format without hyphens (e.g., `southindia` not `south-india`)

5. **Docker Build Fails**
   - Ensure Docker Desktop is running
   - Check Dockerfile syntax

6. **Bot Messaging Endpoint Issues**
   - Ensure Container App is deployed and accessible
   - Verify the endpoint ends with `/api/messages`

### Getting Help

If you encounter issues, check:
- Azure CLI logs
- Azure Portal for resource status
- Ensure input-config has correct values
