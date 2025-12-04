#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Uploads document template to Azure OpenAI for Assistants API.

.DESCRIPTION
    This script automates:
    - Uploading the Innovation Hub Agenda Format document to Azure OpenAI
    - Setting the file purpose as 'assistants'
    - Saving the file_id to input-config

.NOTES
    Prerequisites:
    - Azure CLI installed and configured
    - Run scripts 01-07 before this script
    - Run this script from the 'deployment-scripts' folder
    - The document 'Innovation Hub Agenda Format.docx' must exist in deployment folder
    
    Authentication:
    - Uses Azure OpenAI API key from input-config
    
    Idempotency:
    - Script will upload the file each time (Azure OpenAI doesn't deduplicate files)
    - Check input-config for existing file_id before running if you want to avoid duplicates
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
$documentPath = Join-Path $deploymentDir "Innovation Hub Agenda Format.docx"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "TAB-Agent-Bot - Upload Document to Azure OpenAI" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Check if document exists
if (-not (Test-Path $documentPath)) {
    Write-Error "Document not found: $documentPath"
    Write-Host "Please ensure 'Innovation Hub Agenda Format.docx' exists in the deployment folder."
    exit 1
}

Write-Host "Document found: $documentPath" -ForegroundColor Green
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

$openAIEndpoint = $config["az-tab-openai-endpoint"]
$openAIKey = $config["az-tab-openai-key"]

Write-Host "  Azure OpenAI Endpoint: $openAIEndpoint" -ForegroundColor Green
Write-Host ""

# Validate required configurations
if (-not $openAIEndpoint -or -not $openAIKey) {
    Write-Error "Missing Azure OpenAI configuration. Please run 06-deploy-azure-openai.ps1 first."
    exit 1
}

# ============================================================================
# STEP 1: Upload Document to Azure OpenAI
# ============================================================================

Write-Host "STEP 1: Uploading Document to Azure OpenAI" -ForegroundColor Cyan

$fileId = $null

if (-not $WhatIf) {
    Write-Host "  Uploading 'Innovation Hub Agenda Format.docx' with purpose 'assistants'..." -ForegroundColor Yellow
    
    # Construct the API URL for file upload
    $uploadUrl = "${openAIEndpoint}openai/files?api-version=2024-05-01-preview"
    
    # Create multipart form data and upload using curl (more reliable for file uploads)
    try {
        $response = curl.exe -s -X POST $uploadUrl `
            -H "api-key: $openAIKey" `
            -F "purpose=assistants" `
            -F "file=@`"$documentPath`"" 2>&1
        
        $responseJson = $response | ConvertFrom-Json
        
        if ($responseJson.id) {
            $fileId = $responseJson.id
            Write-Host "  Document uploaded successfully!" -ForegroundColor Green
            Write-Host "  File ID: $fileId" -ForegroundColor Green
            Write-Host "  Filename: $($responseJson.filename)" -ForegroundColor Green
            Write-Host "  Purpose: $($responseJson.purpose)" -ForegroundColor Green
            Write-Host "  Status: $($responseJson.status)" -ForegroundColor Green
            Write-Host "  Bytes: $($responseJson.bytes)" -ForegroundColor Green
        } else {
            Write-Error "Failed to upload document. Response: $response"
            exit 1
        }
    } catch {
        Write-Error "Failed to upload document: $_"
        exit 1
    }
} else {
    Write-Host "  [WhatIf] Would upload 'Innovation Hub Agenda Format.docx' to Azure OpenAI" -ForegroundColor Magenta
}

Write-Host ""

# ============================================================================
# STEP 2: Update input-config with File ID
# ============================================================================

Write-Host "STEP 2: Updating input-config with File ID" -ForegroundColor Cyan

if (-not $WhatIf -and $fileId) {
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
    
    $inputConfigContent = Update-ConfigEntry -Content $inputConfigContent -Key "hub-doc-template-fileid" -Value $fileId
    
    # Ensure file ends with newline
    $inputConfigContent = $inputConfigContent.TrimEnd() + "`n"
    
    Set-Content -Path $inputConfigPath -Value $inputConfigContent -NoNewline
    
    Write-Host "  Updated input-config with:" -ForegroundColor Green
    Write-Host "    hub-doc-template-fileid=$fileId" -ForegroundColor White
} else {
    Write-Host "  [WhatIf] Would update input-config with hub-doc-template-fileid" -ForegroundColor Magenta
}

Write-Host ""

# ============================================================================
# SUMMARY
# ============================================================================

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Upload Summary" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Document: Innovation Hub Agenda Format.docx" -ForegroundColor Green
Write-Host "  Purpose: assistants" -ForegroundColor Green
if (-not $WhatIf -and $fileId) {
    Write-Host "  File ID: $fileId" -ForegroundColor Green
}
Write-Host ""
Write-Host "Document upload completed successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Yellow
Write-Host "  - Use the file_id when creating or updating your Azure OpenAI Assistant" -ForegroundColor White
Write-Host "  - Reference the file in your assistant's file_search or code_interpreter tools" -ForegroundColor White
