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

2. **RBAC Access** - User must have appropriate permissions to:
   - Create Resource Groups
   - Create Storage Accounts
   - Create and manage Blob Containers
   - Upload blobs

## Configuration

Before running the deployment scripts, update the `input-config` file in the `deployment` folder:

```
hub-city=<your-hub-city-name>
az-region=<azure-region>
az-tab-rg=<resource-group-name>
```

### Configuration Values

| Config Key | Description | Example |
|------------|-------------|---------|
| `hub-city` | The Innovation Hub city for this deployment | `bengaluru`, `New York`, `Silicon Valley` |
| `az-region` | Azure region for resource deployment | `south-india`, `eastus`, `westeurope` |
| `az-tab-rg` | Resource Group name for TAB-Agent resources | `tab-agent-rg` |

### Hub City Name Normalization

The hub city name is automatically normalized to match the application logic:
- All spaces and special characters are removed
- Converted to lowercase

Examples:
- `New York` → `newyork`
- `Silicon Valley` → `siliconvalley`
- `Bengaluru` → `bengaluru`

## Deployment Scripts

### 01-deploy-blob-storage.ps1

Deploys Azure Blob Storage infrastructure including:
- Creates a new Resource Group
- Creates a Storage Account (Standard_LRS, StorageV2)
- Creates containers: `agenda-docs`, `golden-repo`, `hub-master`, `tab-state`
- Uploads master data and documents to the containers

#### Usage

```powershell
# Navigate to the deployment-scripts folder
cd deployment/deployment-scripts

# Run the script
.\01-deploy-blob-storage.ps1

# Or run with WhatIf to see what would happen without making changes
.\01-deploy-blob-storage.ps1 -WhatIf
```

#### Output

The script generates a `deployment-output.config` file in the `deployment` folder containing:
- `storage-account-name` - The created storage account name
- `normalized-hub-city` - The normalized hub city name

This file is used by subsequent deployment scripts.

## Folder Structure

```
deployment/
├── input-config              # Input configuration for deployment
├── deployment-output.config  # Auto-generated output from scripts
├── blob-store/               # Master data to upload to blob storage
│   ├── agenda-docs/
│   ├── golden-repo/
│   │   ├── agenda_mapping.md
│   │   └── *.md (agenda documents)
│   ├── hub-master/
│   │   └── hub-<city>.md
│   └── tab-state/
└── deployment-scripts/       # Deployment automation scripts
    ├── README.md
    └── 01-deploy-blob-storage.ps1
```

## Troubleshooting

### Common Issues

1. **Storage Account Name Already Exists**
   - Storage account names must be globally unique
   - The script generates a random suffix, but if collision occurs, re-run the script

2. **Permission Denied**
   - Ensure you have the required RBAC roles on the subscription
   - Verify you're logged into the correct Azure account: `az account show`

3. **Region Not Available**
   - Verify the region name is valid: `az account list-locations -o table`

### Getting Help

If you encounter issues, check:
- Azure CLI logs
- Azure Portal for resource status
- Ensure input-config has correct values
