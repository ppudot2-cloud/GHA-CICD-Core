<#
.SYNOPSIS
    Checks for in-progress async operations on a Power Platform environment.

.DESCRIPTION
    Queries the Dataverse Web API for async operations that are in-progress,
    waiting, or pausing (statuscode 10/20/0) and are of import/publish/upgrade
    type.

    BEHAVIOUR: Always emits a ::warning:: annotation and continues — the pipeline
    is NEVER blocked. The step outcome is always 'success'. Use the blocking-count
    output to decide in downstream steps if further action is needed.

    HANDLING STRATEGIES (pick one or combine):
      1. Retry-with-backoff  – Re-run the deployment after a configurable wait
         period. Useful when the blocking operation is short-lived (< 5 min).
         Set enable_blocking_check=false on re-run if you know it is resolved.

      2. Wait-and-poll       – Add a polling loop before the import step that
         checks the async-operations API every 60 s until the count reaches 0
         or a timeout (e.g. 15 min) is reached. Recommended for batch processes.

      3. Defer to another env – Deploy to non-blocking environments first while
         waiting. Since all non-Prod gates fire in parallel, you can let UAT and
         Intg proceed while Dev resolves its operations.

      4. Manual override flag – Expose an `override_blocking_check` workflow
         input (boolean, default false). When set to true, skip this step
         entirely. Useful for break-glass situations with explicit approval.

.PARAMETER EnvironmentUrl
    Target environment URL (e.g. https://myorg-dev.crm.dynamics.com).

.PARAMETER AppId
    Service principal application/client ID.

.PARAMETER ClientSecret
    Service principal client secret.

.PARAMETER TenantId
    Azure AD tenant ID.

.PARAMETER EnvironmentName
    Display name for logging (e.g. Dev, Intg).
#>
param(
    [Parameter(Mandatory)][string] $EnvironmentUrl,
    [Parameter(Mandatory)][string] $AppId,
    [Parameter(Mandatory)][string] $ClientSecret,
    [Parameter(Mandatory)][string] $TenantId,
    [string] $EnvironmentName = 'Target'
)

$ErrorActionPreference = 'Stop'

Write-Host "🔍 Checking for in-progress async operations on $EnvironmentUrl ..."

# Acquire OAuth token
$tokenBody = @{
    client_id     = $AppId
    client_secret = $ClientSecret
    grant_type    = 'client_credentials'
    scope         = "$EnvironmentUrl/.default"
}
$tokenResponse = Invoke-RestMethod `
    -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
    -Method POST `
    -Body $tokenBody
$token = $tokenResponse.access_token

if (-not $token) {
    Write-Error "::error::Failed to acquire OAuth token. Verify service principal credentials."
    exit 1
}

# Query in-progress solution-related async operations
# statuscode: 10=Waiting, 20=InProgress, 0=WaitingForResources
# operationtype: 1=import, 6=publishall, 25=solutionimport, 55=upgrade, 71=uninstall
$filter  = "statuscode in (10,20,0) and operationtype in (1,6,7,9,25,55,71,72)"
$select  = "name,statuscodename,operationtypename,createdon"
$apiUrl  = "$EnvironmentUrl/api/data/v9.2/asyncoperations?`$filter=$filter&`$select=$select"

$headers = @{
    'Authorization'  = "Bearer $token"
    'Accept'         = 'application/json'
    'OData-MaxVersion' = '4.0'
    'OData-Version'  = '4.0'
}
$response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method GET
$ops = $response.value

"blocking-count=$($ops.Count)" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append

if ($ops.Count -gt 0) {
    # ── WARNING ONLY — pipeline continues regardless ───────────────────────
    Write-Host "::warning::$($ops.Count) in-progress async operation(s) found on $EnvironmentName. Deployment will continue — monitor for import conflicts."

    @"

### ⚠️ In-Progress Async Operations Detected — $EnvironmentName
> **Pipeline continues.** The import will proceed. Watch for conflicts with the operations below.
> To suppress this warning, wait for them to complete or use the `override_blocking_check` input.

| Name | Status | Type | Created |
| --- | --- | --- | --- |
"@ | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append

    foreach ($op in $ops) {
        "| $($op.name) | $($op.statuscodename) | $($op.operationtypename) | $($op.createdon) |" |
            Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
    }

    @"

<details>
<summary>💡 Handling strategies</summary>

1. **Retry-with-backoff** — Re-run the deployment after a wait period. Flip `enable_blocking_check=false` if you know the operation is resolved.
2. **Wait-and-poll** — Add a polling loop before the import step (check every 60 s, timeout at 15 min).
3. **Defer to another environment** — Let Intg/UAT proceed while this environment resolves its operations.
4. **Manual override** — Use an `override_blocking_check` input (boolean) on re-run for break-glass situations.

</details>
"@ | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append

} else {
    Write-Host "✅ No blocking operations found on $EnvironmentName."
    "✅ No blocking operations found on **$EnvironmentName**." |
        Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
}
