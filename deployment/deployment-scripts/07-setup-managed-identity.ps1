#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Configures Managed Identity and RBAC for TAB-Agent-Bot Container App.

.DESCRIPTION
    This script automates the configuration of:
    - Enabling System Assigned Managed Identity on the Container App
    - Assigning RBAC roles to access Azure Blob Storage
    - Assigning RBAC roles to access Azure OpenAI

.NOTES
    Prerequisites:
    - Azure CLI installed and configured
    - Run scripts 01-06 before this script
    - Run this script from the 'deployment-scripts' folder
    
    Authentication:
    - Uses Azure AD authentication (logged-in user credentials)
    
    Idempotency:
    - Script can be re-run safely; existing role assignments will be detected
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
Write-Host "TAB-Agent-Bot - Managed Identity & RBAC Setup" -ForegroundColor Cyan
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

$azResourceGroup = $config["az-tab-rg"]
$containerAppName = $config["az-tab-containerapp-name"]
$storageAccountName = $config["az-tab-storage-account"]
$openAIName = $config["az-tab-openai-name"]

Write-Host "  Resource Group: $azResourceGroup" -ForegroundColor Green
Write-Host "  Container App: $containerAppName" -ForegroundColor Green
Write-Host "  Storage Account: $storageAccountName" -ForegroundColor Green
Write-Host "  Azure OpenAI: $openAIName" -ForegroundColor Green
Write-Host ""

# Validate required configurations
if (-not $azResourceGroup -or -not $containerAppName -or -not $storageAccountName -or -not $openAIName) {
    Write-Error "Missing required configuration. Please run previous deployment scripts first."
    exit 1
}

# ============================================================================
# STEP 1: Enable System Assigned Managed Identity
# ============================================================================

Write-Host "STEP 1: Enabling System Assigned Managed Identity on Container App" -ForegroundColor Cyan

$principalId = $null

if (-not $WhatIf) {
    # Check current identity status
    Write-Host "  Checking current identity status..." -ForegroundColor Yellow
    $containerApp = az containerapp show `
        --name $containerAppName `
        --resource-group $azResourceGroup `
        --query "identity" -o json 2>$null | ConvertFrom-Json
    
    if ($containerApp -and $containerApp.type -eq "SystemAssigned") {
        Write-Host "  System Assigned Managed Identity already enabled." -ForegroundColor Yellow
        $principalId = $containerApp.principalId
    } else {
        Write-Host "  Enabling System Assigned Managed Identity..." -ForegroundColor Yellow
        
        $identityResult = az containerapp identity assign `
            --name $containerAppName `
            --resource-group $azResourceGroup `
            --system-assigned `
            --output json | ConvertFrom-Json
        
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to enable Managed Identity"
            exit 1
        }
        
        $principalId = $identityResult.principalId
        Write-Host "  Managed Identity enabled successfully." -ForegroundColor Green
    }
    
    Write-Host "  Principal ID: $principalId" -ForegroundColor Green
} else {
    Write-Host "  [WhatIf] Would enable System Assigned Managed Identity" -ForegroundColor Magenta
}

Write-Host ""

# ============================================================================
# STEP 2: Get Resource IDs for Role Assignments
# ============================================================================

Write-Host "STEP 2: Retrieving Resource IDs" -ForegroundColor Cyan

$storageAccountId = $null
$openAIResourceId = $null

if (-not $WhatIf) {
    # Get Storage Account Resource ID
    Write-Host "  Getting Storage Account resource ID..." -ForegroundColor Yellow
    $storageAccountId = az storage account show `
        --name $storageAccountName `
        --resource-group $azResourceGroup `
        --query id -o tsv
    
    if (-not $storageAccountId) {
        Write-Error "Failed to get Storage Account resource ID"
        exit 1
    }
    Write-Host "  Storage Account ID: $storageAccountId" -ForegroundColor Green
    
    # Get Azure OpenAI Resource ID
    Write-Host "  Getting Azure OpenAI resource ID..." -ForegroundColor Yellow
    $openAIResourceId = az cognitiveservices account show `
        --name $openAIName `
        --resource-group $azResourceGroup `
        --query id -o tsv
    
    if (-not $openAIResourceId) {
        Write-Error "Failed to get Azure OpenAI resource ID"
        exit 1
    }
    Write-Host "  Azure OpenAI ID: $openAIResourceId" -ForegroundColor Green
} else {
    Write-Host "  [WhatIf] Would retrieve resource IDs" -ForegroundColor Magenta
}

Write-Host ""

# ============================================================================
# STEP 3: Assign Storage Account RBAC Roles
# ============================================================================

Write-Host "STEP 3: Assigning Storage Account RBAC Roles" -ForegroundColor Cyan

# Storage roles to assign (matching the screenshot)
$storageRoles = @(
    @{ Name = "Storage Account Contributor"; Id = "17d1049b-9a84-46fb-8f53-869881c3d3ab" },
    @{ Name = "Storage Blob Data Contributor"; Id = "ba92f5b4-2d11-453d-a403-e96b0029c9fe" },
    @{ Name = "Storage Blob Data Reader"; Id = "2a2b9908-6ea1-4ae2-8e65-a410df84e7d1" }
)

if (-not $WhatIf -and $principalId -and $storageAccountId) {
    foreach ($role in $storageRoles) {
        Write-Host "  Assigning '$($role.Name)' role..." -ForegroundColor Yellow
        
        # Check if role assignment already exists
        $existingAssignment = az role assignment list `
            --assignee $principalId `
            --role $role.Id `
            --scope $storageAccountId `
            --query "[0]" -o json 2>$null | ConvertFrom-Json
        
        if ($existingAssignment) {
            Write-Host "    Role '$($role.Name)' already assigned. Skipping." -ForegroundColor Yellow
        } else {
            az role assignment create `
                --assignee-object-id $principalId `
                --assignee-principal-type ServicePrincipal `
                --role $role.Id `
                --scope $storageAccountId `
                --output none
            
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Failed to assign role: $($role.Name)"
            } else {
                Write-Host "    Role '$($role.Name)' assigned successfully." -ForegroundColor Green
            }
        }
    }
} else {
    Write-Host "  [WhatIf] Would assign Storage Account roles:" -ForegroundColor Magenta
    foreach ($role in $storageRoles) {
        Write-Host "    - $($role.Name)" -ForegroundColor Magenta
    }
}

Write-Host ""

# ============================================================================
# STEP 4: Assign Azure OpenAI RBAC Roles
# ============================================================================

Write-Host "STEP 4: Assigning Azure OpenAI RBAC Roles" -ForegroundColor Cyan

# OpenAI roles to assign (matching the screenshot)
$openAIRoles = @(
    @{ Name = "Cognitive Services Contributor"; Id = "25fbc0a9-bd7c-42a3-aa1a-3b75d497ee68" },
    @{ Name = "Cognitive Services OpenAI Contributor"; Id = "a001fd3d-188f-4b5d-821b-7da978bf7442" }
)

if (-not $WhatIf -and $principalId -and $openAIResourceId) {
    foreach ($role in $openAIRoles) {
        Write-Host "  Assigning '$($role.Name)' role..." -ForegroundColor Yellow
        
        # Check if role assignment already exists
        $existingAssignment = az role assignment list `
            --assignee $principalId `
            --role $role.Id `
            --scope $openAIResourceId `
            --query "[0]" -o json 2>$null | ConvertFrom-Json
        
        if ($existingAssignment) {
            Write-Host "    Role '$($role.Name)' already assigned. Skipping." -ForegroundColor Yellow
        } else {
            az role assignment create `
                --assignee-object-id $principalId `
                --assignee-principal-type ServicePrincipal `
                --role $role.Id `
                --scope $openAIResourceId `
                --output none
            
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Failed to assign role: $($role.Name)"
            } else {
                Write-Host "    Role '$($role.Name)' assigned successfully." -ForegroundColor Green
            }
        }
    }
} else {
    Write-Host "  [WhatIf] Would assign Azure OpenAI roles:" -ForegroundColor Magenta
    foreach ($role in $openAIRoles) {
        Write-Host "    - $($role.Name)" -ForegroundColor Magenta
    }
}

Write-Host ""

# ============================================================================
# STEP 5: Update input-config with Managed Identity details
# ============================================================================

Write-Host "STEP 5: Updating input-config with Managed Identity details" -ForegroundColor Cyan

if (-not $WhatIf -and $principalId) {
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
    
    $inputConfigContent = Update-ConfigEntry -Content $inputConfigContent -Key "az-tab-containerapp-identity-principal-id" -Value $principalId
    
    # Ensure file ends with newline
    $inputConfigContent = $inputConfigContent.TrimEnd() + "`n"
    
    Set-Content -Path $inputConfigPath -Value $inputConfigContent -NoNewline
    
    Write-Host "  Updated input-config with:" -ForegroundColor Green
    Write-Host "    az-tab-containerapp-identity-principal-id=$principalId" -ForegroundColor White
} else {
    Write-Host "  [WhatIf] Would update input-config with Managed Identity details" -ForegroundColor Magenta
}

Write-Host ""

# ============================================================================
# STEP 6: Wait for Role Propagation
# ============================================================================

Write-Host "STEP 6: Waiting for Role Propagation" -ForegroundColor Cyan

if (-not $WhatIf) {
    Write-Host "  Waiting 30 seconds for RBAC role assignments to propagate..." -ForegroundColor Yellow
    Start-Sleep -Seconds 30
    Write-Host "  Role propagation wait completed." -ForegroundColor Green
} else {
    Write-Host "  [WhatIf] Would wait 30 seconds for role propagation" -ForegroundColor Magenta
}

Write-Host ""

# ============================================================================
# SUMMARY
# ============================================================================

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Deployment Summary" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Container App: $containerAppName" -ForegroundColor Green
Write-Host "  Managed Identity: System Assigned" -ForegroundColor Green
if (-not $WhatIf -and $principalId) {
    Write-Host "  Principal ID: $principalId" -ForegroundColor Green
}
Write-Host ""
Write-Host "  Storage Account Roles Assigned:" -ForegroundColor Green
foreach ($role in $storageRoles) {
    Write-Host "    - $($role.Name)" -ForegroundColor White
}
Write-Host ""
Write-Host "  Azure OpenAI Roles Assigned:" -ForegroundColor Green
foreach ($role in $openAIRoles) {
    Write-Host "    - $($role.Name)" -ForegroundColor White
}
Write-Host ""
Write-Host "Managed Identity and RBAC setup completed successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Yellow
Write-Host "  - Update your application to use DefaultAzureCredential for authentication" -ForegroundColor White
Write-Host "  - Remove API keys from environment variables (use Managed Identity instead)" -ForegroundColor White
Write-Host "  - Test the application to verify access to Storage and OpenAI" -ForegroundColor White
