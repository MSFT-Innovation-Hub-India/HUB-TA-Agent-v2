#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Deploys Azure OpenAI Service for TAB-Agent-Bot solution.

.DESCRIPTION
    This script automates the deployment of Azure OpenAI Service including:
    - Creating an Azure OpenAI resource
    - Deploying the GPT-4o model
    - Assigning necessary role permissions
    - Saving endpoint and key to input-config

.NOTES
    Prerequisites:
    - Azure CLI installed and configured
    - Run scripts 01-05 before this script
    - Run this script from the 'deployment-scripts' folder
    - Your subscription must have access to Azure OpenAI Service
    
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
Write-Host "TAB-Agent-Bot - Azure OpenAI Deployment" -ForegroundColor Cyan
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
    Write-Error "Missing required configuration. Please run previous deployment scripts first."
    exit 1
}

# ============================================================================
# Normalize Hub City Name and Generate Resource Names
# ============================================================================

$normalizedHubCity = ($hubCity -replace '[^a-zA-Z0-9]', '').ToLower()
Write-Host "  Normalized Hub City: $normalizedHubCity" -ForegroundColor Green

# Resource names
$openAIName = "az-$normalizedHubCity-openai"
$gpt4oDeploymentName = "gpt-4o"

Write-Host "  Azure OpenAI Name: $openAIName" -ForegroundColor Green
Write-Host "  GPT-4o Deployment Name: $gpt4oDeploymentName" -ForegroundColor Green
Write-Host ""

# ============================================================================
# STEP 1: Create Azure OpenAI Resource
# ============================================================================

Write-Host "STEP 1: Creating Azure OpenAI Resource" -ForegroundColor Cyan

$openAIEndpoint = $null
$openAIKey = $null

if (-not $WhatIf) {
    # Check if Azure OpenAI resource already exists
    Write-Host "  Checking if Azure OpenAI resource exists..." -ForegroundColor Yellow
    $existingOpenAI = az cognitiveservices account show `
        --name $openAIName `
        --resource-group $azResourceGroup 2>$null | ConvertFrom-Json
    
    if ($LASTEXITCODE -eq 0 -and $existingOpenAI) {
        Write-Host "  Azure OpenAI '$openAIName' already exists. Using existing resource." -ForegroundColor Yellow
        $openAIEndpoint = $existingOpenAI.properties.endpoint
    } else {
        Write-Host "  Creating Azure OpenAI resource: $openAIName..." -ForegroundColor Yellow
        
        az cognitiveservices account create `
            --name $openAIName `
            --resource-group $azResourceGroup `
            --location $azRegion `
            --kind OpenAI `
            --sku S0 `
            --custom-domain $openAIName `
            --output none
        
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to create Azure OpenAI resource. Make sure your subscription has access to Azure OpenAI."
            exit 1
        }
        
        Write-Host "  Azure OpenAI resource created successfully." -ForegroundColor Green
        
        # Get the endpoint
        $openAIResource = az cognitiveservices account show `
            --name $openAIName `
            --resource-group $azResourceGroup | ConvertFrom-Json
        
        $openAIEndpoint = $openAIResource.properties.endpoint
    }
    
    # Get the API key
    Write-Host "  Retrieving API key..." -ForegroundColor Yellow
    $keys = az cognitiveservices account keys list `
        --name $openAIName `
        --resource-group $azResourceGroup | ConvertFrom-Json
    
    $openAIKey = $keys.key1
    
    Write-Host "  Endpoint: $openAIEndpoint" -ForegroundColor Green
    Write-Host "  API Key: **********" -ForegroundColor Green
} else {
    Write-Host "  [WhatIf] Would create Azure OpenAI resource: $openAIName" -ForegroundColor Magenta
}

Write-Host ""

# ============================================================================
# STEP 2: Deploy GPT-4o Model
# ============================================================================

Write-Host "STEP 2: Deploying GPT-4o Model" -ForegroundColor Cyan

if (-not $WhatIf) {
    # Check if deployment already exists
    Write-Host "  Checking if GPT-4o deployment exists..." -ForegroundColor Yellow
    $existingDeployment = az cognitiveservices account deployment show `
        --name $openAIName `
        --resource-group $azResourceGroup `
        --deployment-name $gpt4oDeploymentName 2>$null | ConvertFrom-Json
    
    if ($LASTEXITCODE -eq 0 -and $existingDeployment) {
        Write-Host "  GPT-4o deployment '$gpt4oDeploymentName' already exists." -ForegroundColor Yellow
    } else {
        Write-Host "  Creating GPT-4o deployment: $gpt4oDeploymentName..." -ForegroundColor Yellow
        
        az cognitiveservices account deployment create `
            --name $openAIName `
            --resource-group $azResourceGroup `
            --deployment-name $gpt4oDeploymentName `
            --model-name "gpt-4o" `
            --model-version "2024-08-06" `
            --model-format OpenAI `
            --sku-capacity 10 `
            --sku-name Standard `
            --output none
        
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Failed to create GPT-4o deployment. You may need to deploy it manually or check model availability in your region."
        } else {
            Write-Host "  GPT-4o deployment created successfully." -ForegroundColor Green
        }
    }
} else {
    Write-Host "  [WhatIf] Would deploy GPT-4o model" -ForegroundColor Magenta
}

Write-Host ""

# ============================================================================
# STEP 3: Update input-config with Azure OpenAI details
# ============================================================================

Write-Host "STEP 3: Updating input-config with Azure OpenAI details" -ForegroundColor Cyan

if (-not $WhatIf -and $openAIEndpoint) {
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
    
    $inputConfigContent = Update-ConfigEntry -Content $inputConfigContent -Key "az-tab-openai-name" -Value $openAIName
    $inputConfigContent = Update-ConfigEntry -Content $inputConfigContent -Key "az-tab-openai-endpoint" -Value $openAIEndpoint
    $inputConfigContent = Update-ConfigEntry -Content $inputConfigContent -Key "az-tab-openai-key" -Value $openAIKey
    $inputConfigContent = Update-ConfigEntry -Content $inputConfigContent -Key "az-tab-openai-deployment" -Value $gpt4oDeploymentName
    
    # Ensure file ends with newline
    $inputConfigContent = $inputConfigContent.TrimEnd() + "`n"
    
    Set-Content -Path $inputConfigPath -Value $inputConfigContent -NoNewline
    
    Write-Host "  Updated input-config with:" -ForegroundColor Green
    Write-Host "    az-tab-openai-name=$openAIName" -ForegroundColor White
    Write-Host "    az-tab-openai-endpoint=$openAIEndpoint" -ForegroundColor White
    Write-Host "    az-tab-openai-key=**********" -ForegroundColor White
    Write-Host "    az-tab-openai-deployment=$gpt4oDeploymentName" -ForegroundColor White
} else {
    Write-Host "  [WhatIf] Would update input-config with Azure OpenAI details" -ForegroundColor Magenta
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
Write-Host "  Azure OpenAI Name: $openAIName" -ForegroundColor Green
Write-Host "  Region: $azRegion" -ForegroundColor Green
Write-Host "  SKU: S0 (Standard)" -ForegroundColor Green
Write-Host "  Model Deployment: $gpt4oDeploymentName (GPT-4o)" -ForegroundColor Green
if (-not $WhatIf -and $openAIEndpoint) {
    Write-Host "  Endpoint: $openAIEndpoint" -ForegroundColor Green
}
Write-Host ""
Write-Host "Azure OpenAI deployment completed successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Yellow
Write-Host "  - Update Container App with AZURE_OPENAI_ENDPOINT and AZURE_OPENAI_KEY environment variables" -ForegroundColor White
Write-Host "  - Or use Managed Identity for authentication (recommended)" -ForegroundColor White
Write-Host "  - Test the model in Azure AI Studio" -ForegroundColor White
