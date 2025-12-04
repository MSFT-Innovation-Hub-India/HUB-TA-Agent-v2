#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Deploys Azure Application Insights for TAB-Agent-Bot solution.

.DESCRIPTION
    This script automates the deployment of Azure Application Insights including:
    - Creating an Application Insights resource
    - Linking to existing Log Analytics workspace
    - Saving the connection string to input-config

.NOTES
    Prerequisites:
    - Azure CLI installed and configured
    - Run scripts 01-04 before this script
    - Run this script from the 'deployment-scripts' folder
    
    Authentication:
    - Uses Azure AD authentication (logged-in user credentials)
    
    Idempotency:
    - Script can be re-run safely; existing resources will be reused
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
Write-Host "TAB-Agent-Bot - Application Insights Deployment" -ForegroundColor Cyan
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
$logAnalyticsWorkspaceId = $config["az-tab-log-analytics-workspace-id"]

Write-Host "  Azure Region: $azRegion" -ForegroundColor Green
Write-Host "  Resource Group: $azResourceGroup" -ForegroundColor Green
Write-Host "  Hub City: $hubCity" -ForegroundColor Green
Write-Host "  Log Analytics Workspace ID: $logAnalyticsWorkspaceId" -ForegroundColor Green
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
$appInsightsName = "az-$normalizedHubCity-appinsights"

Write-Host "  Application Insights Name: $appInsightsName" -ForegroundColor Green
Write-Host ""

# ============================================================================
# STEP 1: Create Application Insights Resource
# ============================================================================

Write-Host "STEP 1: Creating Application Insights Resource" -ForegroundColor Cyan

$connectionString = $null

if (-not $WhatIf) {
    # Check if Application Insights already exists using list command
    Write-Host "  Checking if Application Insights exists..." -ForegroundColor Yellow
    $existingAppInsights = az monitor app-insights component list `
        --resource-group $azResourceGroup `
        --query "[?name=='$appInsightsName'] | [0]" `
        -o json 2>$null | ConvertFrom-Json
    
    if ($existingAppInsights) {
        Write-Host "  Application Insights '$appInsightsName' already exists. Using existing resource." -ForegroundColor Yellow
        $connectionString = $existingAppInsights.connectionString
    } else {
        Write-Host "  Creating Application Insights: $appInsightsName..." -ForegroundColor Yellow
        
        # Get the full resource ID of the Log Analytics workspace using name from input-config
        $logAnalyticsName = $config["az-tab-log-analytics-name"]
        $workspaceParam = $null
        
        if ($logAnalyticsName) {
            Write-Host "  Looking up Log Analytics workspace: $logAnalyticsName..." -ForegroundColor Yellow
            $logAnalyticsResourceId = az monitor log-analytics workspace show `
                --workspace-name $logAnalyticsName `
                --resource-group $azResourceGroup `
                --query id -o tsv 2>$null
            
            if ($LASTEXITCODE -eq 0 -and $logAnalyticsResourceId) {
                $workspaceParam = $logAnalyticsResourceId
                Write-Host "  Linking to Log Analytics workspace: $logAnalyticsName" -ForegroundColor Yellow
            }
        }
        
        # Create Application Insights
        Write-Host "  Running az monitor app-insights component create..." -ForegroundColor Yellow
        
        if ($workspaceParam) {
            az monitor app-insights component create `
                --app $appInsightsName `
                --resource-group $azResourceGroup `
                --location $azRegion `
                --kind web `
                --application-type web `
                --workspace $workspaceParam `
                --output none
        } else {
            az monitor app-insights component create `
                --app $appInsightsName `
                --resource-group $azResourceGroup `
                --location $azRegion `
                --kind web `
                --application-type web `
                --output none
        }
        
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to create Application Insights"
            exit 1
        }
        
        Write-Host "  Application Insights created successfully." -ForegroundColor Green
        
        # Now fetch the connection string
        Write-Host "  Retrieving connection string..." -ForegroundColor Yellow
        $connectionString = az monitor app-insights component show `
            --app $appInsightsName `
            --resource-group $azResourceGroup `
            --query connectionString -o tsv
    }
    
    if ($connectionString) {
        Write-Host "  Connection String: $($connectionString.Substring(0, 50))..." -ForegroundColor Green
    } else {
        Write-Warning "Could not retrieve connection string"
    }
} else {
    Write-Host "  [WhatIf] Would create Application Insights: $appInsightsName" -ForegroundColor Magenta
}

Write-Host ""

# ============================================================================
# STEP 2: Update input-config with Application Insights details
# ============================================================================

Write-Host "STEP 2: Updating input-config with Application Insights details" -ForegroundColor Cyan

if (-not $WhatIf -and $connectionString) {
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
    
    $inputConfigContent = Update-ConfigEntry -Content $inputConfigContent -Key "az-tab-appinsights-name" -Value $appInsightsName
    $inputConfigContent = Update-ConfigEntry -Content $inputConfigContent -Key "az-tab-appinsights-connection-string" -Value $connectionString
    
    # Ensure file ends with newline
    $inputConfigContent = $inputConfigContent.TrimEnd() + "`n"
    
    Set-Content -Path $inputConfigPath -Value $inputConfigContent -NoNewline
    
    Write-Host "  Updated input-config with:" -ForegroundColor Green
    Write-Host "    az-tab-appinsights-name=$appInsightsName" -ForegroundColor White
    Write-Host "    az-tab-appinsights-connection-string=**********" -ForegroundColor White
} else {
    Write-Host "  [WhatIf] Would update input-config with Application Insights details" -ForegroundColor Magenta
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
Write-Host "  Application Insights Name: $appInsightsName" -ForegroundColor Green
Write-Host "  Region: $azRegion" -ForegroundColor Green
Write-Host "  Type: Web Application" -ForegroundColor Green
Write-Host ""
Write-Host "Application Insights deployment completed successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Yellow
Write-Host "  - Update Container App with APPLICATIONINSIGHTS_CONNECTION_STRING environment variable" -ForegroundColor White
Write-Host "  - Add Application Insights SDK to your application code" -ForegroundColor White
Write-Host "  - View telemetry in Azure Portal > Application Insights" -ForegroundColor White
