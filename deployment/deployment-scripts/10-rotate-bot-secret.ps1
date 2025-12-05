#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Rotates the Bot App client secret and updates the Azure Container App.

.DESCRIPTION
    This script automates the rotation of the Bot App client secret:
    - Generates a new client secret with 25-day validity
    - Updates the Azure Container App with the new secret
    - Updates the input-config file with the new secret
    
    This script is designed to be run:
    - Manually when secret rotation is needed
    - As an Azure Automation Runbook on a schedule (every 20-25 days)

.NOTES
    Prerequisites:
    - Azure CLI installed and configured (for manual runs)
    - For Azure Automation: Managed Identity with appropriate permissions
    - Run scripts 01-04 before this script (initial deployment)
    
    Required Permissions (for Azure Automation Managed Identity):
    - Microsoft Graph: Application.ReadWrite.All
    - Azure RBAC: Contributor on the Container App resource group

.PARAMETER WhatIf
    Shows what would happen without making changes.

.PARAMETER SecretValidityDays
    Number of days the new secret should be valid. Default is 25.

.EXAMPLE
    .\10-rotate-bot-secret.ps1
    
.EXAMPLE
    .\10-rotate-bot-secret.ps1 -WhatIf

.EXAMPLE
    .\10-rotate-bot-secret.ps1 -SecretValidityDays 30
#>

param(
    [switch]$WhatIf = $false,
    [int]$SecretValidityDays = 25
)

$ErrorActionPreference = "Stop"

# ============================================================================
# CONFIGURATION - Read from input-config
# ============================================================================

$scriptDir = $PSScriptRoot
$deploymentDir = Split-Path -Parent $scriptDir
$inputConfigPath = Join-Path $deploymentDir "input-config"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "TAB-Agent-Bot - Bot Secret Rotation" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Execution Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Yellow
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

$azResourceGroup = $config["az-tab-rg"]
$hubCity = $config["hub-city"]
$botAppId = $config["az-tab-bot-app-id"]
$containerAppName = $config["az-tab-containerapp-name"]
$currentSecret = $config["az-tab-bot-client-secret"]

# Normalize hub city for display
$normalizedHubCity = ($hubCity -replace '[^a-zA-Z0-9]', '').ToLower()

Write-Host "  Resource Group: $azResourceGroup" -ForegroundColor Green
Write-Host "  Hub City: $hubCity ($normalizedHubCity)" -ForegroundColor Green
Write-Host "  Bot App ID: $botAppId" -ForegroundColor Green
Write-Host "  Container App: $containerAppName" -ForegroundColor Green
Write-Host "  Secret Validity: $SecretValidityDays days" -ForegroundColor Green
Write-Host ""

# Validate required configurations
if (-not $azResourceGroup -or -not $botAppId -or -not $containerAppName) {
    Write-Error "Missing required configuration. Please ensure deployment scripts 01-04 have been run."
    exit 1
}

# ============================================================================
# STEP 1: Generate New Client Secret
# ============================================================================

Write-Host "STEP 1: Generating New Client Secret" -ForegroundColor Cyan

$newClientSecret = $null
$endDate = (Get-Date).AddDays($SecretValidityDays).ToString("yyyy-MM-dd")

if ($WhatIf) {
    Write-Host "  [WhatIf] Would create new client secret with expiry: $endDate" -ForegroundColor Magenta
    $newClientSecret = "WHATIF-SECRET-PLACEHOLDER"
} else {
    Write-Host "  Creating new client secret with expiry: $endDate..." -ForegroundColor Yellow
    
    # Create a new client secret
    $secretResult = az ad app credential reset `
        --id $botAppId `
        --display-name "TAB-Agent-Bot-Secret-Rotated-$(Get-Date -Format 'yyyyMMdd')" `
        --end-date $endDate `
        --query "{password:password}" -o json 2>&1
    
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to create new client secret: $secretResult"
        exit 1
    }
    
    $secretJson = $secretResult | ConvertFrom-Json
    $newClientSecret = $secretJson.password
    
    if (-not $newClientSecret) {
        Write-Error "Failed to retrieve new client secret from response"
        exit 1
    }
    
    Write-Host "  New client secret created successfully." -ForegroundColor Green
    Write-Host "  Expiry Date: $endDate" -ForegroundColor Green
}

Write-Host ""

# ============================================================================
# STEP 2: Update Container App Environment Variable
# ============================================================================

Write-Host "STEP 2: Updating Container App with New Secret" -ForegroundColor Cyan

if ($WhatIf) {
    Write-Host "  [WhatIf] Would update Container App '$containerAppName' with new CLIENT_SECRET" -ForegroundColor Magenta
} else {
    Write-Host "  Updating CLIENT_SECRET environment variable..." -ForegroundColor Yellow
    
    # Update only the CLIENT_SECRET environment variable
    $result = az containerapp update `
        --name $containerAppName `
        --resource-group $azResourceGroup `
        --set-env-vars "CLIENT_SECRET=$newClientSecret" `
        --output none 2>&1
    
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to update Container App: $result"
        exit 1
    }
    
    Write-Host "  Container App updated successfully." -ForegroundColor Green
    Write-Host "  The container will restart automatically with the new secret." -ForegroundColor Green
}

Write-Host ""

# ============================================================================
# STEP 3: Update input-config File
# ============================================================================

Write-Host "STEP 3: Updating input-config with New Secret" -ForegroundColor Cyan

if ($WhatIf) {
    Write-Host "  [WhatIf] Would update az-tab-bot-client-secret in input-config" -ForegroundColor Magenta
} else {
    $inputConfigContent = Get-Content $inputConfigPath -Raw
    
    # Update the client secret in input-config
    if ($inputConfigContent -match "az-tab-bot-client-secret=") {
        $inputConfigContent = $inputConfigContent -replace "az-tab-bot-client-secret=.*", "az-tab-bot-client-secret=$newClientSecret"
    } else {
        $inputConfigContent = $inputConfigContent.TrimEnd() + "`naz-tab-bot-client-secret=$newClientSecret`n"
    }
    
    Set-Content -Path $inputConfigPath -Value $inputConfigContent -NoNewline
    Write-Host "  Updated input-config with new client secret." -ForegroundColor Green
}

Write-Host ""

# ============================================================================
# STEP 4: Verify Container App Health (Optional)
# ============================================================================

Write-Host "STEP 4: Verifying Container App Status" -ForegroundColor Cyan

if ($WhatIf) {
    Write-Host "  [WhatIf] Would check Container App status" -ForegroundColor Magenta
} else {
    # Wait a moment for the update to propagate
    Write-Host "  Waiting for Container App to update..." -ForegroundColor Yellow
    Start-Sleep -Seconds 10
    
    # Check container app status
    $appStatus = az containerapp show `
        --name $containerAppName `
        --resource-group $azResourceGroup `
        --query "properties.runningStatus" -o tsv 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Container App Status: $appStatus" -ForegroundColor Green
    } else {
        Write-Host "  Warning: Could not verify Container App status" -ForegroundColor Yellow
    }
}

Write-Host ""

# ============================================================================
# SUMMARY
# ============================================================================

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Secret Rotation Complete!" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Summary:" -ForegroundColor Green
Write-Host "  Bot App ID: $botAppId" -ForegroundColor White
Write-Host "  Container App: $containerAppName" -ForegroundColor White
Write-Host "  New Secret Expiry: $endDate" -ForegroundColor White
Write-Host "  Next Rotation Due: Before $endDate" -ForegroundColor Yellow
Write-Host ""

if (-not $WhatIf) {
    # Log rotation event
    $logEntry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Secret rotated. New expiry: $endDate"
    $logPath = Join-Path $deploymentDir "secret-rotation.log"
    Add-Content -Path $logPath -Value $logEntry
    Write-Host "  Rotation logged to: $logPath" -ForegroundColor Gray
}

Write-Host ""
Write-Host "Secret rotation completed successfully!" -ForegroundColor Green
