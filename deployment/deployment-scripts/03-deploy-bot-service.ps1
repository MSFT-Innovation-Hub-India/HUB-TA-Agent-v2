#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Deploys Azure Bot Service for TAB-Agent-Bot solution.

.DESCRIPTION
    This script automates the deployment of Azure Bot Service including:
    - Creating a Microsoft Entra ID App Registration (Single Tenant)
    - Creating a Service Principal (Enterprise Application) for the App Registration
    - Generating a client secret with 25-day validity
    - Creating an Azure Bot resource (Global type)
    - Saving credentials to input-config for use by Container App deployment

.NOTES
    Prerequisites:
    - Azure CLI installed and configured
    - Run scripts 01 and 02 before this script
    - Run this script from the 'deployment-scripts' folder
    
    Authentication:
    - Uses Azure AD authentication (logged-in user credentials)
    
    Idempotency:
    - Script can be re-run safely; existing resources will be reused
    - Client secret is only created if not already in input-config
#>

param(
    [switch]$WhatIf = $false,  # Set to $true to see what would happen without making changes
    [switch]$ForceNewSecret = $false  # Set to $true to force creation of a new client secret
)

# ============================================================================
# CONFIGURATION - Read from input-config
# ============================================================================

$scriptDir = $PSScriptRoot
$deploymentDir = Split-Path -Parent $scriptDir
$inputConfigPath = Join-Path $deploymentDir "input-config"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "TAB-Agent-Bot - Azure Bot Service Deployment" -ForegroundColor Cyan
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
$existingAppId = $config["az-tab-bot-app-id"]
$existingSecret = $config["az-tab-bot-client-secret"]

Write-Host "  Azure Region: $azRegion" -ForegroundColor Green
Write-Host "  Resource Group: $azResourceGroup" -ForegroundColor Green
Write-Host "  Hub City: $hubCity" -ForegroundColor Green
Write-Host ""

# Validate required configurations
if (-not $azRegion -or -not $azResourceGroup -or -not $hubCity) {
    Write-Error "Missing required configuration. Please run previous deployment scripts first."
    exit 1
}

# ============================================================================
# Normalize Hub City Name and Generate Resource Names
# ============================================================================

$normalizedHubCity = ($hubCity -replace '[^a-zA-Z0-9]', '').ToLower()
Write-Host "  Normalized Hub City: $normalizedHubCity" -ForegroundColor Green

# Resource names
$botName = "tab-$normalizedHubCity-agent"
$appDisplayName = "tab-$normalizedHubCity-agent-app"

# Placeholder endpoint - will be updated by 04-deploy-container-app.ps1
$placeholderEndpoint = "https://placeholder.azurecontainerapps.io/api/messages"

Write-Host "  Bot Name: $botName" -ForegroundColor Green
Write-Host "  App Registration Name: $appDisplayName" -ForegroundColor Green
Write-Host ""

# ============================================================================
# STEP 1: Create or Get Microsoft Entra ID App Registration
# ============================================================================

Write-Host "STEP 1: Creating Microsoft Entra ID App Registration" -ForegroundColor Cyan

$appId = $null
$tenantId = $null

if (-not $WhatIf) {
    # Check if app registration already exists
    $existingApp = az ad app list --display-name $appDisplayName --query "[0]" 2>$null | ConvertFrom-Json
    
    if ($existingApp) {
        Write-Host "  App Registration '$appDisplayName' already exists. Using existing app." -ForegroundColor Yellow
        $appId = $existingApp.appId
    } else {
        Write-Host "  Creating App Registration: $appDisplayName..." -ForegroundColor Yellow
        
        # Create single-tenant app registration
        $newApp = az ad app create `
            --display-name $appDisplayName `
            --sign-in-audience "AzureADMyOrg" `
            --query "{appId:appId}" -o json | ConvertFrom-Json
        
        if ($LASTEXITCODE -ne 0 -or -not $newApp) {
            Write-Error "Failed to create App Registration"
            exit 1
        }
        
        $appId = $newApp.appId
        Write-Host "  App Registration created successfully." -ForegroundColor Green
    }
    
    # Get tenant ID
    $tenantId = az account show --query tenantId -o tsv
    
    Write-Host "  App ID (Client ID): $appId" -ForegroundColor Green
    Write-Host "  Tenant ID: $tenantId" -ForegroundColor Green
    
    # Create Service Principal for the App Registration (required for token acquisition)
    Write-Host "  Creating Service Principal for App Registration..." -ForegroundColor Yellow
    $existingSp = az ad sp show --id $appId 2>$null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Service Principal already exists." -ForegroundColor Yellow
    } else {
        $spResult = az ad sp create --id $appId 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to create Service Principal: $spResult"
            exit 1
        }
        Write-Host "  Service Principal created successfully." -ForegroundColor Green
    }
} else {
    Write-Host "  [WhatIf] Would create App Registration: $appDisplayName" -ForegroundColor Magenta
    Write-Host "  [WhatIf] Would create Service Principal for the App Registration" -ForegroundColor Magenta
}

Write-Host ""

# ============================================================================
# STEP 2: Generate Client Secret (if not already exists or forced)
# ============================================================================

Write-Host "STEP 2: Generating Client Secret (25-day validity)" -ForegroundColor Cyan

$clientSecret = $null

if (-not $WhatIf) {
    # Check if we already have a secret in input-config and not forcing new one
    if ($existingSecret -and -not $ForceNewSecret) {
        Write-Host "  Client Secret already exists in input-config. Skipping creation." -ForegroundColor Yellow
        Write-Host "  (Use -ForceNewSecret to generate a new secret)" -ForegroundColor Yellow
        $clientSecret = $existingSecret
    } else {
        # Calculate end date (25 days from now)
        $endDate = (Get-Date).AddDays(25).ToString("yyyy-MM-dd")
        
        Write-Host "  Creating client secret with expiry: $endDate..." -ForegroundColor Yellow
        
        # Create a new client secret
        $secretResult = az ad app credential reset `
            --id $appId `
            --display-name "TAB-Agent-Bot-Secret" `
            --end-date $endDate `
            --query "{password:password}" -o json 2>$null | ConvertFrom-Json
        
        if ($LASTEXITCODE -ne 0 -or -not $secretResult) {
            Write-Error "Failed to create client secret"
            exit 1
        }
        
        $clientSecret = $secretResult.password
        Write-Host "  Client Secret created successfully." -ForegroundColor Green
        Write-Host "  Secret Value: ********** (will be saved to input-config)" -ForegroundColor Green
        Write-Host "  Expiry Date: $endDate" -ForegroundColor Green
    }
} else {
    Write-Host "  [WhatIf] Would create client secret with 25-day validity" -ForegroundColor Magenta
}

Write-Host ""

# ============================================================================
# STEP 3: Create Azure Bot Resource
# ============================================================================

Write-Host "STEP 3: Creating Azure Bot Resource" -ForegroundColor Cyan

if (-not $WhatIf) {
    # Check if bot already exists
    $botExists = az bot show --name $botName --resource-group $azResourceGroup 2>$null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Azure Bot '$botName' already exists." -ForegroundColor Yellow
        Write-Host "  Messaging endpoint will be updated by 04-deploy-container-app.ps1" -ForegroundColor Yellow
    } else {
        Write-Host "  Creating Azure Bot: $botName..." -ForegroundColor Yellow
        Write-Host "  Note: Using placeholder endpoint - will be updated after Container App deployment" -ForegroundColor Yellow
        
        # Build the command
        $botCreateParams = @(
            "--resource-group", $azResourceGroup,
            "--name", $botName,
            "--app-type", "SingleTenant",
            "--appid", $appId,
            "--tenant-id", $tenantId,
            "--endpoint", $placeholderEndpoint,
            "--output", "none"
        )
        
        az bot create @botCreateParams
        
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to create Azure Bot"
            exit 1
        }
        Write-Host "  Azure Bot created successfully." -ForegroundColor Green
    }
} else {
    Write-Host "  [WhatIf] Would create Azure Bot: $botName" -ForegroundColor Magenta
}

Write-Host ""

# ============================================================================
# STEP 4: Update input-config with Bot details
# ============================================================================

Write-Host "STEP 4: Updating input-config with Bot details" -ForegroundColor Cyan

if (-not $WhatIf) {
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
    
    $inputConfigContent = Update-ConfigEntry -Content $inputConfigContent -Key "az-tab-bot-name" -Value $botName
    $inputConfigContent = Update-ConfigEntry -Content $inputConfigContent -Key "az-tab-bot-app-id" -Value $appId
    $inputConfigContent = Update-ConfigEntry -Content $inputConfigContent -Key "az-tab-bot-tenant-id" -Value $tenantId
    $inputConfigContent = Update-ConfigEntry -Content $inputConfigContent -Key "az-tab-bot-client-secret" -Value $clientSecret
    
    # Ensure file ends with newline
    $inputConfigContent = $inputConfigContent.TrimEnd() + "`n"
    
    Set-Content -Path $inputConfigPath -Value $inputConfigContent -NoNewline
    
    Write-Host "  Updated input-config with:" -ForegroundColor Green
    Write-Host "    az-tab-bot-name=$botName" -ForegroundColor White
    Write-Host "    az-tab-bot-app-id=$appId" -ForegroundColor White
    Write-Host "    az-tab-bot-tenant-id=$tenantId" -ForegroundColor White
    Write-Host "    az-tab-bot-client-secret=**********" -ForegroundColor White
} else {
    Write-Host "  [WhatIf] Would update input-config with Bot details" -ForegroundColor Magenta
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
Write-Host "  Bot Name: $botName" -ForegroundColor Green
Write-Host "  Bot Type: Global, Single Tenant" -ForegroundColor Green
Write-Host "  App ID: $appId" -ForegroundColor Green
Write-Host "  Tenant ID: $tenantId" -ForegroundColor Green
Write-Host ""
Write-Host "Azure Bot Service deployment completed successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Yellow
Write-Host "  - Run 04-deploy-container-app.ps1 to deploy the Container App" -ForegroundColor White
Write-Host "  - The Container App script will automatically update the Bot's messaging endpoint" -ForegroundColor White
Write-Host "  - Configure Teams channel in the Azure Portal after Container App deployment" -ForegroundColor White
Write-Host "  - Note: Client secret expires in 25 days - renew before expiry" -ForegroundColor White
