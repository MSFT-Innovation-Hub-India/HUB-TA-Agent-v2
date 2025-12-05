#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Sets up Azure Automation Account for scheduled Bot secret rotation.

.DESCRIPTION
    This script creates and configures an Azure Automation Account to run
    the Bot secret rotation runbook on a schedule (every 20 days).
    
    It creates:
    - Azure Automation Account with System-Assigned Managed Identity
    - Automation Variables for configuration
    - PowerShell Runbook for secret rotation
    - Schedule to run every 20 days
    - Links the schedule to the runbook

.NOTES
    Prerequisites:
    - Azure CLI installed and configured
    - Run deployment scripts 01-04 first
    - User must have permissions to:
      - Create Automation Accounts
      - Assign RBAC roles
      - Grant Microsoft Graph API permissions

.PARAMETER WhatIf
    Shows what would happen without making changes.

.EXAMPLE
    .\11-setup-secret-rotation-automation.ps1
#>

param(
    [switch]$WhatIf = $false
)

$ErrorActionPreference = "Stop"

# ============================================================================
# CONFIGURATION
# ============================================================================

$scriptDir = $PSScriptRoot
$deploymentDir = Split-Path -Parent $scriptDir
$inputConfigPath = Join-Path $deploymentDir "input-config"
$runbookPath = Join-Path $scriptDir "runbooks\Rotate-BotSecret-Runbook.ps1"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "TAB-Agent-Bot - Setup Secret Rotation Automation" -ForegroundColor Cyan
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
$botAppId = $config["az-tab-bot-app-id"]
$containerAppName = $config["az-tab-containerapp-name"]

$normalizedHubCity = ($hubCity -replace '[^a-zA-Z0-9]', '').ToLower()
$automationAccountName = "az-$normalizedHubCity-automation"
$runbookName = "Rotate-BotSecret"
$scheduleName = "RotateBotSecret-Every20Days"

Write-Host "  Azure Region: $azRegion" -ForegroundColor Green
Write-Host "  Resource Group: $azResourceGroup" -ForegroundColor Green
Write-Host "  Automation Account: $automationAccountName" -ForegroundColor Green
Write-Host "  Bot App ID: $botAppId" -ForegroundColor Green
Write-Host "  Container App: $containerAppName" -ForegroundColor Green
Write-Host ""

# ============================================================================
# STEP 1: Create Automation Account
# ============================================================================

Write-Host "STEP 1: Creating Azure Automation Account" -ForegroundColor Cyan

if ($WhatIf) {
    Write-Host "  [WhatIf] Would create Automation Account: $automationAccountName" -ForegroundColor Magenta
} else {
    # Check if automation account exists
    $accountExists = az automation account show --name $automationAccountName --resource-group $azResourceGroup 2>$null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Automation Account '$automationAccountName' already exists." -ForegroundColor Yellow
    } else {
        Write-Host "  Creating Automation Account: $automationAccountName..." -ForegroundColor Yellow
        
        az automation account create `
            --name $automationAccountName `
            --resource-group $azResourceGroup `
            --location $azRegion `
            --sku Basic `
            --output none
        
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to create Automation Account"
            exit 1
        }
        Write-Host "  Automation Account created successfully." -ForegroundColor Green
    }
}

Write-Host ""

# ============================================================================
# STEP 2: Enable System-Assigned Managed Identity
# ============================================================================

Write-Host "STEP 2: Enabling System-Assigned Managed Identity" -ForegroundColor Cyan

$managedIdentityPrincipalId = $null

if ($WhatIf) {
    Write-Host "  [WhatIf] Would enable System-Assigned Managed Identity" -ForegroundColor Magenta
} else {
    Write-Host "  Enabling Managed Identity..." -ForegroundColor Yellow
    
    $identityResult = az automation account update `
        --name $automationAccountName `
        --resource-group $azResourceGroup `
        --identity-type SystemAssigned `
        --query "identity.principalId" -o tsv 2>&1
    
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to enable Managed Identity: $identityResult"
        exit 1
    }
    
    $managedIdentityPrincipalId = $identityResult
    Write-Host "  Managed Identity enabled." -ForegroundColor Green
    Write-Host "  Principal ID: $managedIdentityPrincipalId" -ForegroundColor Green
}

Write-Host ""

# ============================================================================
# STEP 3: Assign RBAC Role for Container App Management
# ============================================================================

Write-Host "STEP 3: Assigning RBAC Role for Container App Management" -ForegroundColor Cyan

if ($WhatIf) {
    Write-Host "  [WhatIf] Would assign Contributor role on resource group" -ForegroundColor Magenta
} else {
    Write-Host "  Assigning Contributor role on resource group..." -ForegroundColor Yellow
    
    $subscriptionId = az account show --query id -o tsv
    $scope = "/subscriptions/$subscriptionId/resourceGroups/$azResourceGroup"
    
    az role assignment create `
        --assignee-object-id $managedIdentityPrincipalId `
        --assignee-principal-type ServicePrincipal `
        --role "Contributor" `
        --scope $scope `
        --output none 2>$null
    
    # Ignore error if role already assigned
    Write-Host "  Contributor role assigned." -ForegroundColor Green
}

Write-Host ""

# ============================================================================
# STEP 4: Grant Microsoft Graph API Permissions
# ============================================================================

Write-Host "STEP 4: Granting Microsoft Graph API Permissions" -ForegroundColor Cyan
Write-Host ""
Write-Host "  IMPORTANT: This step requires manual configuration in Azure Portal." -ForegroundColor Yellow
Write-Host ""
Write-Host "  Please follow these steps:" -ForegroundColor Cyan
Write-Host "  1. Go to Azure Portal > Microsoft Entra ID > Enterprise Applications" -ForegroundColor White
Write-Host "  2. Find the Managed Identity: $automationAccountName" -ForegroundColor White
Write-Host "  3. Go to Permissions > Grant admin consent" -ForegroundColor White
Write-Host "  4. Or use the following PowerShell commands:" -ForegroundColor White
Write-Host ""
Write-Host "  # Install Microsoft Graph PowerShell module if not installed" -ForegroundColor Gray
Write-Host "  Install-Module Microsoft.Graph -Scope CurrentUser" -ForegroundColor Gray
Write-Host ""
Write-Host "  # Connect and grant permission" -ForegroundColor Gray
Write-Host "  Connect-MgGraph -Scopes 'Application.ReadWrite.All','AppRoleAssignment.ReadWrite.All'" -ForegroundColor Gray
Write-Host "  `$graphApp = Get-MgServicePrincipal -Filter `"appId eq '00000003-0000-0000-c000-000000000000'`"" -ForegroundColor Gray
Write-Host "  `$appRole = `$graphApp.AppRoles | Where-Object { `$_.Value -eq 'Application.ReadWrite.All' }" -ForegroundColor Gray
Write-Host "  `$msi = Get-MgServicePrincipal -Filter `"displayName eq '$automationAccountName'`"" -ForegroundColor Gray
Write-Host "  New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId `$msi.Id -PrincipalId `$msi.Id -ResourceId `$graphApp.Id -AppRoleId `$appRole.Id" -ForegroundColor Gray
Write-Host ""

# ============================================================================
# STEP 5: Create Automation Variables
# ============================================================================

Write-Host "STEP 5: Creating Automation Variables" -ForegroundColor Cyan

$variables = @(
    @{ Name = "BotAppId"; Value = $botAppId; Description = "Bot App Registration ID" },
    @{ Name = "ContainerAppName"; Value = $containerAppName; Description = "Azure Container App name" },
    @{ Name = "ResourceGroupName"; Value = $azResourceGroup; Description = "Resource Group name" },
    @{ Name = "SecretValidityDays"; Value = "25"; Description = "Secret validity in days" }
)

if ($WhatIf) {
    foreach ($var in $variables) {
        Write-Host "  [WhatIf] Would create variable: $($var.Name) = $($var.Value)" -ForegroundColor Magenta
    }
} else {
    foreach ($var in $variables) {
        Write-Host "  Creating variable: $($var.Name)..." -ForegroundColor Yellow
        
        # Check if variable exists
        $varExists = az automation variable show `
            --automation-account-name $automationAccountName `
            --resource-group $azResourceGroup `
            --name $var.Name 2>$null
        
        if ($LASTEXITCODE -eq 0) {
            # Update existing variable
            az automation variable update `
                --automation-account-name $automationAccountName `
                --resource-group $azResourceGroup `
                --name $var.Name `
                --value "`"$($var.Value)`"" `
                --output none
        } else {
            # Create new variable
            az automation variable create `
                --automation-account-name $automationAccountName `
                --resource-group $azResourceGroup `
                --name $var.Name `
                --value "`"$($var.Value)`"" `
                --description $var.Description `
                --output none
        }
        
        Write-Host "    $($var.Name) = $($var.Value)" -ForegroundColor Green
    }
}

Write-Host ""

# ============================================================================
# STEP 6: Import PowerShell Modules
# ============================================================================

Write-Host "STEP 6: Importing Required PowerShell Modules" -ForegroundColor Cyan

$modules = @("Az.Accounts", "Az.App")

if ($WhatIf) {
    foreach ($module in $modules) {
        Write-Host "  [WhatIf] Would import module: $module" -ForegroundColor Magenta
    }
} else {
    foreach ($module in $modules) {
        Write-Host "  Importing module: $module..." -ForegroundColor Yellow
        
        # Check if module exists
        $moduleExists = az automation module show `
            --automation-account-name $automationAccountName `
            --resource-group $azResourceGroup `
            --name $module 2>$null
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    Module '$module' already exists." -ForegroundColor Yellow
        } else {
            # Import from PowerShell Gallery
            $contentLink = "https://www.powershellgallery.com/api/v2/package/$module"
            
            az automation module create `
                --automation-account-name $automationAccountName `
                --resource-group $azResourceGroup `
                --name $module `
                --content-link $contentLink `
                --output none 2>$null
            
            Write-Host "    Module '$module' import initiated." -ForegroundColor Green
        }
    }
    
    Write-Host "  Note: Modules may take a few minutes to fully import." -ForegroundColor Yellow
}

Write-Host ""

# ============================================================================
# STEP 7: Create Runbook
# ============================================================================

Write-Host "STEP 7: Creating Runbook" -ForegroundColor Cyan

if ($WhatIf) {
    Write-Host "  [WhatIf] Would create runbook: $runbookName" -ForegroundColor Magenta
} else {
    Write-Host "  Creating runbook: $runbookName..." -ForegroundColor Yellow
    
    # Create or update runbook
    az automation runbook create `
        --automation-account-name $automationAccountName `
        --resource-group $azResourceGroup `
        --name $runbookName `
        --type PowerShell `
        --description "Rotates Bot App client secret and updates Container App" `
        --output none 2>$null
    
    # Upload runbook content
    if (Test-Path $runbookPath) {
        Write-Host "  Uploading runbook content..." -ForegroundColor Yellow
        
        az automation runbook replace-content `
            --automation-account-name $automationAccountName `
            --resource-group $azResourceGroup `
            --name $runbookName `
            --content @$runbookPath `
            --output none
        
        # Publish runbook
        Write-Host "  Publishing runbook..." -ForegroundColor Yellow
        
        az automation runbook publish `
            --automation-account-name $automationAccountName `
            --resource-group $azResourceGroup `
            --name $runbookName `
            --output none
        
        Write-Host "  Runbook created and published." -ForegroundColor Green
    } else {
        Write-Warning "Runbook file not found at: $runbookPath"
        Write-Host "  Please upload the runbook content manually via Azure Portal." -ForegroundColor Yellow
    }
}

Write-Host ""

# ============================================================================
# STEP 8: Create Schedule
# ============================================================================

Write-Host "STEP 8: Creating Schedule (Every 20 Days)" -ForegroundColor Cyan

$startTime = (Get-Date).AddDays(20).ToString("yyyy-MM-ddT09:00:00+00:00")

if ($WhatIf) {
    Write-Host "  [WhatIf] Would create schedule: $scheduleName" -ForegroundColor Magenta
    Write-Host "  [WhatIf] First run: $startTime" -ForegroundColor Magenta
} else {
    Write-Host "  Creating schedule: $scheduleName..." -ForegroundColor Yellow
    
    # Delete existing schedule if exists
    az automation schedule delete `
        --automation-account-name $automationAccountName `
        --resource-group $azResourceGroup `
        --name $scheduleName `
        --yes `
        --output none 2>$null
    
    # Create new schedule (every 20 days)
    az automation schedule create `
        --automation-account-name $automationAccountName `
        --resource-group $azResourceGroup `
        --name $scheduleName `
        --description "Runs every 20 days to rotate Bot secret before expiry" `
        --frequency Day `
        --interval 20 `
        --start-time $startTime `
        --output none
    
    Write-Host "  Schedule created." -ForegroundColor Green
    Write-Host "  First run: $startTime" -ForegroundColor Green
    Write-Host "  Frequency: Every 20 days" -ForegroundColor Green
}

Write-Host ""

# ============================================================================
# STEP 9: Link Schedule to Runbook
# ============================================================================

Write-Host "STEP 9: Linking Schedule to Runbook" -ForegroundColor Cyan

if ($WhatIf) {
    Write-Host "  [WhatIf] Would link schedule to runbook" -ForegroundColor Magenta
} else {
    Write-Host "  Linking schedule to runbook..." -ForegroundColor Yellow
    
    # Note: Azure CLI doesn't have a direct command for this
    # Need to use Azure Portal or PowerShell Az module
    Write-Host ""
    Write-Host "  IMPORTANT: Complete this step manually in Azure Portal:" -ForegroundColor Yellow
    Write-Host "  1. Go to Azure Portal > Automation Accounts > $automationAccountName" -ForegroundColor White
    Write-Host "  2. Navigate to Runbooks > $runbookName" -ForegroundColor White
    Write-Host "  3. Click 'Link to schedule'" -ForegroundColor White
    Write-Host "  4. Select '$scheduleName'" -ForegroundColor White
    Write-Host "  5. Click OK" -ForegroundColor White
    Write-Host ""
}

# ============================================================================
# SUMMARY
# ============================================================================

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Setup Complete!" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Resources Created:" -ForegroundColor Green
Write-Host "  Automation Account: $automationAccountName" -ForegroundColor White
Write-Host "  Runbook: $runbookName" -ForegroundColor White
Write-Host "  Schedule: $scheduleName (every 20 days)" -ForegroundColor White
Write-Host ""
Write-Host "Remaining Manual Steps:" -ForegroundColor Yellow
Write-Host "  1. Grant Microsoft Graph 'Application.ReadWrite.All' permission to Managed Identity" -ForegroundColor White
Write-Host "  2. Link the schedule to the runbook in Azure Portal" -ForegroundColor White
Write-Host ""

# Save automation account name to input-config
if (-not $WhatIf) {
    $inputConfigContent = Get-Content $inputConfigPath -Raw
    if ($inputConfigContent -match "az-tab-automation-account=") {
        $inputConfigContent = $inputConfigContent -replace "az-tab-automation-account=.*", "az-tab-automation-account=$automationAccountName"
    } else {
        $inputConfigContent = $inputConfigContent.TrimEnd() + "`naz-tab-automation-account=$automationAccountName`n"
    }
    Set-Content -Path $inputConfigPath -Value $inputConfigContent -NoNewline
    Write-Host "  Updated input-config with az-tab-automation-account=$automationAccountName" -ForegroundColor Green
}

Write-Host ""
Write-Host "Automation setup completed!" -ForegroundColor Green
