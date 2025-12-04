#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Builds, pushes Docker image and deploys Azure Container App for TAB-Agent-Bot solution.

.DESCRIPTION
    This script automates:
    - Building Docker image from the project Dockerfile
    - Pushing image to Azure Container Registry
    - Creating Azure Container Apps Environment (if not exists)
    - Creating/Updating Azure Container App with the new image
    - Configuring Bot credentials as environment variables
    - Updating the Azure Bot's messaging endpoint with the Container App URL

.NOTES
    Prerequisites:
    - Azure CLI installed and configured
    - Docker Desktop installed and running
    - Run scripts 01, 02, and 03 before this script
    - Run this script from the 'deployment-scripts' folder
    
    Usage:
    - First deployment: Creates environment and container app
    - Subsequent runs: Builds new image and updates container app
    
    Idempotency:
    - Script can be re-run safely; existing resources will be reused
#>

param(
    [switch]$WhatIf = $false,  # Set to $true to see what would happen without making changes
    [switch]$SkipBuild = $false  # Set to $true to skip Docker build (use existing image)
)

# ============================================================================
# CONFIGURATION - Read from input-config
# ============================================================================

$scriptDir = $PSScriptRoot
$deploymentDir = Split-Path -Parent $scriptDir
$projectDir = Split-Path -Parent $deploymentDir
$inputConfigPath = Join-Path $deploymentDir "input-config"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "TAB-Agent-Bot - Container App Deployment" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Read configuration from input-config
Write-Host "Reading configuration from: $inputConfigPath" -ForegroundColor Yellow

if (-not (Test-Path $inputConfigPath)) {
    Write-Error "Configuration file not found: $inputConfigPath"
    exit 1
}

$config = @{}
Get-Content $inputConfigPath | ForEach-Object {
    if ($_ -match "^([^#][^=]*)=(.*)$") {
        $config[$matches[1].Trim()] = $matches[2].Trim()
    }
}

$azRegion = $config["az-region"]
$azResourceGroup = $config["az-tab-rg"]
$hubCity = $config["hub-city"]
$acrName = $config["az-tab-acr-name"]
$acrLoginServer = $config["az-tab-acr-login-server"]
$acrUsername = $config["az-tab-acr-username"]
$acrPassword = $config["az-tab-acr-password"]
$storageAccountName = $config["az-tab-storage-account"]

# Bot credentials from 03-deploy-bot-service.ps1
$botName = $config["az-tab-bot-name"]
$botAppId = $config["az-tab-bot-app-id"]
$botTenantId = $config["az-tab-bot-tenant-id"]
$botClientSecret = $config["az-tab-bot-client-secret"]

Write-Host "  Azure Region: $azRegion" -ForegroundColor Green
Write-Host "  Resource Group: $azResourceGroup" -ForegroundColor Green
Write-Host "  Hub City: $hubCity" -ForegroundColor Green
Write-Host "  ACR: $acrLoginServer" -ForegroundColor Green
Write-Host "  Storage Account: $storageAccountName" -ForegroundColor Green
Write-Host "  Bot Name: $botName" -ForegroundColor Green
Write-Host "  Bot App ID: $botAppId" -ForegroundColor Green
Write-Host ""

# Validate required configurations
if (-not $azRegion -or -not $azResourceGroup -or -not $hubCity -or -not $acrName) {
    Write-Error "Missing required configuration. Please run 01-deploy-blob-storage.ps1 and 02-deploy-container-registry.ps1 first."
    exit 1
}

if (-not $botAppId -or -not $botClientSecret) {
    Write-Error "Missing Bot credentials. Please run 03-deploy-bot-service.ps1 first."
    exit 1
}

# ============================================================================
# Normalize Hub City Name and Generate Resource Names
# ============================================================================

$normalizedHubCity = ($hubCity -replace '[^a-zA-Z0-9]', '').ToLower()
Write-Host "  Normalized Hub City: $normalizedHubCity" -ForegroundColor Green

# Resource names
$logAnalyticsWorkspaceName = "az-$normalizedHubCity-log-analytics"
$containerAppEnvName = "az-$normalizedHubCity-containerapp-env"
$containerAppName = "az-$normalizedHubCity-containerapp"
$imageName = "tab-agent-bot"

# Generate timestamp for image tag
$timestamp = Get-Date -Format "yyyy-MM-dd_HHmm"
$fullImageName = "$acrLoginServer/${imageName}:$timestamp"

Write-Host "  Log Analytics Workspace: $logAnalyticsWorkspaceName" -ForegroundColor Green
Write-Host "  Container App Environment: $containerAppEnvName" -ForegroundColor Green
Write-Host "  Container App: $containerAppName" -ForegroundColor Green
Write-Host "  Image: $fullImageName" -ForegroundColor Green
Write-Host ""

# ============================================================================
# STEP 1: Login to ACR
# ============================================================================

Write-Host "STEP 1: Logging in to Azure Container Registry" -ForegroundColor Cyan

if ($WhatIf) {
    Write-Host "  [WhatIf] Would run: az acr login --name $acrName" -ForegroundColor Magenta
} else {
    az acr login --name $acrName
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to login to ACR"
        exit 1
    }
    Write-Host "  Logged in to ACR successfully." -ForegroundColor Green
}

Write-Host ""

# ============================================================================
# STEP 2: Build and Push Docker Image
# ============================================================================

Write-Host "STEP 2: Building and Pushing Docker Image" -ForegroundColor Cyan

if ($SkipBuild) {
    Write-Host "  Skipping build (--SkipBuild flag set)" -ForegroundColor Yellow
    # Use the latest image from ACR
    $latestImage = az acr repository show-tags --name $acrName --repository $imageName --top 1 --orderby time_desc -o tsv 2>$null
    if ($latestImage) {
        $fullImageName = "$acrLoginServer/${imageName}:$latestImage"
        Write-Host "  Using latest image: $fullImageName" -ForegroundColor Green
    } else {
        Write-Error "No existing image found in ACR. Please run without --SkipBuild flag."
        exit 1
    }
} else {
    # Change to project directory for Docker build
    $originalDir = Get-Location
    Set-Location $projectDir
    
    Write-Host "  Building Docker image: $fullImageName" -ForegroundColor Yellow
    Write-Host "  Project directory: $projectDir" -ForegroundColor Yellow
    
    if ($WhatIf) {
        Write-Host "  [WhatIf] Would run: docker build --file Dockerfile --tag $fullImageName ." -ForegroundColor Magenta
    } else {
        docker build --file Dockerfile --tag $fullImageName .
        if ($LASTEXITCODE -ne 0) {
            Set-Location $originalDir
            Write-Error "Failed to build Docker image"
            exit 1
        }
        Write-Host "  Docker image built successfully." -ForegroundColor Green
        
        # Push image to ACR
        Write-Host "  Pushing image to ACR..." -ForegroundColor Yellow
        docker push $fullImageName
        if ($LASTEXITCODE -ne 0) {
            Set-Location $originalDir
            Write-Error "Failed to push Docker image to ACR"
            exit 1
        }
        Write-Host "  Image pushed to ACR successfully." -ForegroundColor Green
    }
    
    Set-Location $originalDir
}

Write-Host ""

# ============================================================================
# STEP 3: Create Log Analytics Workspace (if not exists)
# ============================================================================

Write-Host "STEP 3: Creating Log Analytics Workspace" -ForegroundColor Cyan

# Variables to store Log Analytics details
$logAnalyticsWorkspaceId = $null
$logAnalyticsWorkspaceKey = $null
$logAnalyticsCustomerId = $null

# Check if Log Analytics workspace exists
$laExists = az monitor log-analytics workspace show --workspace-name $logAnalyticsWorkspaceName --resource-group $azResourceGroup 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "  Log Analytics Workspace '$logAnalyticsWorkspaceName' already exists. Skipping creation." -ForegroundColor Yellow
} else {
    Write-Host "  Creating Log Analytics Workspace: $logAnalyticsWorkspaceName..." -ForegroundColor Yellow
    if ($WhatIf) {
        Write-Host "  [WhatIf] Would run: az monitor log-analytics workspace create --workspace-name $logAnalyticsWorkspaceName --resource-group $azResourceGroup --location $azRegion" -ForegroundColor Magenta
    } else {
        az monitor log-analytics workspace create `
            --workspace-name $logAnalyticsWorkspaceName `
            --resource-group $azResourceGroup `
            --location $azRegion `
            --output none
        
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to create Log Analytics Workspace"
            exit 1
        }
        Write-Host "  Log Analytics Workspace created successfully." -ForegroundColor Green
    }
}

# Get Log Analytics Workspace details
if (-not $WhatIf) {
    $logAnalyticsCustomerId = az monitor log-analytics workspace show `
        --workspace-name $logAnalyticsWorkspaceName `
        --resource-group $azResourceGroup `
        --query customerId -o tsv
    
    $logAnalyticsWorkspaceKey = az monitor log-analytics workspace get-shared-keys `
        --workspace-name $logAnalyticsWorkspaceName `
        --resource-group $azResourceGroup `
        --query primarySharedKey -o tsv
    
    Write-Host "  Workspace Customer ID: $logAnalyticsCustomerId" -ForegroundColor Green
    Write-Host "  Workspace Key: ********** (will be saved to input-config)" -ForegroundColor Green
}

Write-Host ""

# ============================================================================
# STEP 4: Create Container Apps Environment (if not exists)
# ============================================================================

Write-Host "STEP 4: Creating Container Apps Environment" -ForegroundColor Cyan

# Check if environment exists
$envExists = az containerapp env show --name $containerAppEnvName --resource-group $azResourceGroup 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "  Container Apps Environment '$containerAppEnvName' already exists. Skipping creation." -ForegroundColor Yellow
} else {
    Write-Host "  Creating Container Apps Environment: $containerAppEnvName..." -ForegroundColor Yellow
    if ($WhatIf) {
        Write-Host "  [WhatIf] Would run: az containerapp env create with Log Analytics workspace" -ForegroundColor Magenta
    } else {
        az containerapp env create `
            --name $containerAppEnvName `
            --resource-group $azResourceGroup `
            --location $azRegion `
            --logs-workspace-id $logAnalyticsCustomerId `
            --logs-workspace-key $logAnalyticsWorkspaceKey `
            --output none
        
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to create Container Apps Environment"
            exit 1
        }
        Write-Host "  Container Apps Environment created successfully." -ForegroundColor Green
    }
}

Write-Host ""

# ============================================================================
# STEP 5: Create or Update Container App with Bot Credentials
# ============================================================================

Write-Host "STEP 5: Creating/Updating Container App with Bot Credentials" -ForegroundColor Cyan

# Build environment variables string for bot credentials
$envVars = "MicrosoftAppId=$botAppId MicrosoftAppPassword=$botClientSecret MicrosoftAppTenantId=$botTenantId MicrosoftAppType=SingleTenant AZURE_STORAGE_ACCOUNT_NAME=$storageAccountName"

Write-Host "  Environment Variables:" -ForegroundColor Yellow
Write-Host "    MicrosoftAppId=$botAppId" -ForegroundColor White
Write-Host "    MicrosoftAppPassword=**********" -ForegroundColor White
Write-Host "    MicrosoftAppTenantId=$botTenantId" -ForegroundColor White
Write-Host "    MicrosoftAppType=SingleTenant" -ForegroundColor White
Write-Host "    AZURE_STORAGE_ACCOUNT_NAME=$storageAccountName" -ForegroundColor White

# Check if container app exists
$appExists = az containerapp show --name $containerAppName --resource-group $azResourceGroup 2>$null
if ($LASTEXITCODE -eq 0) {
    # Update existing container app with new image and environment variables
    Write-Host "  Container App '$containerAppName' exists. Updating with new image and credentials..." -ForegroundColor Yellow
    if ($WhatIf) {
        Write-Host "  [WhatIf] Would run: az containerapp update with new image and env vars" -ForegroundColor Magenta
    } else {
        az containerapp update `
            --name $containerAppName `
            --resource-group $azResourceGroup `
            --image $fullImageName `
            --set-env-vars $envVars `
            --output none
        
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to update Container App"
            exit 1
        }
        Write-Host "  Container App updated successfully." -ForegroundColor Green
    }
} else {
    # Create new container app
    Write-Host "  Creating Container App: $containerAppName..." -ForegroundColor Yellow
    if ($WhatIf) {
        Write-Host "  [WhatIf] Would create container app with public ingress and bot credentials" -ForegroundColor Magenta
    } else {
        az containerapp create `
            --name $containerAppName `
            --resource-group $azResourceGroup `
            --environment $containerAppEnvName `
            --image $fullImageName `
            --registry-server $acrLoginServer `
            --registry-username $acrUsername `
            --registry-password $acrPassword `
            --target-port 3978 `
            --ingress external `
            --transport auto `
            --env-vars $envVars `
            --output none
        
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to create Container App"
            exit 1
        }
        Write-Host "  Container App created successfully." -ForegroundColor Green
    }
}

Write-Host ""

# ============================================================================
# STEP 6: Get Container App URL
# ============================================================================

Write-Host "STEP 6: Retrieving Container App URL" -ForegroundColor Cyan

$containerAppUrl = $null
$messagingEndpoint = $null

if (-not $WhatIf) {
    # Get the FQDN of the container app
    $containerAppFqdn = az containerapp show `
        --name $containerAppName `
        --resource-group $azResourceGroup `
        --query "properties.configuration.ingress.fqdn" `
        --output tsv
    
    if ($containerAppFqdn) {
        $containerAppUrl = "https://$containerAppFqdn"
        $messagingEndpoint = "$containerAppUrl/api/messages"
        Write-Host "  Container App URL: $containerAppUrl" -ForegroundColor Green
        Write-Host "  Messaging Endpoint: $messagingEndpoint" -ForegroundColor Green
    } else {
        Write-Warning "Could not retrieve Container App URL"
    }
} else {
    Write-Host "  [WhatIf] Would retrieve Container App URL" -ForegroundColor Magenta
}

Write-Host ""

# ============================================================================
# STEP 7: Update Azure Bot Messaging Endpoint
# ============================================================================

Write-Host "STEP 7: Updating Azure Bot Messaging Endpoint" -ForegroundColor Cyan

if (-not $WhatIf -and $messagingEndpoint) {
    Write-Host "  Updating Bot '$botName' with messaging endpoint: $messagingEndpoint" -ForegroundColor Yellow
    
    az bot update `
        --name $botName `
        --resource-group $azResourceGroup `
        --endpoint $messagingEndpoint `
        --output none
    
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Failed to update bot endpoint. Please update manually in Azure Portal."
    } else {
        Write-Host "  Bot messaging endpoint updated successfully." -ForegroundColor Green
    }
} else {
    if ($WhatIf) {
        Write-Host "  [WhatIf] Would update Bot messaging endpoint" -ForegroundColor Magenta
    }
}

Write-Host ""

# ============================================================================
# STEP 8: Update input-config with Deployment Details
# ============================================================================

Write-Host "STEP 8: Updating input-config with Deployment Details" -ForegroundColor Cyan

if (-not $WhatIf -and $containerAppUrl) {
    $inputConfigContent = Get-Content $inputConfigPath -Raw
    
    # Helper function to update or add config entry
    function Update-ConfigEntry {
        param (
            [string]$Content,
            [string]$Key,
            [string]$Value
        )
        
        if ($Content -match "$Key=") {
            # Update existing entry
            $Content = $Content -replace "$Key=.*", "$Key=$Value"
        } else {
            # Add new entry
            $Content = $Content.TrimEnd() + "`n$Key=$Value"
        }
        return $Content
    }
    
    # Log Analytics details
    $inputConfigContent = Update-ConfigEntry -Content $inputConfigContent -Key "az-tab-log-analytics-name" -Value $logAnalyticsWorkspaceName
    $inputConfigContent = Update-ConfigEntry -Content $inputConfigContent -Key "az-tab-log-analytics-workspace-id" -Value $logAnalyticsCustomerId
    $inputConfigContent = Update-ConfigEntry -Content $inputConfigContent -Key "az-tab-log-analytics-key" -Value $logAnalyticsWorkspaceKey
    
    # Container App details
    $inputConfigContent = Update-ConfigEntry -Content $inputConfigContent -Key "az-tab-containerapp-env" -Value $containerAppEnvName
    $inputConfigContent = Update-ConfigEntry -Content $inputConfigContent -Key "az-tab-containerapp-name" -Value $containerAppName
    $inputConfigContent = Update-ConfigEntry -Content $inputConfigContent -Key "az-tab-containerapp-url" -Value $containerAppUrl
    $inputConfigContent = Update-ConfigEntry -Content $inputConfigContent -Key "az-tab-containerapp-image" -Value $fullImageName
    
    # Bot messaging endpoint
    $inputConfigContent = Update-ConfigEntry -Content $inputConfigContent -Key "az-tab-bot-messaging-endpoint" -Value $messagingEndpoint
    
    # Ensure file ends with newline
    $inputConfigContent = $inputConfigContent.TrimEnd() + "`n"
    
    Set-Content -Path $inputConfigPath -Value $inputConfigContent -NoNewline
    
    Write-Host "  Updated input-config with:" -ForegroundColor Green
    Write-Host "    az-tab-log-analytics-name=$logAnalyticsWorkspaceName" -ForegroundColor White
    Write-Host "    az-tab-log-analytics-workspace-id=$logAnalyticsCustomerId" -ForegroundColor White
    Write-Host "    az-tab-log-analytics-key=**********" -ForegroundColor White
    Write-Host "    az-tab-containerapp-env=$containerAppEnvName" -ForegroundColor White
    Write-Host "    az-tab-containerapp-name=$containerAppName" -ForegroundColor White
    Write-Host "    az-tab-containerapp-url=$containerAppUrl" -ForegroundColor White
    Write-Host "    az-tab-containerapp-image=$fullImageName" -ForegroundColor White
    Write-Host "    az-tab-bot-messaging-endpoint=$messagingEndpoint" -ForegroundColor White
} else {
    Write-Host "  [WhatIf] Would update input-config with deployment details" -ForegroundColor Magenta
}

Write-Host ""

# ============================================================================
# SUMMARY
# ============================================================================

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Deployment Summary" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Resource Group: $azResourceGroup" -ForegroundColor Green
Write-Host "  Log Analytics Workspace: $logAnalyticsWorkspaceName" -ForegroundColor Green
Write-Host "  Container Apps Environment: $containerAppEnvName" -ForegroundColor Green
Write-Host "  Container App: $containerAppName" -ForegroundColor Green
Write-Host "  Image: $fullImageName" -ForegroundColor Green
Write-Host "  Ingress: External (public access enabled)" -ForegroundColor Green
if (-not $WhatIf -and $containerAppUrl) {
    Write-Host "  URL: $containerAppUrl" -ForegroundColor Green
    Write-Host "  Bot Messaging Endpoint: $messagingEndpoint" -ForegroundColor Green
}
Write-Host ""
Write-Host "  Bot Environment Variables Configured:" -ForegroundColor Green
Write-Host "    - MicrosoftAppId" -ForegroundColor White
Write-Host "    - MicrosoftAppPassword" -ForegroundColor White
Write-Host "    - MicrosoftAppTenantId" -ForegroundColor White
Write-Host "    - MicrosoftAppType" -ForegroundColor White
Write-Host "    - AZURE_STORAGE_ACCOUNT_NAME" -ForegroundColor White
Write-Host ""
Write-Host "Container App deployment completed successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Yellow
Write-Host "  - Configure Teams channel in the Azure Portal for Bot: $botName" -ForegroundColor White
Write-Host "  - Test the bot by sending a message" -ForegroundColor White
Write-Host "  - To deploy a new version, simply run this script again" -ForegroundColor White
