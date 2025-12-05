#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Grants Microsoft Graph API permissions to the Automation Account's Managed Identity.

.DESCRIPTION
    This script grants the 'Application.ReadWrite.All' permission from Microsoft Graph API
    to the Azure Automation Account's Managed Identity. This permission is required for
    the secret rotation runbook to create new client secrets for the Bot App Registration.
    
    This script must be run by a user with:
    - Global Administrator or Privileged Role Administrator role in Entra ID
    - Or Application Administrator + ability to grant admin consent

.NOTES
    Prerequisites:
    - Microsoft.Graph PowerShell module
    - Run script 11-setup-secret-rotation-automation.ps1 first
    - Admin permissions in Microsoft Entra ID

.PARAMETER AutomationAccountName
    The name of the Azure Automation Account. If not provided, reads from input-config.

.PARAMETER WhatIf
    Shows what would happen without making changes.

.EXAMPLE
    .\12-grant-graph-permissions.ps1
    
.EXAMPLE
    .\12-grant-graph-permissions.ps1 -AutomationAccountName "az-bengaluru-automation"
#>

param(
    [string]$AutomationAccountName,
    [switch]$WhatIf = $false
)

$ErrorActionPreference = "Stop"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Grant Microsoft Graph Permissions to Managed Identity" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# STEP 0: Check/Install Microsoft.Graph Module
# ============================================================================

Write-Host "STEP 0: Checking Microsoft.Graph PowerShell Module" -ForegroundColor Cyan

$graphModule = Get-Module -ListAvailable -Name "Microsoft.Graph.Applications"

if (-not $graphModule) {
    Write-Host "  Microsoft.Graph module not found. Installing..." -ForegroundColor Yellow
    
    if ($WhatIf) {
        Write-Host "  [WhatIf] Would install Microsoft.Graph module" -ForegroundColor Magenta
    } else {
        try {
            Install-Module Microsoft.Graph -Scope CurrentUser -Force -AllowClobber
            Write-Host "  Microsoft.Graph module installed successfully." -ForegroundColor Green
        } catch {
            Write-Error "Failed to install Microsoft.Graph module. Please run: Install-Module Microsoft.Graph -Scope CurrentUser"
            exit 1
        }
    }
} else {
    Write-Host "  Microsoft.Graph module is installed." -ForegroundColor Green
}

Write-Host ""

# ============================================================================
# STEP 1: Read Configuration
# ============================================================================

Write-Host "STEP 1: Reading Configuration" -ForegroundColor Cyan

if (-not $AutomationAccountName) {
    $scriptDir = $PSScriptRoot
    $deploymentDir = Split-Path -Parent $scriptDir
    $inputConfigPath = Join-Path $deploymentDir "input-config"
    
    if (Test-Path $inputConfigPath) {
        $config = @{}
        Get-Content $inputConfigPath | ForEach-Object {
            if ($_ -match "^([^#][^=]*)=(.*)$") {
                $config[$matches[1].Trim()] = $matches[2].Trim()
            }
        }
        
        $AutomationAccountName = $config["az-tab-automation-account"]
        
        if (-not $AutomationAccountName) {
            # Derive from hub city if not explicitly set
            $hubCity = $config["hub-city"]
            if ($hubCity) {
                $normalizedHubCity = ($hubCity -replace '[^a-zA-Z0-9]', '').ToLower()
                $AutomationAccountName = "az-$normalizedHubCity-automation"
            }
        }
    }
}

if (-not $AutomationAccountName) {
    Write-Error "AutomationAccountName not provided and could not be determined from input-config"
    exit 1
}

Write-Host "  Automation Account: $AutomationAccountName" -ForegroundColor Green
Write-Host ""

# ============================================================================
# STEP 2: Connect to Microsoft Graph
# ============================================================================

Write-Host "STEP 2: Connecting to Microsoft Graph" -ForegroundColor Cyan

if ($WhatIf) {
    Write-Host "  [WhatIf] Would connect to Microsoft Graph" -ForegroundColor Magenta
} else {
    Write-Host "  Connecting to Microsoft Graph (browser authentication will open)..." -ForegroundColor Yellow
    Write-Host "  Required scopes: Application.ReadWrite.All, AppRoleAssignment.ReadWrite.All" -ForegroundColor Gray
    
    try {
        # Disconnect any existing session
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        
        # Connect with required scopes
        Connect-MgGraph -Scopes "Application.ReadWrite.All", "AppRoleAssignment.ReadWrite.All" -NoWelcome
        
        $context = Get-MgContext
        Write-Host "  Connected as: $($context.Account)" -ForegroundColor Green
        Write-Host "  Tenant: $($context.TenantId)" -ForegroundColor Green
    } catch {
        Write-Error "Failed to connect to Microsoft Graph: $_"
        exit 1
    }
}

Write-Host ""

# ============================================================================
# STEP 3: Get Microsoft Graph Service Principal
# ============================================================================

Write-Host "STEP 3: Getting Microsoft Graph Service Principal" -ForegroundColor Cyan

$graphAppId = "00000003-0000-0000-c000-000000000000"  # Microsoft Graph App ID (constant)

if ($WhatIf) {
    Write-Host "  [WhatIf] Would get Microsoft Graph service principal" -ForegroundColor Magenta
    $graphSp = @{ Id = "WHATIF-GRAPH-SP-ID" }
    $appRole = @{ Id = "WHATIF-APP-ROLE-ID" }
} else {
    try {
        $graphSp = Get-MgServicePrincipal -Filter "appId eq '$graphAppId'"
        
        if (-not $graphSp) {
            Write-Error "Microsoft Graph service principal not found"
            exit 1
        }
        
        Write-Host "  Found Microsoft Graph service principal" -ForegroundColor Green
        Write-Host "    ID: $($graphSp.Id)" -ForegroundColor Gray
        
        # Get the Application.ReadWrite.All app role
        $appRole = $graphSp.AppRoles | Where-Object { $_.Value -eq "Application.ReadWrite.All" }
        
        if (-not $appRole) {
            Write-Error "Application.ReadWrite.All role not found in Microsoft Graph"
            exit 1
        }
        
        Write-Host "  Found 'Application.ReadWrite.All' role" -ForegroundColor Green
        Write-Host "    Role ID: $($appRole.Id)" -ForegroundColor Gray
    } catch {
        Write-Error "Failed to get Microsoft Graph service principal: $_"
        exit 1
    }
}

Write-Host ""

# ============================================================================
# STEP 4: Get Automation Account's Managed Identity
# ============================================================================

Write-Host "STEP 4: Getting Managed Identity for '$AutomationAccountName'" -ForegroundColor Cyan

if ($WhatIf) {
    Write-Host "  [WhatIf] Would get Managed Identity service principal" -ForegroundColor Magenta
    $msiSp = @{ Id = "WHATIF-MSI-SP-ID"; DisplayName = $AutomationAccountName }
} else {
    try {
        $msiSp = Get-MgServicePrincipal -Filter "displayName eq '$AutomationAccountName'"
        
        if (-not $msiSp) {
            Write-Error "Managed Identity '$AutomationAccountName' not found. Ensure the Automation Account exists and has System-Assigned Managed Identity enabled."
            exit 1
        }
        
        Write-Host "  Found Managed Identity" -ForegroundColor Green
        Write-Host "    Display Name: $($msiSp.DisplayName)" -ForegroundColor Gray
        Write-Host "    Object ID: $($msiSp.Id)" -ForegroundColor Gray
        Write-Host "    App ID: $($msiSp.AppId)" -ForegroundColor Gray
    } catch {
        Write-Error "Failed to get Managed Identity: $_"
        exit 1
    }
}

Write-Host ""

# ============================================================================
# STEP 5: Check Existing Permissions
# ============================================================================

Write-Host "STEP 5: Checking Existing Permissions" -ForegroundColor Cyan

$permissionExists = $false

if ($WhatIf) {
    Write-Host "  [WhatIf] Would check existing permissions" -ForegroundColor Magenta
} else {
    try {
        $existingAssignments = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $msiSp.Id
        
        $existingPermission = $existingAssignments | Where-Object { 
            $_.AppRoleId -eq $appRole.Id -and $_.ResourceId -eq $graphSp.Id 
        }
        
        if ($existingPermission) {
            $permissionExists = $true
            Write-Host "  Permission 'Application.ReadWrite.All' already granted." -ForegroundColor Yellow
            Write-Host "  No action needed." -ForegroundColor Yellow
        } else {
            Write-Host "  Permission not yet granted. Will grant now." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  Could not check existing permissions. Will attempt to grant." -ForegroundColor Yellow
    }
}

Write-Host ""

# ============================================================================
# STEP 6: Grant Permission
# ============================================================================

Write-Host "STEP 6: Granting 'Application.ReadWrite.All' Permission" -ForegroundColor Cyan

if ($permissionExists) {
    Write-Host "  Skipping - permission already exists." -ForegroundColor Yellow
} elseif ($WhatIf) {
    Write-Host "  [WhatIf] Would grant Application.ReadWrite.All permission to Managed Identity" -ForegroundColor Magenta
} else {
    try {
        Write-Host "  Granting permission..." -ForegroundColor Yellow
        
        $params = @{
            ServicePrincipalId = $msiSp.Id
            PrincipalId = $msiSp.Id
            ResourceId = $graphSp.Id
            AppRoleId = $appRole.Id
        }
        
        New-MgServicePrincipalAppRoleAssignment @params | Out-Null
        
        Write-Host "  Permission granted successfully!" -ForegroundColor Green
    } catch {
        if ($_.Exception.Message -like "*Permission being assigned already exists*") {
            Write-Host "  Permission already exists (race condition). OK." -ForegroundColor Yellow
        } else {
            Write-Error "Failed to grant permission: $_"
            exit 1
        }
    }
}

Write-Host ""

# ============================================================================
# STEP 7: Verify Permission
# ============================================================================

Write-Host "STEP 7: Verifying Permission" -ForegroundColor Cyan

if ($WhatIf) {
    Write-Host "  [WhatIf] Would verify permission was granted" -ForegroundColor Magenta
} else {
    try {
        Start-Sleep -Seconds 2  # Brief wait for propagation
        
        $assignments = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $msiSp.Id
        
        $verified = $assignments | Where-Object { 
            $_.AppRoleId -eq $appRole.Id -and $_.ResourceId -eq $graphSp.Id 
        }
        
        if ($verified) {
            Write-Host "  Verified: Application.ReadWrite.All permission is active." -ForegroundColor Green
        } else {
            Write-Host "  Warning: Could not verify permission. It may take a few minutes to propagate." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  Warning: Could not verify permission. Check Azure Portal to confirm." -ForegroundColor Yellow
    }
}

Write-Host ""

# ============================================================================
# SUMMARY
# ============================================================================

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Permission Grant Complete!" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Summary:" -ForegroundColor Green
Write-Host "  Managed Identity: $AutomationAccountName" -ForegroundColor White
Write-Host "  Permission: Application.ReadWrite.All (Microsoft Graph)" -ForegroundColor White
Write-Host ""
Write-Host "Next Step:" -ForegroundColor Yellow
Write-Host "  Link the schedule to the runbook in Azure Portal:" -ForegroundColor White
Write-Host "  1. Go to Automation Accounts > $AutomationAccountName" -ForegroundColor Gray
Write-Host "  2. Click Runbooks > Rotate-BotSecret" -ForegroundColor Gray
Write-Host "  3. Click 'Link to schedule'" -ForegroundColor Gray
Write-Host "  4. Select 'RotateBotSecret-Every20Days'" -ForegroundColor Gray
Write-Host ""

# Disconnect from Graph
if (-not $WhatIf) {
    Disconnect-MgGraph | Out-Null
    Write-Host "Disconnected from Microsoft Graph." -ForegroundColor Gray
}

Write-Host ""
Write-Host "Done!" -ForegroundColor Green
