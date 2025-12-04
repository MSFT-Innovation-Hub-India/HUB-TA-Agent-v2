<#
.SYNOPSIS
    Configures environment variables for the TAB Agent Bot Container App.

.DESCRIPTION
    This script sets all required environment variables on the Azure Container App
    by reading values from the input-config file. This includes bot credentials,
    Azure OpenAI settings, blob storage settings, and other configuration.

.PARAMETER WhatIf
    Shows what would happen without making changes.

.EXAMPLE
    .\09-configure-container-app-env.ps1
    
.EXAMPLE
    .\09-configure-container-app-env.ps1 -WhatIf
#>

param(
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Step 9: Configure Container App Environment Variables" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Read input-config
$inputConfigPath = Join-Path $PSScriptRoot "..\input-config"
if (-not (Test-Path $inputConfigPath)) {
    Write-Error "input-config file not found at: $inputConfigPath"
    exit 1
}

Write-Host "`nReading configuration from input-config..." -ForegroundColor Yellow

# Parse input-config into a hashtable
$config = @{}
Get-Content $inputConfigPath | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith("#")) {
        $parts = $line -split "=", 2
        if ($parts.Count -eq 2) {
            $key = $parts[0].Trim()
            $value = $parts[1].Trim()
            # Remove quotes if present
            if ($value.StartsWith('"') -and $value.EndsWith('"')) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            $config[$key] = $value
        }
    }
}

# Validate required configuration values
$requiredKeys = @(
    "az-tab-rg",
    "az-tab-containerapp-name",
    "az-tab-bot-tenant-id",
    "az-tab-bot-app-id",
    "az-tab-bot-client-secret",
    "host-entra-tenant-id",
    "az-tab-openai-endpoint",
    "az-tab-openai-deployment",
    "az_openai_api_version",
    "hub_cities",
    "hub_assistant_file_ids",
    "hub-doc-template-fileid",
    "az-tab-storage-account",
    "az_blob_container_name",
    "az_blob_container_name_hubmaster",
    "az_blob_container_name_state",
    "az_blob_golden_docs_container_name",
    "az-subscription-id",
    "log_level",
    "az-tab-appinsights-connection-string"
)

$missingKeys = @()
foreach ($key in $requiredKeys) {
    if (-not $config.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($config[$key])) {
        $missingKeys += $key
    }
}

if ($missingKeys.Count -gt 0) {
    Write-Error "Missing required configuration values in input-config: $($missingKeys -join ', ')"
    exit 1
}

# Extract values
$resourceGroup = $config["az-tab-rg"]
$containerAppName = $config["az-tab-containerapp-name"]

Write-Host "`nConfiguration Summary:" -ForegroundColor Green
Write-Host "  Resource Group: $resourceGroup"
Write-Host "  Container App: $containerAppName"

# Build environment variables mapping
# Format: "ENV_VAR_NAME=value"
$envVars = @(
    # Bot credentials
    "TENANT_ID=$($config["az-tab-bot-tenant-id"])",
    "CLIENT_ID=$($config["az-tab-bot-app-id"])",
    "CLIENT_SECRET=$($config["az-tab-bot-client-secret"])",
    "HOST_TENANT_ID=$($config["host-entra-tenant-id"])",
    
    # Azure OpenAI settings
    "az_openai_endpoint=$($config["az-tab-openai-endpoint"])",
    "az_deployment_name=$($config["az-tab-openai-deployment"])",
    "az_openai_api_version=$($config["az_openai_api_version"])",
    
    # Hub configuration
    "hub_cities=$($config["hub_cities"])",
    "hub_assistant_file_ids=$($config["hub_assistant_file_ids"])",
    "file_ids=$($config["hub-doc-template-fileid"])",
    
    # Blob storage settings
    "az_blob_storage_account_name=$($config["az-tab-storage-account"])",
    "az_blob_container_name=$($config["az_blob_container_name"])",
    "az_blob_container_name_hubmaster=$($config["az_blob_container_name_hubmaster"])",
    "az_blob_container_name_state=$($config["az_blob_container_name_state"])",
    "az_blob_golden_docs_container_name=$($config["az_blob_golden_docs_container_name"])",
    "az_storage_rg=$($config["az-tab-rg"])",
    "az_subscription_id=$($config["az-subscription-id"])",
    
    # Logging and monitoring
    "log_level=$($config["log_level"])",
    "az_application_insights_key=$($config["az-tab-appinsights-connection-string"])"
)

Write-Host "`nEnvironment Variables to be set:" -ForegroundColor Yellow
Write-Host "  Bot Credentials:" -ForegroundColor Cyan
Write-Host "    TENANT_ID = $($config["az-tab-bot-tenant-id"])"
Write-Host "    CLIENT_ID = $($config["az-tab-bot-app-id"])"
Write-Host "    CLIENT_SECRET = ********** (hidden)"
Write-Host "    HOST_TENANT_ID = $($config["host-entra-tenant-id"])"

Write-Host "  Azure OpenAI:" -ForegroundColor Cyan
Write-Host "    az_openai_endpoint = $($config["az-tab-openai-endpoint"])"
Write-Host "    az_deployment_name = $($config["az-tab-openai-deployment"])"
Write-Host "    az_openai_api_version = $($config["az_openai_api_version"])"

Write-Host "  Hub Configuration:" -ForegroundColor Cyan
Write-Host "    hub_cities = $($config["hub_cities"].Substring(0, [Math]::Min(50, $config["hub_cities"].Length)))..."
Write-Host "    hub_assistant_file_ids = $($config["hub_assistant_file_ids"])"
Write-Host "    file_ids = $($config["hub-doc-template-fileid"])"

Write-Host "  Blob Storage:" -ForegroundColor Cyan
Write-Host "    az_blob_storage_account_name = $($config["az-tab-storage-account"])"
Write-Host "    az_blob_container_name = $($config["az_blob_container_name"])"
Write-Host "    az_blob_container_name_hubmaster = $($config["az_blob_container_name_hubmaster"])"
Write-Host "    az_blob_container_name_state = $($config["az_blob_container_name_state"])"
Write-Host "    az_blob_golden_docs_container_name = $($config["az_blob_golden_docs_container_name"])"
Write-Host "    az_storage_rg = $($config["az-tab-rg"])"
Write-Host "    az_subscription_id = $($config["az-subscription-id"])"

Write-Host "  Logging & Monitoring:" -ForegroundColor Cyan
Write-Host "    log_level = $($config["log_level"])"
Write-Host "    az_application_insights_key = ********** (hidden)"

if ($WhatIf) {
    Write-Host "`n[WhatIf] Would update Container App '$containerAppName' with environment variables" -ForegroundColor Magenta
    Write-Host "[WhatIf] Command that would be run:" -ForegroundColor Magenta
    Write-Host "az containerapp update --name $containerAppName --resource-group $resourceGroup --set-env-vars <env-vars>" -ForegroundColor Gray
    exit 0
}

# Update Container App with environment variables
Write-Host "`nUpdating Container App environment variables..." -ForegroundColor Yellow
Write-Host "This may take a few minutes as the container app restarts..." -ForegroundColor Gray

try {
    # Use az containerapp update with --set-env-vars
    # Pass environment variables as separate arguments to avoid escaping issues
    Write-Host "Executing update command..." -ForegroundColor Gray
    
    $result = az containerapp update `
        --name $containerAppName `
        --resource-group $resourceGroup `
        --set-env-vars `
        "TENANT_ID=$($config["az-tab-bot-tenant-id"])" `
        "CLIENT_ID=$($config["az-tab-bot-app-id"])" `
        "CLIENT_SECRET=$($config["az-tab-bot-client-secret"])" `
        "HOST_TENANT_ID=$($config["host-entra-tenant-id"])" `
        "az_openai_endpoint=$($config["az-tab-openai-endpoint"])" `
        "az_deployment_name=$($config["az-tab-openai-deployment"])" `
        "az_openai_api_version=$($config["az_openai_api_version"])" `
        "hub_cities=$($config["hub_cities"])" `
        "hub_assistant_file_ids=$($config["hub_assistant_file_ids"])" `
        "file_ids=$($config["hub-doc-template-fileid"])" `
        "az_blob_storage_account_name=$($config["az-tab-storage-account"])" `
        "az_blob_container_name=$($config["az_blob_container_name"])" `
        "az_blob_container_name_hubmaster=$($config["az_blob_container_name_hubmaster"])" `
        "az_blob_container_name_state=$($config["az_blob_container_name_state"])" `
        "az_blob_golden_docs_container_name=$($config["az_blob_golden_docs_container_name"])" `
        "az_storage_rg=$($config["az-tab-rg"])" `
        "az_subscription_id=$($config["az-subscription-id"])" `
        "log_level=$($config["log_level"])" `
        "az_application_insights_key=$($config["az-tab-appinsights-connection-string"])" `
        --output none 2>&1
    
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to update Container App environment variables: $result"
        exit 1
    }
    
    Write-Host "`nContainer App environment variables updated successfully!" -ForegroundColor Green
}
catch {
    Write-Error "Failed to update Container App: $_"
    exit 1
}

# Verify the update
Write-Host "`nVerifying environment variables..." -ForegroundColor Yellow
try {
    $containerAppJson = az containerapp show --name $containerAppName --resource-group $resourceGroup --query "properties.template.containers[0].env" -o json 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        $envCount = ($containerAppJson | ConvertFrom-Json).Count
        Write-Host "Container App now has $envCount environment variables configured." -ForegroundColor Green
    }
}
catch {
    Write-Host "Warning: Could not verify environment variables, but update may have succeeded." -ForegroundColor Yellow
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Step 9 Complete!" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "`nSummary:" -ForegroundColor Green
Write-Host "  Container App: $containerAppName"
Write-Host "  Environment Variables Set: $($envVars.Count)"
Write-Host "`nThe Container App will restart automatically with the new configuration."
Write-Host "You can verify the deployment by checking the Container App in the Azure Portal."
