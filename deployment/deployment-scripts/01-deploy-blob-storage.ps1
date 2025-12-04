#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Deploys Azure Blob Storage for TAB-Agent-Bot solution.

.DESCRIPTION
    This script automates the deployment of Azure Blob Storage including:
    - Creating a Storage Account in the specified Azure region
    - Creating required containers (agenda-docs, golden-repo, hub-master, tab-state)
    - Uploading master data and documents to the containers

.NOTES
    Prerequisites:
    - Azure CLI installed and configured
    - User must have RBAC access to create resources in the subscription
    - User must have Storage Blob Data Contributor role on the storage account
    - Run this script from the 'deployment-scripts' folder or ensure relative paths are correct
    
    Authentication:
    - Uses Azure AD authentication (logged-in user credentials) for all operations
    - No storage account keys are used
    
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
$blobStoreDir = Join-Path $deploymentDir "blob-store"
$inputConfigPath = Join-Path $deploymentDir "input-config"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "TAB-Agent-Bot - Azure Blob Storage Deployment" -ForegroundColor Cyan
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
    if ($_ -match "^([^=]+)=(.*)$") {
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
# STEP 3: Normalize Hub City Name (matching application logic)
# ============================================================================
# Application logic from config.py:
# - Remove all non-alphanumeric characters (including spaces)
# - Convert to lowercase
# Example: "New York" -> "newyork", "Bengaluru" -> "bengaluru"

Write-Host "STEP 3: Normalizing Hub City Name" -ForegroundColor Cyan
$normalizedHubCity = ($hubCity -replace '[^a-zA-Z0-9]', '').ToLower()
Write-Host "  Original Hub City: $hubCity" -ForegroundColor Yellow
Write-Host "  Normalized Hub City: $normalizedHubCity" -ForegroundColor Green
Write-Host ""

# ============================================================================
# STEP 1: Create Resource Group and Storage Account
# ============================================================================

Write-Host "STEP 1: Creating Resource Group and Storage Account" -ForegroundColor Cyan

# Generate storage account name: 'tab' + cleansed city name
# Azure Storage Account naming rules: 3-24 characters, lowercase alphanumeric only
$storageAccountName = "tab" + $normalizedHubCity

# Truncate to max 24 characters if needed
if ($storageAccountName.Length -gt 24) {
    $storageAccountName = $storageAccountName.Substring(0, 24)
}

Write-Host "  Storage Account Name: $storageAccountName" -ForegroundColor Yellow

# Check if Resource Group exists
$rgExists = az group exists --name $azResourceGroup 2>$null
if ($rgExists -eq "true") {
    Write-Host "  Resource Group '$azResourceGroup' already exists. Skipping creation." -ForegroundColor Yellow
} else {
    Write-Host "  Creating Resource Group: $azResourceGroup in $azRegion..." -ForegroundColor Yellow
    if ($WhatIf) {
        Write-Host "  [WhatIf] Would run: az group create --name $azResourceGroup --location $azRegion" -ForegroundColor Magenta
    } else {
        az group create --name $azResourceGroup --location $azRegion --output none
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to create resource group"
            exit 1
        }
        Write-Host "  Resource Group created successfully." -ForegroundColor Green
    }
}

# Check if Storage Account exists
$storageExists = az storage account show --name $storageAccountName --resource-group $azResourceGroup 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "  Storage Account '$storageAccountName' already exists. Skipping creation." -ForegroundColor Yellow
} else {
    Write-Host "  Creating Storage Account: $storageAccountName..." -ForegroundColor Yellow
    if ($WhatIf) {
        Write-Host "  [WhatIf] Would run: az storage account create --name $storageAccountName --resource-group $azResourceGroup --location $azRegion --sku Standard_LRS --kind StorageV2" -ForegroundColor Magenta
    } else {
        az storage account create `
            --name $storageAccountName `
            --resource-group $azResourceGroup `
            --location $azRegion `
            --sku Standard_LRS `
            --kind StorageV2 `
            --output none
        
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to create storage account"
            exit 1
        }
        Write-Host "  Storage Account created successfully." -ForegroundColor Green
    }
}

Write-Host ""

# ============================================================================
# Assign Storage Blob Data Contributor role to current user (for Azure AD auth)
# ============================================================================

Write-Host "Ensuring current user has Storage Blob Data Contributor role..." -ForegroundColor Cyan

if (-not $WhatIf) {
    # Get current user's object ID
    $currentUserObjectId = az ad signed-in-user show --query id -o tsv 2>$null
    
    if ($currentUserObjectId) {
        # Get storage account resource ID
        $storageAccountId = az storage account show `
            --name $storageAccountName `
            --resource-group $azResourceGroup `
            --query id -o tsv
        
        # Check if role assignment already exists
        $existingRole = az role assignment list `
            --assignee $currentUserObjectId `
            --scope $storageAccountId `
            --role "Storage Blob Data Contributor" `
            --query "[0].id" -o tsv 2>$null
        
        if ($existingRole) {
            Write-Host "  Role assignment already exists. Skipping." -ForegroundColor Yellow
        } else {
            Write-Host "  Assigning Storage Blob Data Contributor role..." -ForegroundColor Yellow
            az role assignment create `
                --assignee $currentUserObjectId `
                --role "Storage Blob Data Contributor" `
                --scope $storageAccountId `
                --output none 2>$null
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  Role assigned successfully." -ForegroundColor Green
                Write-Host "  Waiting 30 seconds for role assignment to propagate..." -ForegroundColor Yellow
                Start-Sleep -Seconds 30
            } else {
                Write-Warning "  Could not assign role. You may need to assign 'Storage Blob Data Contributor' role manually."
            }
        }
    } else {
        Write-Warning "  Could not determine current user. Ensure you have 'Storage Blob Data Contributor' role on the storage account."
    }
}

Write-Host ""

# ============================================================================
# STEP 2: Create Containers (using Azure AD authentication)
# ============================================================================

Write-Host "STEP 2: Creating Containers in Storage Account" -ForegroundColor Cyan

# Container names based on folder structure in blob-store
$containers = @("agenda-docs", "golden-repo", "hub-master", "tab-state")

foreach ($container in $containers) {
    if ($WhatIf) {
        Write-Host "  [WhatIf] Would create container: $container" -ForegroundColor Magenta
    } else {
        # Check if container exists
        $containerExists = az storage container exists `
            --name $container `
            --account-name $storageAccountName `
            --auth-mode login `
            --query exists -o tsv 2>$null
        
        if ($containerExists -eq "true") {
            Write-Host "  Container '$container' already exists. Skipping." -ForegroundColor Yellow
        } else {
            Write-Host "  Creating container: $container..." -ForegroundColor Yellow
            az storage container create `
                --name $container `
                --account-name $storageAccountName `
                --auth-mode login `
                --output none
            
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Failed to create container: $container"
                exit 1
            } else {
                Write-Host "  Container '$container' created successfully." -ForegroundColor Green
            }
        }
    }
}

Write-Host ""

# ============================================================================
# STEP 4: Upload Master Data and Documents (using Azure AD authentication)
# ============================================================================

Write-Host "STEP 4: Uploading Master Data and Documents" -ForegroundColor Cyan

# --- Upload to 'golden-repo' container ---
Write-Host ""
Write-Host "  Uploading to 'golden-repo' container..." -ForegroundColor Cyan

$goldenRepoLocalPath = Join-Path $blobStoreDir "golden-repo"
$hubDirectoryName = "hub-$normalizedHubCity"

# Step 4a: Create hub directory and upload agenda_mapping.md
$agendaMappingFile = Join-Path $goldenRepoLocalPath "agenda_mapping.md"
$agendaMappingBlobPath = "$hubDirectoryName/agenda_mapping.md"

Write-Host "    Creating directory '$hubDirectoryName' and uploading agenda_mapping.md..." -ForegroundColor Yellow
if ($WhatIf) {
    Write-Host "    [WhatIf] Would upload: $agendaMappingFile -> $agendaMappingBlobPath" -ForegroundColor Magenta
} else {
    az storage blob upload `
        --container-name "golden-repo" `
        --file $agendaMappingFile `
        --name $agendaMappingBlobPath `
        --account-name $storageAccountName `
        --auth-mode login `
        --overwrite `
        --output none
    
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Failed to upload agenda_mapping.md"
    } else {
        Write-Host "    Uploaded agenda_mapping.md to $agendaMappingBlobPath" -ForegroundColor Green
    }
}

# Step 4c & 4d: Create 'documents' directory inside hub folder and upload remaining files
Write-Host "    Uploading other documents to '$hubDirectoryName/documents' directory..." -ForegroundColor Yellow
$documentsDir = "$hubDirectoryName/documents"

Get-ChildItem -Path $goldenRepoLocalPath -File | Where-Object { $_.Name -ne "agenda_mapping.md" } | ForEach-Object {
    $localFilePath = $_.FullName
    $blobPath = "$documentsDir/$($_.Name)"
    
    if ($WhatIf) {
        Write-Host "    [WhatIf] Would upload: $localFilePath -> $blobPath" -ForegroundColor Magenta
    } else {
        az storage blob upload `
            --container-name "golden-repo" `
            --file $localFilePath `
            --name $blobPath `
            --account-name $storageAccountName `
            --auth-mode login `
            --overwrite `
            --output none
        
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Failed to upload $($_.Name)"
        } else {
            Write-Host "    Uploaded $($_.Name) to $blobPath" -ForegroundColor Green
        }
    }
}

# --- Upload to 'hub-master' container ---
Write-Host ""
Write-Host "  Uploading to 'hub-master' container..." -ForegroundColor Cyan

$hubMasterLocalPath = Join-Path $blobStoreDir "hub-master"
$targetHubMasterFileName = "hub-$normalizedHubCity.md"

# Find the markdown file in hub-master folder and upload with new name
$hubMasterFiles = Get-ChildItem -Path $hubMasterLocalPath -Filter "*.md" -File

if ($hubMasterFiles.Count -gt 0) {
    $sourceFile = $hubMasterFiles[0].FullName
    Write-Host "    Uploading $($hubMasterFiles[0].Name) as $targetHubMasterFileName..." -ForegroundColor Yellow
    
    if ($WhatIf) {
        Write-Host "    [WhatIf] Would upload: $sourceFile -> $targetHubMasterFileName" -ForegroundColor Magenta
    } else {
        az storage blob upload `
            --container-name "hub-master" `
            --file $sourceFile `
            --name $targetHubMasterFileName `
            --account-name $storageAccountName `
            --auth-mode login `
            --overwrite `
            --output none
        
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Failed to upload hub-master file"
        } else {
            Write-Host "    Uploaded as $targetHubMasterFileName" -ForegroundColor Green
        }
    }
} else {
    Write-Warning "No markdown files found in hub-master folder"
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
Write-Host "  Storage Account: $storageAccountName" -ForegroundColor Green
Write-Host "  Location: $azRegion" -ForegroundColor Green
Write-Host "  Hub City: $hubCity (normalized: $normalizedHubCity)" -ForegroundColor Green
Write-Host ""
Write-Host "  Containers Created:" -ForegroundColor Green
foreach ($container in $containers) {
    Write-Host "    - $container" -ForegroundColor White
}
Write-Host ""
Write-Host "  Files Uploaded:" -ForegroundColor Green
Write-Host "    golden-repo/$hubDirectoryName/agenda_mapping.md" -ForegroundColor White
Write-Host "    golden-repo/$hubDirectoryName/documents/*.md (agenda documents)" -ForegroundColor White
Write-Host "    hub-master/$targetHubMasterFileName" -ForegroundColor White
Write-Host ""

# Save storage account name to a file for subsequent scripts
$outputConfigPath = Join-Path $deploymentDir "deployment-output.config"
@"
# Auto-generated by 01-deploy-blob-storage.ps1
# This file contains outputs needed by subsequent deployment scripts
storage-account-name=$storageAccountName
normalized-hub-city=$normalizedHubCity
"@ | Set-Content -Path $outputConfigPath

Write-Host "  Output saved to: $outputConfigPath" -ForegroundColor Yellow
Write-Host "  (This file will be used by subsequent deployment scripts)" -ForegroundColor Yellow

# Update input-config with the storage account name
Write-Host ""
Write-Host "Updating input-config with storage account name..." -ForegroundColor Cyan

$inputConfigContent = Get-Content $inputConfigPath -Raw

# Check if az-tab-storage-account already exists in the config
if ($inputConfigContent -match "az-tab-storage-account=") {
    # Update existing entry
    $inputConfigContent = $inputConfigContent -replace "az-tab-storage-account=.*", "az-tab-storage-account=$storageAccountName"
} else {
    # Add new entry (remove trailing whitespace and add new line)
    $inputConfigContent = $inputConfigContent.TrimEnd() + "`naz-tab-storage-account=$storageAccountName`n"
}

Set-Content -Path $inputConfigPath -Value $inputConfigContent -NoNewline
Write-Host "  Updated input-config with az-tab-storage-account=$storageAccountName" -ForegroundColor Green

Write-Host ""
Write-Host "Blob Storage deployment completed successfully!" -ForegroundColor Green
