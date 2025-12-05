<#
.SYNOPSIS
    Azure Automation Runbook for rotating Bot App client secret.

.DESCRIPTION
    This runbook is designed to run as a scheduled job in Azure Automation.
    It rotates the Bot App client secret and updates the Azure Container App.
    
    Required Azure Automation Setup:
    1. Create an Azure Automation Account
    2. Enable System-Assigned Managed Identity
    3. Grant the Managed Identity these permissions:
       - Microsoft Graph API: Application.ReadWrite.All
       - Azure RBAC: Contributor on the resource group
    4. Create Automation Variables for configuration
    5. Schedule to run every 20 days

.NOTES
    Automation Variables Required:
    - BotAppId: The Bot's App Registration ID
    - ContainerAppName: Name of the Azure Container App
    - ResourceGroupName: Resource group containing the Container App
    - SecretValidityDays: Number of days for secret validity (default: 25)
    
    The runbook uses the Automation Account's Managed Identity for authentication.
#>

param(
    [int]$SecretValidityDays = 25
)

$ErrorActionPreference = "Stop"

Write-Output "============================================"
Write-Output "TAB-Agent-Bot - Bot Secret Rotation (Automation Runbook)"
Write-Output "============================================"
Write-Output ""
Write-Output "Execution Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC')"
Write-Output ""

# ============================================================================
# STEP 0: Authenticate using Managed Identity
# ============================================================================

Write-Output "STEP 0: Authenticating with Managed Identity"

try {
    # Connect to Azure using the Automation Account's Managed Identity
    Connect-AzAccount -Identity | Out-Null
    Write-Output "  Successfully authenticated with Managed Identity."
} catch {
    Write-Error "Failed to authenticate with Managed Identity: $_"
    throw
}

# ============================================================================
# STEP 1: Retrieve Configuration from Automation Variables
# ============================================================================

Write-Output ""
Write-Output "STEP 1: Reading Configuration from Automation Variables"

try {
    $botAppId = Get-AutomationVariable -Name "BotAppId"
    $containerAppName = Get-AutomationVariable -Name "ContainerAppName"
    $resourceGroupName = Get-AutomationVariable -Name "ResourceGroupName"
    
    # Optional: Override default secret validity
    try {
        $configuredDays = Get-AutomationVariable -Name "SecretValidityDays"
        if ($configuredDays) {
            $SecretValidityDays = [int]$configuredDays
        }
    } catch {
        Write-Output "  Using default SecretValidityDays: $SecretValidityDays"
    }
    
    Write-Output "  Bot App ID: $botAppId"
    Write-Output "  Container App: $containerAppName"
    Write-Output "  Resource Group: $resourceGroupName"
    Write-Output "  Secret Validity: $SecretValidityDays days"
} catch {
    Write-Error "Failed to retrieve Automation Variables: $_"
    throw
}

# ============================================================================
# STEP 2: Generate New Client Secret using Microsoft Graph
# ============================================================================

Write-Output ""
Write-Output "STEP 2: Generating New Client Secret"

$endDate = (Get-Date).AddDays($SecretValidityDays)
$endDateString = $endDate.ToString("yyyy-MM-ddTHH:mm:ssZ")

try {
    # Get access token for Microsoft Graph
    $graphToken = (Get-AzAccessToken -ResourceUrl "https://graph.microsoft.com").Token
    
    # Prepare the request to add a new password credential
    $secretDisplayName = "TAB-Agent-Bot-Secret-Rotated-$(Get-Date -Format 'yyyyMMdd-HHmm')"
    
    $body = @{
        passwordCredential = @{
            displayName = $secretDisplayName
            endDateTime = $endDateString
        }
    } | ConvertTo-Json
    
    $headers = @{
        "Authorization" = "Bearer $graphToken"
        "Content-Type" = "application/json"
    }
    
    # Call Microsoft Graph API to add password
    $uri = "https://graph.microsoft.com/v1.0/applications(appId='$botAppId')/addPassword"
    
    Write-Output "  Creating new client secret..."
    $response = Invoke-RestMethod -Uri $uri -Method POST -Headers $headers -Body $body
    
    $newClientSecret = $response.secretText
    
    if (-not $newClientSecret) {
        throw "No secret text returned from Graph API"
    }
    
    Write-Output "  New client secret created successfully."
    Write-Output "  Secret Name: $secretDisplayName"
    Write-Output "  Expiry Date: $($endDate.ToString('yyyy-MM-dd'))"
} catch {
    Write-Error "Failed to create new client secret: $_"
    throw
}

# ============================================================================
# STEP 3: Update Container App Environment Variable
# ============================================================================

Write-Output ""
Write-Output "STEP 3: Updating Container App with New Secret"

try {
    Write-Output "  Updating CLIENT_SECRET environment variable..."
    
    # Get current container app configuration
    $containerApp = Get-AzContainerApp -Name $containerAppName -ResourceGroupName $resourceGroupName
    
    # Update the environment variable
    $envVars = $containerApp.TemplateContainer[0].Env
    
    # Find and update CLIENT_SECRET
    $secretUpdated = $false
    for ($i = 0; $i -lt $envVars.Count; $i++) {
        if ($envVars[$i].Name -eq "CLIENT_SECRET") {
            $envVars[$i].Value = $newClientSecret
            $secretUpdated = $true
            break
        }
    }
    
    if (-not $secretUpdated) {
        # Add CLIENT_SECRET if it doesn't exist
        $envVars += @{
            Name = "CLIENT_SECRET"
            Value = $newClientSecret
        }
    }
    
    # Update the container app
    $containerApp.TemplateContainer[0].Env = $envVars
    $containerApp | Update-AzContainerApp
    
    Write-Output "  Container App updated successfully."
    Write-Output "  The container will restart automatically with the new secret."
} catch {
    Write-Error "Failed to update Container App: $_"
    throw
}

# ============================================================================
# STEP 4: Clean Up Old Secrets (Optional)
# ============================================================================

Write-Output ""
Write-Output "STEP 4: Cleaning Up Expired Secrets"

try {
    # Get all password credentials for the app
    $uri = "https://graph.microsoft.com/v1.0/applications(appId='$botAppId')"
    $appDetails = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers
    
    $now = Get-Date
    $expiredSecrets = $appDetails.passwordCredentials | Where-Object {
        [DateTime]$_.endDateTime -lt $now
    }
    
    if ($expiredSecrets.Count -gt 0) {
        Write-Output "  Found $($expiredSecrets.Count) expired secret(s). Removing..."
        
        foreach ($secret in $expiredSecrets) {
            $removeBody = @{
                keyId = $secret.keyId
            } | ConvertTo-Json
            
            $removeUri = "https://graph.microsoft.com/v1.0/applications(appId='$botAppId')/removePassword"
            Invoke-RestMethod -Uri $removeUri -Method POST -Headers $headers -Body $removeBody
            Write-Output "    Removed expired secret: $($secret.displayName)"
        }
    } else {
        Write-Output "  No expired secrets to clean up."
    }
} catch {
    Write-Output "  Warning: Could not clean up old secrets: $_"
    # Don't fail the runbook for cleanup issues
}

# ============================================================================
# SUMMARY
# ============================================================================

Write-Output ""
Write-Output "============================================"
Write-Output "Secret Rotation Complete!"
Write-Output "============================================"
Write-Output ""
Write-Output "Summary:"
Write-Output "  Bot App ID: $botAppId"
Write-Output "  Container App: $containerAppName"
Write-Output "  New Secret Expiry: $($endDate.ToString('yyyy-MM-dd'))"
Write-Output "  Next Rotation Due: Before $($endDate.ToString('yyyy-MM-dd'))"
Write-Output ""
Write-Output "Secret rotation completed successfully!"
