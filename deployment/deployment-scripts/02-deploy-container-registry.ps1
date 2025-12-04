#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Deploys Azure Container Registry for TAB-Agent-Bot solution.

.DESCRIPTION
    This script automates the deployment of Azure Container Registry including:
    - Creating an ACR in the specified resource group
    - Enabling admin user credentials
    - Updating input-config with ACR details

.NOTES
    Prerequisites:
    - Azure CLI installed and configured
    - User must have RBAC access to create resources in the subscription
    - Run script 01-deploy-blob-storage.ps1 before this script
    - Run this script from the 'deployment-scripts' folder
    
    Authentication:
    - Uses Azure AD authentication (logged-in user credentials)
    
    Idempotency:
    - Script can be re-run safely; existing resources will be skipped
#>

param(
    [switch]$WhatIf = $false  # Set to $true to see what would happen without making changes
)

# ============================================================================
# CONFIGURATION - Read from input-config
# ============================================================================

$scriptDir = $PSScriptRoot
$deploymentDir = Split-Path -Parent $scriptDir
$inputConfigPath = Join-Path $deploymentDir "input-config"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "TAB-Agent-Bot - Azure Container Registry Deployment" -ForegroundColor Cyan
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

Write-Host "  Azure Region: $azRegion" -ForegroundColor Green
Write-Host "  Resource Group: $azResourceGroup" -ForegroundColor Green
Write-Host "  Hub City: $hubCity" -ForegroundColor Green
Write-Host ""

# Validate required configurations
if (-not $azRegion -or -not $azResourceGroup -or -not $hubCity) {
    Write-Error "Missing required configuration. Please ensure az-region, az-tab-rg, and hub-city are set in input-config"
    exit 1
}

# ============================================================================
# Normalize Hub City Name (matching application logic)
# ============================================================================

$normalizedHubCity = ($hubCity -replace '[^a-zA-Z0-9]', '').ToLower()
Write-Host "  Normalized Hub City: $normalizedHubCity" -ForegroundColor Green
Write-Host ""

# ============================================================================
# STEP 1: Create Azure Container Registry
# ============================================================================

Write-Host "STEP 1: Creating Azure Container Registry" -ForegroundColor Cyan

# Generate ACR name: 'tab' + cleansed city name + 'acr'
# ACR naming rules: 5-50 characters, alphanumeric only (no hyphens allowed in ACR names)
$acrName = "tab" + $normalizedHubCity + "acr"

# Truncate to max 50 characters if needed
if ($acrName.Length -gt 50) {
    $acrName = $acrName.Substring(0, 50)
}

Write-Host "  ACR Name: $acrName" -ForegroundColor Yellow

# Check if ACR already exists
$acrExists = az acr show --name $acrName --resource-group $azResourceGroup 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "  ACR '$acrName' already exists. Skipping creation." -ForegroundColor Yellow
} else {
    Write-Host "  Creating ACR: $acrName..." -ForegroundColor Yellow
    if ($WhatIf) {
        Write-Host "  [WhatIf] Would run: az acr create --name $acrName --resource-group $azResourceGroup --location $azRegion --sku Basic --admin-enabled true" -ForegroundColor Magenta
    } else {
        az acr create `
            --name $acrName `
            --resource-group $azResourceGroup `
            --location $azRegion `
            --sku Basic `
            --admin-enabled true `
            --output none
        
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to create Azure Container Registry"
            exit 1
        }
        Write-Host "  ACR created successfully." -ForegroundColor Green
    }
}

Write-Host ""

# ============================================================================
# STEP 2: Enable Admin User and Get Credentials
# ============================================================================

Write-Host "STEP 2: Ensuring Admin User is Enabled and Retrieving Credentials" -ForegroundColor Cyan

if (-not $WhatIf) {
    # Ensure admin user is enabled (idempotent)
    az acr update --name $acrName --resource-group $azResourceGroup --admin-enabled true --output none 2>$null
    
    # Get admin credentials
    $acrCredentials = az acr credential show --name $acrName --resource-group $azResourceGroup 2>$null | ConvertFrom-Json
    
    if ($LASTEXITCODE -ne 0 -or -not $acrCredentials) {
        Write-Error "Failed to retrieve ACR credentials"
        exit 1
    }
    
    $acrUsername = $acrCredentials.username
    $acrPassword = $acrCredentials.passwords[0].value
    $acrLoginServer = "$acrName.azurecr.io"
    
    Write-Host "  Admin User: $acrUsername" -ForegroundColor Green
    Write-Host "  Login Server: $acrLoginServer" -ForegroundColor Green
    Write-Host "  Password: ********** (saved to input-config)" -ForegroundColor Green
} else {
    Write-Host "  [WhatIf] Would enable admin user and retrieve credentials" -ForegroundColor Magenta
    $acrUsername = "<admin-username>"
    $acrPassword = "<admin-password>"
    $acrLoginServer = "$acrName.azurecr.io"
}

Write-Host ""

# ============================================================================
# STEP 3: Update input-config with ACR details
# ============================================================================

Write-Host "STEP 3: Updating input-config with ACR details" -ForegroundColor Cyan

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
    
    $inputConfigContent = Update-ConfigEntry -Content $inputConfigContent -Key "az-tab-acr-name" -Value $acrName
    $inputConfigContent = Update-ConfigEntry -Content $inputConfigContent -Key "az-tab-acr-login-server" -Value $acrLoginServer
    $inputConfigContent = Update-ConfigEntry -Content $inputConfigContent -Key "az-tab-acr-username" -Value $acrUsername
    $inputConfigContent = Update-ConfigEntry -Content $inputConfigContent -Key "az-tab-acr-password" -Value $acrPassword
    
    # Ensure file ends with newline
    $inputConfigContent = $inputConfigContent.TrimEnd() + "`n"
    
    Set-Content -Path $inputConfigPath -Value $inputConfigContent -NoNewline
    
    Write-Host "  Updated input-config with:" -ForegroundColor Green
    Write-Host "    az-tab-acr-name=$acrName" -ForegroundColor White
    Write-Host "    az-tab-acr-login-server=$acrLoginServer" -ForegroundColor White
    Write-Host "    az-tab-acr-username=$acrUsername" -ForegroundColor White
    Write-Host "    az-tab-acr-password=**********" -ForegroundColor White
} else {
    Write-Host "  [WhatIf] Would update input-config with ACR details" -ForegroundColor Magenta
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
Write-Host "  ACR Name: $acrName" -ForegroundColor Green
Write-Host "  ACR Login Server: $acrLoginServer" -ForegroundColor Green
Write-Host "  Location: $azRegion" -ForegroundColor Green
Write-Host "  Admin User Enabled: Yes" -ForegroundColor Green
Write-Host ""
Write-Host "  Credentials saved to input-config" -ForegroundColor Yellow
Write-Host ""
Write-Host "Azure Container Registry deployment completed successfully!" -ForegroundColor Green
