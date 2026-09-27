#Requires -Version 7.2

<#
.SYNOPSIS
    Azure FinOps Workspace (V3, Microsoft Fabric): end-to-end, fully automated deployment of a PRIVATE FinOps hub
    (FinOps toolkit) that uses a Microsoft Fabric capacity and eventhouse (Real-Time Intelligence) as its data store, with
    private endpoints in your own virtual network, Cost Management exports for every subscription, and the FinOps hub
    dashboard as a Fabric real-time dashboard.

.DESCRIPTION
    This is version 3 of Deploy-FinOpsHub.ps1: the same deployment as version 2 with an improved console experience
    (start banner, step timings, a completion summary and an estimate of when all data is in Fabric). It deploys the
    same private FinOps hub as version 1, but instead of Azure Data
    Explorer it creates a Fabric capacity (you choose the SKU) and automates every Fabric step of the FinOps toolkit
    documentation (https://learn.microsoft.com/cloud-computing/finops/toolkit/hubs/deploy - "Optional: Set up
    Microsoft Fabric" and "Optional: Configure Fabric access"). All steps are idempotent - it is safe to re-run.

      1. Pre-flight checks: Azure CLI sign-in, Fabric API access, files, virtual network/subnet, Fabric region, SKU,
         quota and capacity name, private DNS plan, providers and permissions. Asks for the Fabric capacity SKU.
      2. Creates (or reuses/resumes) the Fabric capacity (Azure resource Microsoft.Fabric/capacities) in the hub region.
      3. Creates (or reuses) the Fabric workspace on that capacity with a workspace identity, the eventhouse and the
         Ingestion and Hub KQL databases, and runs the FinOps hub setup scripts (fabric/*.kql) in both databases.
      4. Deploys template.json (FinOps hub) with private access, connected to the eventhouse query URI.
      5. Creates private endpoints in YOUR subnet for storage (blob + dfs), Data Factory (+ Studio portal endpoint)
         and Key Vault (when present). Private DNS zones already linked to the virtual network are reused (any
         subscription); otherwise zones in -PrivateDnsZoneResourceGroupName are linked, and missing zones are created
         there.
      6. Network hardening: disables Data Factory public access and sets the hub storage firewall so the Fabric
         eventhouse can load data (see NOTES > Networking), plus a resource instance rule for this Fabric workspace.
      7. Fabric access: the Data Factory identity becomes admin of the Ingestion and Hub databases, -FabricViewers get
         Viewer on the workspace, the hub initialization pipeline is run again, and data loads that failed are re-run.
      8. Creates daily + monthly FOCUS cost exports in every subscription and backfills history (default 12 months).
      9. Imports finops-hub-dashboard.json as a Fabric real-time dashboard connected to the Hub database.
     10. Verifies the deployment - including Fabric load failures and cost rows in the Hub database - and writes a
         JSON summary to .\logs.

    Values come from parametersFile.json (null values fall back to template defaults). Parameters passed to this script
    override the file. Public access is always disabled and Azure Data Explorer is never deployed by this version.

    Guided setup: run the script without the subscription, resource group, virtual network or subnet parameters in an
    interactive session. It lists your subscriptions, virtual networks, subnets, Fabric regions with quota and private
    DNS zone locations, asks for the Fabric SKU, runs all pre-flight checks, shows the plan and asks for confirmation.
    When -FabricCapacitySku is not passed, the SKU is always asked for in interactive sessions (F2 is used for
    unattended runs).

    Requirements:
      - PowerShell 7.2+ and Azure CLI 2.60+ (signed in with 'az login').
      - Azure: Owner (or Contributor + User Access Administrator) on the hub resource group, Network Contributor on the
        virtual network, private DNS zone permissions on the DNS zone resource group, Cost Management Contributor (or
        better) on the subscriptions to export, and Fabric capacity quota in the hub region (Azure portal > Quotas >
        Microsoft Fabric).
      - Fabric: the signed-in account must be able to use Microsoft Fabric (sign in once at
        https://app.fabric.microsoft.com), create workspaces and Fabric items (tenant settings, on by default).

.PARAMETER SubscriptionId
    Subscription for the FinOps hub and the Fabric capacity. Prompted with a list when omitted.

.PARAMETER ResourceGroupName
    Resource group for the FinOps hub (and by default the Fabric capacity). Created when missing. Prompted when omitted.

.PARAMETER VirtualNetworkName
    Existing virtual network that will host the private endpoints. Prompted with a list when omitted.

.PARAMETER VirtualNetworkResourceGroupName
    Resource group of the virtual network. Prompted (with the virtual network) when omitted.

.PARAMETER PrivateEndpointSubnetName
    Existing subnet (not delegated) for the private endpoints; about 5 IP addresses are used. Prompted with a list
    when omitted.

.PARAMETER VirtualNetworkSubscriptionId
    Subscription of the virtual network. Default: SubscriptionId.

.PARAMETER PrivateEndpointResourceGroupName
    Resource group for the private endpoint resources. Must be in the virtual network subscription.
    Default: the hub resource group when the virtual network is in the hub subscription, otherwise the virtual
    network resource group.

.PARAMETER PrivateDnsZoneSubscriptionId
    Subscription that holds your private DNS zones, for example a central connectivity subscription.
    Default: VirtualNetworkSubscriptionId.

.PARAMETER PrivateDnsZoneResourceGroupName
    Existing resource group that holds your private DNS zones. Zones found there are reused and linked to the
    virtual network; missing zones are created there and linked. Zones the virtual network is already linked to
    are reused wherever they are. Default: VirtualNetworkResourceGroupName. Cannot be the hub resource group.

.PARAMETER SkipPrivateDnsZones
    Do not create/link private DNS zones or DNS zone groups (use when DNS is managed by policy or custom DNS).
    The private endpoint FQDNs and IP addresses are printed so the records can be created elsewhere.

.PARAMETER HubName
    FinOps hub name. Overrides parametersFile.json. Default: finops-hub.

.PARAMETER Location
    Azure region of the hub AND the Fabric capacity (they must match). Overrides parametersFile.json. The region must
    offer Fabric capacities and the subscription needs Fabric quota there; guided setup lists regions with quota.

.PARAMETER FabricCapacitySku
    Fabric capacity SKU: F2 (lowest cost, recommended for testing), F4, F8, F16, F32, F64 ... F2048. Asked for in
    interactive sessions when omitted; unattended runs use F2 (or the current SKU of an existing capacity).

.PARAMETER FabricCapacityName
    Fabric capacity name (3-63 lowercase letters and digits, starting with a letter). Reused when it exists (a paused
    capacity is resumed). Default: fc<hub name><6 characters unique to the subscription and resource group>.

.PARAMETER FabricCapacityResourceGroupName
    Resource group of the Fabric capacity (in SubscriptionId). Default: the hub resource group.

.PARAMETER FabricCapacityAdmins
    Extra Fabric capacity administrators (user principal names, or object IDs for service principals). The signed-in
    identity is always an administrator (it needs to assign the workspace to the capacity).

.PARAMETER FabricWorkspaceName
    Fabric workspace for the eventhouse and dashboard. Created when missing; an existing workspace must be on the same
    capacity (or on none). Default: "FinOps hub - <resource group name>".

.PARAMETER FabricEventhouseName
    Eventhouse name (letters, digits, _ . -). Default: FinOpsHub. The databases are always named Ingestion and Hub.

.PARAMETER FabricViewers
    Entra object IDs (users, groups or service principals) that get Viewer access to the Fabric workspace, which lets
    them use the dashboard and query the Hub and Ingestion databases.

.PARAMETER HubVirtualNetworkAddressPrefix
    Address space (/26 or larger) of the hub's isolated internal network. Overrides parametersFile.json.
    Default: 10.20.30.0/26. Pick a range that does not overlap your networks if you ever plan to peer it.

.PARAMETER EnableRecommendations
    Enables Azure Resource Graph recommendations and grants the hub Reader access on the export subscriptions.

.PARAMETER Tags
    Tags for the resource groups and every Azure resource created (including the Fabric capacity).

.PARAMETER ExportScopes
    Scopes to export (for example /subscriptions/<id>). Default: every enabled subscription in the tenant.

.PARAMETER BackfillMonths
    Number of previous months to export after the exports are created. Default: 12. Use 0 to skip.

.PARAMETER FocusDatasetVersion
    FOCUS dataset version. Default: 1.2-preview (falls back to 1.0r2 if the scope does not support it).

.PARAMETER AllowDataFactoryPublicAccess
    Keep Data Factory public network access enabled (Data Factory Studio reachable from the internet).

.PARAMETER KeepStorageFirewallClosed
    Keep the hub storage firewall closed (default action Deny). Fabric eventhouses cannot load data through a storage
    firewall today, so data then stays in storage and does not reach Fabric (see NOTES > Networking).

.PARAMETER SkipHubDeployment
    Skip the template deployment and reuse the outputs of the last successful run (all other steps still run).

.PARAMETER SkipExports
    Do not create Cost Management exports.

.PARAMETER SkipDashboard
    Do not import the Fabric real-time dashboard.

.PARAMETER NoBrowser
    Do not open the dashboard in the browser at the end.

.PARAMETER MaxDeploymentAttempts
    Number of attempts for the template deployment when a transient error occurs. Default: 3.

.PARAMETER TemplateFile
    FinOps hub ARM template. Default: template.json next to this script.

.PARAMETER TemplateParameterFile
    Template parameter values. Default: parametersFile.json next to this script.

.PARAMETER DashboardFile
    FinOps hub dashboard definition to import into Fabric. Default: finops-hub-dashboard.json next to this script.

.PARAMETER FabricSetupScriptFolder
    Folder with finops-hub-fabric-setup-Ingestion.kql and finops-hub-fabric-setup-Hub.kql (the FinOps toolkit release
    assets that match template.json). Default: the fabric folder next to this script.

.EXAMPLE
    ./Deploy-FinOpsHub-V3-Fabric.ps1

    Guided setup: choose the subscription, virtual network, subnet, region, Fabric SKU and private DNS zone location.

.EXAMPLE
    $p = Import-PowerShellDataFile ./customer-fabric.psd1; ./Deploy-FinOpsHub-V3-Fabric.ps1 @p

    Unattended run with the parameters kept in a PowerShell data file (keys are the parameter names).

.EXAMPLE
    ./Deploy-FinOpsHub-V3-Fabric.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -ResourceGroupName rg-finops-hub `
        -Location swedencentral -FabricCapacitySku F2 `
        -VirtualNetworkName vnet-hub -VirtualNetworkResourceGroupName rg-network -PrivateEndpointSubnetName snet-pe

.NOTES
    Solution developed by Zahir Hussain Shah, Sr. Solution Engineer, Cloud & AI - Infra, Microsoft Qatar.
    Azure public cloud only.
    Cost: a Fabric capacity is billed per hour while it is active, whether it is used or not. It can be paused (the
    script prints the command), but no data is loaded while it is paused; re-running the script resumes it and re-runs
    the loads that failed.
    Updates: Cost Management runs the daily export (month to date) every day and the monthly export (the closed previous
    month) around the 5th of each month. The hub pipelines load every export run into the eventhouse and the dashboard
    queries it live. Exports are scheduled for 5 years. Re-run the script (it is idempotent) after adding
    subscriptions (new ones are not picked up automatically), after redeploying the hub template, and to renew the
    exports. Failed loads are listed by '.show ingestion failures' in the Ingestion database.
    Networking: Data Factory, Key Vault (when present) and the private endpoints in your virtual network are private as
    in version 1. The hub storage firewall is set to allow all networks: the Fabric eventhouse loads data by pulling
    the files from storage (.ingest ... ;impersonate), and neither the trusted services exception, trusted workspace
    access nor Fabric managed private endpoints cover that (FinOps toolkit issue #2061, verified in this deployment).
    Every request still needs authentication (Entra ID RBAC or the account key); anonymous access stays disabled.
    Use -KeepStorageFirewallClosed where policy forbids it (data then stops at storage). Fabric itself is a SaaS
    service protected by Entra ID and workspace roles; Fabric private links are not configured by this script.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Parameters are read by the step functions.')]
[CmdletBinding()]
param(
    [ValidatePattern('^([0-9a-fA-F-]{36})?$')][string] $SubscriptionId,
    [ValidateLength(0, 90)][string] $ResourceGroupName,
    [string] $VirtualNetworkName,
    [string] $VirtualNetworkResourceGroupName,
    [string] $PrivateEndpointSubnetName,
    [ValidatePattern('^([0-9a-fA-F-]{36})?$')][string] $VirtualNetworkSubscriptionId,
    [string] $PrivateEndpointResourceGroupName,
    [ValidatePattern('^([0-9a-fA-F-]{36})?$')][string] $PrivateDnsZoneSubscriptionId,
    [string] $PrivateDnsZoneResourceGroupName,
    [switch] $SkipPrivateDnsZones,
    [string] $HubName,
    [string] $Location,
    [ValidatePattern('^(F\d{1,4})?$')][string] $FabricCapacitySku,
    [ValidatePattern('^([a-z][a-z0-9]{2,62})?$')][string] $FabricCapacityName,
    [ValidateLength(0, 90)][string] $FabricCapacityResourceGroupName,
    [string[]] $FabricCapacityAdmins = @(),
    [ValidateLength(0, 256)][string] $FabricWorkspaceName,
    [ValidatePattern('^[A-Za-z0-9_.-]{1,128}$')][string] $FabricEventhouseName = 'FinOpsHub',
    [string[]] $FabricViewers = @(),
    [string] $HubVirtualNetworkAddressPrefix,
    [switch] $EnableRecommendations,
    [hashtable] $Tags = @{},
    [string[]] $ExportScopes,
    [ValidateRange(0, 84)][int] $BackfillMonths = 12,
    [ValidateSet('1.2-preview', '1.0r2', '1.0')][string] $FocusDatasetVersion = '1.2-preview',
    [switch] $AllowDataFactoryPublicAccess,
    [switch] $KeepStorageFirewallClosed,
    [switch] $SkipHubDeployment,
    [switch] $SkipExports,
    [switch] $SkipDashboard,
    [switch] $NoBrowser,
    [ValidateRange(1, 5)][int] $MaxDeploymentAttempts = 3,
    [string] $TemplateFile = (Join-Path $PSScriptRoot 'template.json'),
    [string] $TemplateParameterFile = (Join-Path $PSScriptRoot 'parametersFile.json'),
    [string] $DashboardFile = (Join-Path $PSScriptRoot 'finops-hub-dashboard.json'),
    [string] $FabricSetupScriptFolder = (Join-Path $PSScriptRoot 'fabric')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:ArmUrl = 'https://management.azure.com'
$script:ArmResource = 'https://management.azure.com/'
$script:FabricApi = 'https://api.fabric.microsoft.com/v1'
$script:FabricResource = 'https://api.fabric.microsoft.com'
$script:KustoResource = 'https://kusto.kusto.windows.net'
$script:FabricArmApiVersion = '2023-11-01'
$script:ExportsApiVersion = '2025-03-01'
$script:DeploymentPrefix = 'finopshub-fabric'
$script:TokenCache = @{}
$script:PermissionCache = @{}
$script:FabricSkuCatalog = $null
$script:HubServiceRegions = $null
$script:TenantId = $null
$script:Warnings = [System.Collections.Generic.List[string]]::new()
$script:StepNumber = 0
$script:TotalSteps = 10
$script:RunStart = Get-Date

#region Output helpers
function Write-Step([string] $Message) {
    $script:StepNumber++
    Write-Host ''
    Write-Host ("==> [{0}/{1}] {2}" -f $script:StepNumber, $script:TotalSteps, $Message) -ForegroundColor Cyan -NoNewline
    Write-Host ("   [{0:hh\:mm\:ss}]" -f ((Get-Date) - $script:RunStart)) -ForegroundColor DarkGray
}
function Write-Info([string] $Message) { Write-Host "    $Message" }
function Write-Ok([string] $Message) { Write-Host "    [OK] $Message" -ForegroundColor Green }
function Write-Warn([string] $Message) {
    $script:Warnings.Add($Message)
    Write-Host "    [WARN] $Message" -ForegroundColor Yellow
}
function Write-Rule([string] $Character = '=', [ConsoleColor] $Color = 'DarkCyan') { Write-Host ('  ' + ($Character * 93)) -ForegroundColor $Color }

function Write-Paragraph([string] $Text, [ConsoleColor] $Color = 'Gray', [string] $Indent = '    ', [int] $Width = 95) {
    $line = ''
    foreach ($word in @($Text -split '\s+' | Where-Object { $_ })) {
        if ($line -and ($Indent.Length + $line.Length + 1 + $word.Length) -gt $Width) {
            Write-Host ($Indent + $line) -ForegroundColor $Color
            $line = $word
        }
        else { $line = if ($line) { "$line $word" } else { $word } }
    }
    if ($line) { Write-Host ($Indent + $line) -ForegroundColor $Color }
}

function Write-Banner {
    $art = @(
        '    _      _____  _   _   ____    _____      _____   ___   _   _    ___    ____    ____'
        '   / \    |__  / | | | | |  _ \  | ____|    |  ___| |_ _| | \ | |  / _ \  |  _ \  / ___|'
        '  / _ \     / /  | | | | | |_) | |  _|      | |_     | |  |  \| | | | | | | |_) | \___ \'
        ' / ___ \   / /_  | |_| | |  _ <  | |___     |  _|    | |  | |\  | | |_| | |  __/   ___) |'
        '/_/   \_\ /____|  \___/  |_| \_\ |_____|    |_|     |___| |_| \_|  \___/  |_|     |____/'
    )
    $center = { param([string] $Text) (' ' * (4 + [Math]::Max(0, [int][Math]::Floor((89 - $Text.Length) / 2)))) + $Text }
    Write-Host ''
    Write-Rule
    Write-Host ''
    foreach ($line in $art) { Write-Host "    $line" -ForegroundColor Cyan }
    Write-Host ''
    Write-Host (& $center 'W   O   R   K   S   P   A   C   E') -ForegroundColor White
    Write-Host (& $center 'Automated FinOps hub deployment with Microsoft Fabric  |  version 3') -ForegroundColor DarkGray
    Write-Host ''
    Write-Rule
    Write-Host '    Solution developed by' -ForegroundColor DarkGray
    Write-Host '      Zahir Hussain Shah' -ForegroundColor White
    Write-Host '      Sr. Solution Engineer, Cloud & AI - Infra' -ForegroundColor Gray
    Write-Host '      Microsoft Qatar' -ForegroundColor Gray
    Write-Rule '-' 'DarkGray'
    Write-Paragraph ('A fully automated, end-to-end deployment of the Microsoft Azure FinOps workspace. It brings the cost data of ' +
        'your Azure subscriptions into Microsoft Fabric and keeps it current every day, for secure dashboard viewing by the ' +
        'corporate users your administrator allows.') 'White'
    Write-Host ''
    foreach ($feature in @(
            'FinOps hub (FinOps toolkit) with private endpoints in your own virtual network',
            'Microsoft Fabric capacity, workspace, eventhouse and the real-time FinOps dashboard',
            'Daily and monthly FOCUS cost exports per subscription, 12 months of history by default',
            'Microsoft Entra ID sign-in and role-based access, no anonymous access',
            'Idempotent: re-run at any time to update, repair or add new subscriptions')) {
        Write-Host '      * ' -ForegroundColor Cyan -NoNewline
        Write-Host $feature -ForegroundColor Gray
    }
    Write-Rule
}

function Get-DataArrivalEstimate([int] $Scopes, [int] $Months) {
    # Measured on test deployments: exports take about 20 minutes, then Fabric loads one scope-month at a time in about 2.5 minutes.
    $minutes = 20 + [Math]::Ceiling([Math]::Max(1, $Scopes) * [Math]::Max(1, $Months) * 2.5)
    if ($minutes -lt 60) { return 'up to about {0} minutes' -f ([Math]::Ceiling($minutes / 5) * 5) }
    $hours = [Math]::Ceiling($minutes / 30) / 2
    if ($hours -lt 48) { return 'up to about {0} hour{1}' -f $hours, $(if ($hours -eq 1) { '' } else { 's' }) }
    return 'up to about {0} days' -f ([Math]::Ceiling($minutes / 720) / 2)
}

function Write-CompletionSummary($Checks, [TimeSpan] $Duration, $Links, [string[]] $Notes, [int] $ExportScopes, [int] $Months, [string] $ScopeLabel = 'subscription(s)') {
    $passed = @($Checks | Where-Object Pass).Count
    $total = @($Checks).Count
    $ready = $passed -eq $total
    Write-Host ''
    Write-Rule
    Write-Host ('    {0,-56}{1,35}' -f $(if ($ready) { 'AZURE FINOPS WORKSPACE IS READY' } else { 'AZURE FINOPS WORKSPACE DEPLOYED WITH WARNINGS' }), "$passed of $total checks passed") -ForegroundColor $(if ($ready) { 'Green' } else { 'Yellow' })
    Write-Host ('    Deployed in {0:N0} minutes' -f $Duration.TotalMinutes) -ForegroundColor Gray
    Write-Rule
    foreach ($name in $Links.Keys) {
        Write-Host ('    {0,-19}' -f $name) -ForegroundColor Gray -NoNewline
        Write-Host $Links[$name] -ForegroundColor White
    }
    if ($Notes) {
        Write-Host ''
        foreach ($note in $Notes) { Write-Info $note }
    }
    if ($script:Warnings.Count -gt 0) { Write-Host "    Completed with $($script:Warnings.Count) warning(s) - see above." -ForegroundColor Yellow }
    Write-Rule '-' 'DarkGray'
    Write-Host '    PLEASE NOTE: the dashboard fills up gradually' -ForegroundColor Yellow
    if ($ExportScopes -gt 0) {
        Write-Paragraph (('Data can take some time to appear in the dashboard. How long depends on the amount of cost data and the ' +
                'number of subscriptions: Cost Management first prepares the exports (about 15-30 minutes), then Microsoft ' +
                'Fabric loads the data one month at a time for each subscription (about 2-3 minutes each). For this deployment ' +
                '({0} {1}, {2} month(s) each) expect the first data within about 30-60 minutes; loading the full history takes ' +
                '{3}. After that, new costs arrive automatically every day.') -f $ExportScopes, $ScopeLabel, $Months, (Get-DataArrivalEstimate -Scopes $ExportScopes -Months $Months))
    }
    else { Write-Paragraph 'No cost exports were created in this run, so no data is loaded yet. Data appears once Cost Management exports write to the hub storage.' }
    Write-Rule
}
#endregion

#region Generic helpers
function Get-Value {
    param($Object, [string] $Path, $Default = $null)
    $current = $Object
    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $current) { return $Default }
        if ($current -is [System.Collections.IDictionary]) {
            if (-not $current.Contains($segment)) { return $Default }
            $current = $current[$segment]
        }
        else {
            $property = $current.PSObject.Properties[$segment]
            if (-not $property) { return $Default }
            $current = $property.Value
        }
    }
    if ($null -eq $current) { return $Default }
    return $current
}

function Invoke-AzCli {
    param([Parameter(Mandatory)][string[]] $Arguments, [switch] $AllowFailure)
    $ErrorActionPreference = 'Continue'
    $output = & az @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $stdout = (@($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n").Trim()
    $stderr = (@($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() }) -join "`n").Trim()
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "az $($Arguments[0]) $($Arguments[1]) failed (exit code $exitCode): $stderr"
    }
    return [pscustomobject]@{ ExitCode = $exitCode; StdOut = $stdout; StdErr = $stderr }
}

function Test-NetworkError([string] $Message) {
    # Name-resolution and connection failures never reached the service, so retrying them is safe.
    return $Message -match 'No such host is known|Name or service not known|nodename nor servname|NameResolutionError|Failed to resolve|getaddrinfo|No connection could be made|network is unreachable|host is unreachable|connection attempt failed|Failed to establish a new connection|ServerOrProxyNotFound|server or proxy was not found'
}

function Get-AccessToken([string] $Resource) {
    $cached = $script:TokenCache[$Resource]
    if ($cached -and $cached.ExpiresOn -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) { return $cached.Token }
    for ($attempt = 1; ; $attempt++) {
        $result = Invoke-AzCli -Arguments @('account', 'get-access-token', '--resource', $Resource, '--tenant', $script:TenantId, '--output', 'json') -AllowFailure
        if ($result.ExitCode -eq 0) { break }
        $network = Test-NetworkError $result.StdErr
        $limit = if ($network) { 10 } elseif ($result.StdErr -match 'AADSTS|az login|interaction_required|invalid_grant') { 1 } else { 3 }
        if ($attempt -ge $limit) {
            if ($network) { throw "Could not reach Microsoft Entra ID to get an access token for $Resource. Check this computer's network connection (DNS, VPN or proxy). Details: $($result.StdErr)" }
            throw "Could not get an access token for $Resource. Sign in again with 'az login --tenant $script:TenantId'. Details: $($result.StdErr)"
        }
        Write-Info "Could not get an access token for $Resource$(if ($network) { ' (network problem)' }); retrying in 30 seconds (attempt $($attempt + 1) of $limit)..."
        Start-Sleep -Seconds 30
    }
    $tokenInfo = $result.StdOut | ConvertFrom-Json
    $epoch = Get-Value $tokenInfo 'expires_on'
    $expiresOn = if ($epoch) { [DateTimeOffset]::FromUnixTimeSeconds([long]$epoch) } else { [DateTimeOffset]::UtcNow.AddMinutes(30) }
    $script:TokenCache[$Resource] = @{ Token = $tokenInfo.accessToken; ExpiresOn = $expiresOn }
    return $tokenInfo.accessToken
}

function Get-TokenClaims([string] $Resource) {
    $payload = (Get-AccessToken $Resource).Split('.')[1].Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) { 2 { $payload += '==' } 3 { $payload += '=' } }
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
}

function Get-ErrorText($Content) {
    # ARM ({error:{code,message}}), Fabric ({errorCode,message}) and Kusto ({error:{code,@message}}) error bodies.
    if ($null -eq $Content) { return '' }
    if ($Content -is [string]) { return $Content }
    $inner = Get-Value $Content 'error' $Content
    if ($inner -is [string]) { return $inner }
    $code = Get-Value $inner 'code' (Get-Value $inner 'errorCode' '')
    $message = Get-Value $inner '@message' (Get-Value $inner 'message' '')
    if ($code -or $message) { return "$code $message".Trim() }
    return ($Content | ConvertTo-Json -Depth 10 -Compress)
}

function Invoke-Arm {
    <# Calls ARM (or any Entra-protected REST API) with retries for throttling and transient errors. #>
    param(
        [ValidateSet('GET', 'PUT', 'POST', 'PATCH', 'DELETE')][string] $Method = 'GET',
        [Parameter(Mandatory)][string] $Path,
        $Body,
        [string] $Resource = $script:ArmResource,
        [int[]] $OkStatus = @(200, 201, 202, 204),
        [switch] $AllowNotFound,
        [switch] $RetryOnConflict,
        [int] $MaxAttempts = 8,
        [int] $TimeoutSec = 300
    )
    $uri = if ($Path -match '^https://') { $Path } else { "$script:ArmUrl$Path" }
    $payload = $null
    if ($null -ne $Body) { $payload = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 50 -Compress } }
    for ($attempt = 1; ; $attempt++) {
        $request = @{
            Method             = $Method
            Uri                = $uri
            Headers            = @{ Authorization = "Bearer $(Get-AccessToken $Resource)" }
            SkipHttpErrorCheck = $true
            TimeoutSec         = $TimeoutSec
        }
        if ($null -ne $payload) {
            $request.Body = [Text.Encoding]::UTF8.GetBytes($payload)
            $request.ContentType = 'application/json'
        }
        try { $response = Invoke-WebRequest @request }
        catch {
            $message = $_.Exception.Message
            $network = Test-NetworkError $message
            $limit = if ($network) { [Math]::Max($MaxAttempts, 20) } else { $MaxAttempts }
            if ($attempt -ge $limit) {
                if ($network) { throw "Could not reach $(([uri]$uri).Host) for about $([Math]::Round(($limit - 1) / 2)) minutes ($message). Check this computer's network connection (DNS, VPN or proxy)." }
                throw "Request $Method $uri failed: $message"
            }
            $wait = if ($network) { 30 } else { [Math]::Min(60, 5 * $attempt) }
            if ($network) { Write-Info "Network problem reaching $(([uri]$uri).Host) ($message); retrying in $wait seconds (attempt $($attempt + 1) of $limit)..." }
            Start-Sleep -Seconds $wait
            continue
        }
        $status = [int]$response.StatusCode
        $content = $null
        if ($response.Content) {
            $raw = if ($response.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($response.Content) } else { [string]$response.Content }
            if ($raw.Trim()) { try { $content = $raw | ConvertFrom-Json -Depth 100 } catch { $content = $raw } }
        }
        if ($OkStatus -contains $status) {
            return [pscustomobject]@{ StatusCode = $status; Content = $content; Headers = $response.Headers }
        }
        if ($status -eq 404 -and $AllowNotFound) { return $null }
        if ($status -eq 409 -and $RetryOnConflict -and $attempt -lt $MaxAttempts) {
            Write-Verbose "HTTP 409 for $Method $uri (resource busy) - retrying in 30 seconds."
            Start-Sleep -Seconds 30
            continue
        }
        if (($status -eq 429 -or $status -ge 500) -and $attempt -lt $MaxAttempts) {
            $wait = if ($status -eq 429) { 60 } else { [Math]::Min(120, 10 * $attempt) }
            $retryAfter = $response.Headers['Retry-After']
            if ($retryAfter) {
                $seconds = 0
                if ([int]::TryParse(@($retryAfter)[0], [ref]$seconds) -and $seconds -gt 0) { $wait = [Math]::Min(300, $seconds + 1) }
            }
            Write-Verbose "HTTP $status for $Method $uri - retrying in $wait seconds (attempt $attempt of $MaxAttempts)."
            Start-Sleep -Seconds $wait
            continue
        }
        $exception = [System.Exception]::new("HTTP $status for $Method $uri : $(Get-ErrorText $content)")
        $exception.Data['StatusCode'] = $status
        $exception.Data['Content'] = $content
        throw $exception
    }
}

function Get-ArmList([string] $Path) {
    $items = [System.Collections.Generic.List[object]]::new()
    $next = $Path
    while ($next) {
        $page = (Invoke-Arm -Path $next).Content
        foreach ($item in @(Get-Value $page 'value' @())) { $items.Add($item) }
        $next = Get-Value $page 'nextLink'
    }
    return $items.ToArray()
}

function Invoke-ResourceGraph([string] $Query) {
    $rows = [System.Collections.Generic.List[object]]::new()
    $skipToken = $null
    do {
        $body = @{ query = $Query; options = @{ resultFormat = 'objectArray' } }
        if ($skipToken) { $body.options['$skipToken'] = $skipToken }
        $page = (Invoke-Arm -Method POST -Path '/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01' -Body $body).Content
        foreach ($row in @(Get-Value $page 'data' @())) { $rows.Add($row) }
        $skipToken = Get-Value $page '$skipToken'
    } while ($skipToken)
    return $rows.ToArray()
}

function New-DeterministicGuid([string] $Seed) {
    $hash = [System.Security.Cryptography.MD5]::HashData([Text.Encoding]::UTF8.GetBytes($Seed.ToLowerInvariant()))
    return [guid]::new($hash).ToString()
}

function ConvertTo-Minified([string] $Json) {
    $options = [System.Text.Json.JsonSerializerOptions]::new()
    $options.Encoder = [System.Text.Encodings.Web.JavaScriptEncoder]::UnsafeRelaxedJsonEscaping
    return [System.Text.Json.Nodes.JsonNode]::Parse($Json).ToJsonString($options)
}

function Test-CidrOverlap([string] $A, [string] $B) {
    $toRange = {
        param([string] $Cidr)
        $parts = $Cidr.Split('/')
        $bytes = [System.Net.IPAddress]::Parse($parts[0]).GetAddressBytes()
        $ip = [double]$bytes[0] * 16777216 + [double]$bytes[1] * 65536 + [double]$bytes[2] * 256 + [double]$bytes[3]
        $size = [Math]::Pow(2, 32 - [int]$parts[1])
        $start = [Math]::Floor($ip / $size) * $size
        return @($start, ($start + $size - 1))
    }
    $ra = & $toRange $A
    $rb = & $toRange $B
    return ($ra[0] -le $rb[1]) -and ($rb[0] -le $ra[1])
}
#endregion

#region Azure helpers
function Test-ArmPermission([string] $Scope, [string] $Action) {
    # Effective permissions of the caller (includes inherited role assignments).
    if (-not $script:PermissionCache.ContainsKey($Scope)) {
        try { $script:PermissionCache[$Scope] = @(Get-ArmList "$Scope/providers/Microsoft.Authorization/permissions?api-version=2022-04-01") }
        catch {
            if ([int]$_.Exception.Data['StatusCode'] -notin 403, 404) { throw }
            $script:PermissionCache[$Scope] = @()
        }
    }
    foreach ($permission in $script:PermissionCache[$Scope]) {
        $allowed = @(Get-Value $permission 'actions' @() | Where-Object { $Action -like $_ }).Count -gt 0
        $denied = @(Get-Value $permission 'notActions' @() | Where-Object { $Action -like $_ }).Count -gt 0
        if ($allowed -and -not $denied) { return $true }
    }
    return $false
}
function Register-Providers([string] $Subscription, [string[]] $Namespaces) {
    $pending = @()
    foreach ($namespace in $Namespaces) {
        $provider = (Invoke-Arm -Path "/subscriptions/$Subscription/providers/$namespace`?api-version=2021-04-01").Content
        if ($provider.registrationState -ne 'Registered') {
            Write-Info "Registering resource provider $namespace in subscription $Subscription..."
            Invoke-Arm -Method POST -Path "/subscriptions/$Subscription/providers/$namespace/register?api-version=2021-04-01" | Out-Null
            $pending += $namespace
        }
    }
    $deadline = (Get-Date).AddMinutes(15)
    foreach ($namespace in $pending) {
        while ((Invoke-Arm -Path "/subscriptions/$Subscription/providers/$namespace`?api-version=2021-04-01").Content.registrationState -ne 'Registered') {
            if ((Get-Date) -gt $deadline) { throw "Resource provider $namespace did not finish registering in subscription $Subscription." }
            Start-Sleep -Seconds 10
        }
    }
}

function Set-ResourceGroup([string] $Subscription, [string] $Name, [string] $RegionName, [hashtable] $ResourceTags, [switch] $MergeTags) {
    $path = "/subscriptions/$Subscription/resourcegroups/$Name`?api-version=2021-04-01"
    $existing = Invoke-Arm -Path $path -AllowNotFound
    if (-not $existing) {
        Invoke-Arm -Method PUT -Path $path -Body @{ location = $RegionName; tags = $ResourceTags } | Out-Null
        Write-Ok "Created resource group $Name ($RegionName)"
        return $RegionName
    }
    if ($MergeTags -and $ResourceTags.Count -gt 0) {
        $body = @{ operation = 'Merge'; properties = @{ tags = $ResourceTags } }
        Invoke-Arm -Method PATCH -Path "/subscriptions/$Subscription/resourceGroups/$Name/providers/Microsoft.Resources/tags/default?api-version=2021-04-01" -Body $body | Out-Null
    }
    return $existing.Content.location
}

function Clear-HubDeploymentScripts([string] $Subscription, [string] $ResourceGroup) {
    # The template's deployment scripts are kept for an hour and are not re-run while they exist, so a redeploy within that hour skips stopping the Data Factory triggers (TriggerEnabledCannotUpdate).
    $scripts = @(Get-ArmList "/subscriptions/$Subscription/resourceGroups/$ResourceGroup/providers/Microsoft.Resources/deploymentScripts?api-version=2023-08-01" |
        Where-Object { (Get-Value $_ 'tags.ftk-tool' '') -eq 'FinOps hubs' -and (Get-Value $_ 'properties.provisioningState' '') -in 'Succeeded', 'Failed', 'Canceled' })
    foreach ($deploymentScript in $scripts) { Invoke-Arm -Method DELETE -Path "$($deploymentScript.id)?api-version=2023-08-01" -AllowNotFound | Out-Null }
    if ($scripts.Count -gt 0) { Write-Info "Removed $($scripts.Count) finished FinOps hub deployment script record(s) so the template runs its trigger steps again." }
}

function Invoke-GroupDeployment {
    <# Runs an ARM group deployment through REST, streams progress, retries transient failures, returns outputs. #>
    param(
        [string] $Subscription,
        [string] $ResourceGroup,
        [string] $NamePrefix,
        [string] $TemplateJson,
        [hashtable] $Parameters,
        [int] $MaxAttempts = 1,
        [int] $TimeoutMinutes = 180,
        [switch] $ShowNestedProgress,
        [switch] $ResumeRunning,
        [scriptblock] $BeforeAttempt
    )
    $parameterObject = [ordered]@{}
    foreach ($key in $Parameters.Keys) { $parameterObject[$key] = @{ value = $Parameters[$key] } }
    $parametersJson = $parameterObject | ConvertTo-Json -Depth 50 -Compress
    $body = '{"properties":{"mode":"Incremental","template":' + $TemplateJson + ',"parameters":' + $parametersJson + '}}'
    $fatalCodes = @('InvalidTemplate', 'InvalidTemplateDeployment', 'AuthorizationFailed', 'LinkedAuthorizationFailed',
        'RequestDisallowedByPolicy', 'QuotaExceeded', 'SkuNotAvailable', 'LocationNotAvailableForResourceType',
        'StorageAccountAlreadyTaken', 'DeploymentActive', 'InvalidResourceLocation', 'LocationRequired',
        'MissingSubscriptionRegistration', 'SubscriptionNotRegistered', 'ResourceGroupNotFound', 'NameNotAvailable')

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $name = '{0}-{1}' -f $NamePrefix, (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
        $deploymentPath = "/subscriptions/$Subscription/resourcegroups/$ResourceGroup/providers/Microsoft.Resources/deployments/$name"
        $started = [DateTime]::UtcNow
        $running = $null
        if ($ResumeRunning -and $attempt -eq 1) {
            $running = @(Get-ArmList "/subscriptions/$Subscription/resourcegroups/$ResourceGroup/providers/Microsoft.Resources/deployments?api-version=2024-03-01" |
                Where-Object { $_.name -like "$NamePrefix-*" -and $_.properties.provisioningState -notin 'Succeeded', 'Failed', 'Canceled', 'Deleted', 'Deleting' }) | Select-Object -First 1
        }
        if ($running) {
            $name = $running.name
            $deploymentPath = "/subscriptions/$Subscription/resourcegroups/$ResourceGroup/providers/Microsoft.Resources/deployments/$name"
            $started = ([DateTime](Get-Value $running 'properties.timestamp' ([DateTime]::UtcNow))).ToUniversalTime()
            Write-Info "Deployment '$name' is already running (started earlier); waiting for it instead of starting a new one."
        }
        else {
            if ($BeforeAttempt) { & $BeforeAttempt }
            Write-Info "Starting deployment '$name' (attempt $attempt of $MaxAttempts)..."
            try {
                Invoke-Arm -Method PUT -Path "$deploymentPath`?api-version=2024-03-01" -Body $body -OkStatus 200, 201 -MaxAttempts 4 | Out-Null
            }
            catch {
                $content = $_.Exception.Data['Content']
                $code = Get-Value $content 'error.code'
                $details = @(Get-Value $content 'error.details' @()) | ForEach-Object { "$(Get-Value $_ 'code'): $(Get-Value $_ 'message')" }
                throw "Deployment '$name' was rejected ($code): $(Get-ErrorText $content) $($details -join ' | ')"
            }
        }

        $lastLine = ''
        $lastPrint = [DateTime]::MinValue
        do {
            Start-Sleep -Seconds 30
            $deployment = (Invoke-Arm -Path "$deploymentPath`?api-version=2024-03-01").Content
            $state = $deployment.properties.provisioningState
            $elapsed = [DateTime]::UtcNow - $started
            $line = "state: $state"
            if ($ShowNestedProgress) {
                $nested = @(Get-ArmList "/subscriptions/$Subscription/resourcegroups/$ResourceGroup/providers/Microsoft.Resources/deployments?api-version=2024-03-01" |
                    Where-Object { $_.name -ne $name -and ([DateTime](Get-Value $_ 'properties.timestamp' ([DateTime]::MinValue))).ToUniversalTime() -ge $started.AddMinutes(-1) })
                $running = @($nested | Where-Object { $_.properties.provisioningState -notin 'Succeeded', 'Failed', 'Canceled' })
                $succeeded = @($nested | Where-Object { $_.properties.provisioningState -eq 'Succeeded' }).Count
                $failed = @($nested | Where-Object { $_.properties.provisioningState -eq 'Failed' }).Count
                $line = "state: $state | nested: $succeeded succeeded, $($running.Count) running, $failed failed"
                if ($running.Count -gt 0) { $line += ' | running: ' + ((@($running | Select-Object -First 4 | ForEach-Object name)) -join ', ') }
            }
            if ($line -ne $lastLine -or ([DateTime]::UtcNow - $lastPrint).TotalMinutes -ge 5) {
                Write-Info ("[{0:hh\:mm\:ss}] {1}" -f $elapsed, $line)
                $lastLine = $line
                $lastPrint = [DateTime]::UtcNow
            }
            if ($elapsed.TotalMinutes -gt $TimeoutMinutes) { throw "Deployment '$name' did not finish within $TimeoutMinutes minutes." }
        } while ($state -notin 'Succeeded', 'Failed', 'Canceled')

        if ($state -eq 'Succeeded') {
            Write-Ok ("Deployment '{0}' succeeded in {1:hh\:mm\:ss}" -f $name, ([DateTime]::UtcNow - $started))
            return [pscustomobject]@{ Name = $name; Outputs = (Get-Value $deployment 'properties.outputs') }
        }

        $failures = @(Get-DeploymentFailures -DeploymentPath $deploymentPath)
        $topError = Get-Value $deployment 'properties.error'
        Write-Host "    Deployment '$name' $state. Errors:" -ForegroundColor Red
        if ($failures.Count -eq 0 -and $topError) { Write-Host "      - $(Get-ErrorText @{ error = $topError })" -ForegroundColor Red }
        foreach ($failure in $failures) {
            Write-Host "      - [$($failure.Resource)] $($failure.Code): $($failure.Message)" -ForegroundColor Red
            if ($failure.Log) { Write-Host ($failure.Log -replace '(?m)^', '          | ') -ForegroundColor DarkGray }
        }
        $codes = @($failures | ForEach-Object { $_.Code }) + @(Get-Value $topError 'code')
        $fatal = @($codes | Where-Object { $_ -in $fatalCodes })
        if ($fatal.Count -gt 0) { throw "Deployment '$name' failed with a non-transient error ($($fatal -join ', ')). Fix the error above and re-run the script." }
        if ($attempt -lt $MaxAttempts) { Write-Warn "Deployment attempt $attempt failed with transient errors; retrying (deployments are idempotent)." }
    }
    throw "Deployment failed after $MaxAttempts attempt(s). See the errors above."
}

function Get-DeploymentFailures([string] $DeploymentPath, [int] $Depth = 0) {
    $operations = @(Get-ArmList "$DeploymentPath/operations?api-version=2024-03-01")
    foreach ($operation in $operations) {
        if ((Get-Value $operation 'properties.provisioningState') -ne 'Failed') { continue }
        $target = Get-Value $operation 'properties.targetResource'
        $type = Get-Value $target 'resourceType' ''
        $id = Get-Value $target 'id' ''
        if ($type -eq 'Microsoft.Resources/deployments' -and $id -and $Depth -lt 8) {
            Get-DeploymentFailures -DeploymentPath $id -Depth ($Depth + 1)
            continue
        }
        $statusMessage = Get-Value $operation 'properties.statusMessage'
        $errorObject = Get-Value $statusMessage 'error' $statusMessage
        $code = Get-Value $errorObject 'code' (Get-Value $operation 'properties.statusCode' 'Unknown')
        $message = Get-Value $errorObject 'message' ''
        $details = @(Get-Value $errorObject 'details' @())
        if ($details.Count -gt 0) {
            $message += ' ' + ((@($details | ForEach-Object { "$(Get-Value $_ 'code'): $(Get-Value $_ 'message')" })) -join ' | ')
            if ($code -in 'DeploymentFailed', 'ResourceDeploymentFailure') { $code = Get-Value $details[0] 'code' $code }
        }
        $log = $null
        if ($type -eq 'Microsoft.Resources/deploymentScripts' -and $id) {
            try {
                $logText = Get-Value (Invoke-Arm -Path "$id/logs/default?api-version=2023-08-01" -AllowNotFound).Content 'properties.log' ''
                $log = (@($logText -split "`n") | Select-Object -Last 25) -join "`n"
            }
            catch { $log = $null }
        }
        [pscustomobject]@{ Resource = "$type/$(Get-Value $target 'resourceName' '')"; Code = $code; Message = $message.Trim(); Log = $log }
    }
}
#endregion

#region Microsoft Fabric helpers
function Invoke-Fabric {
    <# Calls the Fabric REST API (with the retry logic of Invoke-Arm) and waits for long running operations. #>
    param(
        [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')][string] $Method = 'GET',
        [Parameter(Mandatory)][string] $Path,
        $Body,
        [switch] $AllowNotFound,
        [int] $TimeoutMinutes = 20
    )
    $uri = if ($Path -match '^https://') { $Path } else { "$script:FabricApi$Path" }
    $response = Invoke-Arm -Method $Method -Path $uri -Body $Body -Resource $script:FabricResource -AllowNotFound:$AllowNotFound -OkStatus 200, 201, 202
    if (-not $response) { return $null }
    if ($response.StatusCode -ne 202) { return $response.Content }
    $operationUrl = [string](@($response.Headers['Location']) | Select-Object -First 1)
    if (-not $operationUrl) { return $response.Content }
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ($true) {
        $wait = 5
        $retryAfter = 0
        if ([int]::TryParse([string](@($response.Headers['Retry-After']) | Select-Object -First 1), [ref]$retryAfter) -and $retryAfter -gt 0) { $wait = [Math]::Min(60, $retryAfter) }
        Start-Sleep -Seconds $wait
        $response = Invoke-Arm -Path $operationUrl -Resource $script:FabricResource -OkStatus 200, 201, 202
        $status = [string](Get-Value $response.Content 'status' '')
        if ($status -eq 'Succeeded') { break }
        if ($status -in 'Failed', 'Cancelled') { throw "Fabric operation $Method $Path ended with status ${status}: $(Get-ErrorText (Get-Value $response.Content 'error'))" }
        if ((Get-Date) -gt $deadline) { throw "Fabric operation $Method $Path did not finish within $TimeoutMinutes minutes (last status: $status)." }
    }
    try { return (Invoke-Arm -Path "$($operationUrl.TrimEnd('/'))/result" -Resource $script:FabricResource -OkStatus 200 -MaxAttempts 3).Content }
    catch {
        # Some operations have no result document.
        if ([int]$_.Exception.Data['StatusCode'] -in 400, 404) { return $null }
        throw
    }
}

function Get-FabricList([string] $Path) {
    $items = [System.Collections.Generic.List[object]]::new()
    $next = $Path
    while ($next) {
        $page = Invoke-Fabric -Path $next
        foreach ($item in @(Get-Value $page 'value' @())) { $items.Add($item) }
        $next = [string](Get-Value $page 'continuationUri' '')
    }
    return $items.ToArray()
}

function Get-FabricAccessProblem([string] $UserName) {
    try {
        Invoke-Arm -Path "$script:FabricApi/workspaces" -Resource $script:FabricResource -MaxAttempts 3 | Out-Null
        return $null
    }
    catch {
        $status = [int]$_.Exception.Data['StatusCode']
        $code = [string](Get-Value $_.Exception.Data['Content'] 'errorCode' '')
        if ($code -eq 'UserNotLicensed') {
            return "Microsoft Fabric does not recognize a license for $UserName yet (UserNotLicensed). This usually means the account - or the whole tenant - has never used Fabric or Power BI; in such a tenant Azure also refuses to create Fabric capacities ('Tenant ... wasn't recognized by Microsoft Fabric'). Sign in once at https://app.fabric.microsoft.com with this account and accept the prompts (the first sign-in sets up Fabric for the user and the tenant), wait a few minutes and re-run. If Fabric still reports no license, ask your Fabric or Microsoft 365 administrator to allow self-service sign-up or to assign a Fabric (Free) or Power BI license. Nothing was deployed."
        }
        if ($status -eq 401) { return "The Fabric API rejected the sign-in ($code). Run 'az login --tenant $script:TenantId' and re-run. Details: $($_.Exception.Message)" }
        if ($status -eq 403) { return "The Fabric API denied access ($code). A Fabric administrator must allow this identity to use Fabric (for service principals: Fabric admin portal > Tenant settings > Developer settings). Details: $($_.Exception.Message)" }
        return "Could not reach the Fabric API (https://api.fabric.microsoft.com): $($_.Exception.Message)"
    }
}

function Get-FabricSkuUnits([string] $Sku) { return [int]$Sku.Substring(1) }

function Get-FabricRegionSkus([string] $Subscription, [string] $RegionName) {
    # One catalog entry per SKU and region; region display names are normalized to ARM names (West Europe -> westeurope).
    if ($null -eq $script:FabricSkuCatalog) {
        $script:FabricSkuCatalog = @(Get-ArmList "/subscriptions/$Subscription/providers/Microsoft.Fabric/skus?api-version=$script:FabricArmApiVersion" |
            Where-Object { ([string]$_.name) -match '^F\d+$' -and (Get-FabricSkuUnits $_.name) -ge 2 -and @(Get-Value $_ 'restrictions' @()).Count -eq 0 } |
            ForEach-Object {
                $sku = [string]$_.name
                foreach ($region in @(Get-Value $_ 'locations' @())) { [pscustomobject]@{ Sku = $sku; Region = ([string]$region).ToLowerInvariant().Replace(' ', '') } }
            })
    }
    return @($script:FabricSkuCatalog | Where-Object Region -eq $RegionName | ForEach-Object Sku | Sort-Object { Get-FabricSkuUnits $_ } -Unique)
}

function Get-FabricQuota([string] $Subscription, [string] $RegionName) {
    try {
        $usage = @(Get-ArmList "/subscriptions/$Subscription/providers/Microsoft.Fabric/locations/$RegionName/usages?api-version=$script:FabricArmApiVersion" |
            Where-Object { (Get-Value $_ 'name.value' '') -eq 'CapacityQuota' }) | Select-Object -First 1
        if ($usage) { return [pscustomobject]@{ Limit = [int]$usage.limit; Used = [int]$usage.currentValue; Available = [int]$usage.limit - [int]$usage.currentValue } }
    }
    catch { Write-Verbose "Fabric quota for $RegionName could not be read: $($_.Exception.Message)" }
    return $null
}

function Get-FabricRegionProblem([string] $Subscription, [string] $RegionName, [int] $Units = 2) {
    if (@(Get-FabricRegionSkus -Subscription $Subscription -RegionName $RegionName).Count -eq 0) { return "Microsoft Fabric capacities are not offered in $RegionName." }
    $quota = Get-FabricQuota -Subscription $Subscription -RegionName $RegionName
    if ($quota -and $quota.Available -lt $Units) {
        return "The subscription has $($quota.Available) of $($quota.Limit) Fabric capacity units (CU) of quota available in $RegionName (F$Units needs $Units). Choose another region or request quota (Azure portal > Quotas > Microsoft Fabric)."
    }
    return $null
}

function Get-FabricRegionsWithQuota([string] $Subscription, [string[]] $Regions = @(), [int] $Limit = 0, [int] $Units = 2) {
    # Regions (in the given order) where the whole hub can be deployed and Fabric quota is available.
    if ($Regions.Count -eq 0) {
        $null = Get-FabricRegionSkus -Subscription $Subscription -RegionName ''
        $Regions = @($script:FabricSkuCatalog | Where-Object Sku -eq "F$Units" | ForEach-Object Region | Sort-Object -Unique)
    }
    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($region in $Regions) {
        if (Get-HubRegionProblem -Subscription $Subscription -RegionName $region) { continue }
        $quota = Get-FabricQuota -Subscription $Subscription -RegionName $region
        if ($quota -and $quota.Available -ge $Units) {
            $found.Add($region)
            if ($Limit -gt 0 -and $found.Count -ge $Limit) { break }
        }
    }
    return $found.ToArray()
}

function Get-HubRegionProblem([string] $Subscription, [string] $RegionName) {
    # Besides Fabric, the hub template needs Data Factory and deployment scripts (Azure Container Instances) in its region.
    if ($null -eq $script:HubServiceRegions) {
        $script:HubServiceRegions = @{}
        foreach ($type in @('Microsoft.DataFactory/factories', 'Microsoft.ContainerInstance/containerGroups', 'Microsoft.Resources/deploymentScripts')) {
            $namespace, $resourceType = $type.Split('/')
            $provider = (Invoke-Arm -Path "/subscriptions/$Subscription/providers/$namespace`?api-version=2021-04-01").Content
            $entry = @(Get-Value $provider 'resourceTypes' @() | Where-Object { (Get-Value $_ 'resourceType' '') -eq $resourceType }) | Select-Object -First 1
            $script:HubServiceRegions[$type] = @(Get-Value $entry 'locations' @() | ForEach-Object { ([string]$_).ToLowerInvariant().Replace(' ', '') })
        }
    }
    $missing = @($script:HubServiceRegions.Keys | Where-Object { $script:HubServiceRegions[$_] -notcontains $RegionName } | Sort-Object)
    if ($missing.Count -gt 0) { return "The FinOps hub needs $($missing -join ', ') in its region, and $RegionName does not offer it for this subscription." }
    return $null
}

function Get-FabricUnitPrice([string] $RegionName) {
    # Pay-as-you-go list price of one capacity unit hour from the public Azure retail prices API (best effort).
    try {
        $filter = [uri]::EscapeDataString("serviceName eq 'Microsoft Fabric' and armRegionName eq '$RegionName' and priceType eq 'Consumption' and productName eq 'Fabric Capacity'")
        $page = Invoke-RestMethod -Uri "https://prices.azure.com/api/retail/prices?`$filter=$filter" -TimeoutSec 20
        $items = @($page.Items | Where-Object { $_.unitOfMeasure -eq '1 Hour' -and $_.meterName -like '*Capacity Usage CU' -and $_.meterName -notlike '*Overage*' })
        if ($items.Count -eq 0) { return $null }
        $price = @($items | Group-Object { [double]$_.retailPrice } | Sort-Object Count -Descending)[0].Group[0].retailPrice
        return [pscustomobject]@{ PerUnitHour = [double]$price; Currency = [string]$items[0].currencyCode }
    }
    catch {
        Write-Verbose "Fabric prices could not be read: $($_.Exception.Message)"
        return $null
    }
}

function Format-FabricCost($Price, [int] $Units) {
    if (-not $Price) { return 'see Azure pricing' }
    return '~{0:N2} {1}/hour (~{2:N0} {1}/month if never paused)' -f ($Units * $Price.PerUnitHour), $Price.Currency, ($Units * $Price.PerUnitHour * 730)
}

function Get-HubNameValue {
    if ($HubName) { return $HubName }
    $fromFile = [string](Get-Value (Get-Content -Path $TemplateParameterFile -Raw | ConvertFrom-Json -AsHashtable) 'parameters.hubName.value' '')
    if ($fromFile) { return $fromFile }
    return 'finops-hub'
}

function Get-DefaultFabricCapacityName([string] $Hub, [string] $Subscription, [string] $Group) {
    $base = $Hub.ToLowerInvariant() -replace '[^a-z0-9]', ''
    if ($base.Length -gt 40) { $base = $base.Substring(0, 40) }
    return "fc$base$((New-DeterministicGuid "$Subscription/$Group").Replace('-', '').Substring(0, 6))"
}

function Read-FabricCapacitySku([string[]] $Skus, $Price, $AvailableUnits, [string] $CurrentSku, [string] $RegionName) {
    $choices = @($Skus | Where-Object { $null -eq $AvailableUnits -or (Get-FabricSkuUnits $_) -le $AvailableUnits -or $_ -eq $CurrentSku } | Sort-Object { Get-FabricSkuUnits $_ })
    if ($CurrentSku -and $choices -contains $CurrentSku) { $choices = @($CurrentSku) + @($choices | Where-Object { $_ -ne $CurrentSku }) }
    $labels = @(foreach ($sku in $choices) {
            $units = Get-FabricSkuUnits $sku
            $note = if ($sku -eq $CurrentSku) { '  <- current SKU' } elseif ($units -eq 2) { '  <- lowest cost, recommended for testing' } else { '' }
            '{0,-6} {1,5} CU   {2}{3}' -f $sku, $units, (Format-FabricCost -Price $Price -Units $units), $note
        })
    $quotaText = if ($null -ne $AvailableUnits) { " ($AvailableUnits CU of quota available)" } else { '' }
    Write-Host ''
    Write-Info 'The Fabric capacity is billed per hour while it is active (pay-as-you-go list price); it can be paused when not in use.'
    return (Read-Selection -Title "Fabric capacity SKU in $RegionName$quotaText" -Items $choices -Labels $labels)
}

function Wait-FabricCapacity([string] $CapacityId, [int] $TimeoutMinutes = 30) {
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ($true) {
        $capacity = (Invoke-Arm -Path "$CapacityId`?api-version=$script:FabricArmApiVersion").Content
        $provisioning = [string](Get-Value $capacity 'properties.provisioningState' '')
        $state = [string](Get-Value $capacity 'properties.state' '')
        if ($provisioning -eq 'Succeeded' -and $state -eq 'Active') { return $capacity }
        if ($provisioning -in 'Failed', 'Canceled' -or $state -eq 'Failed') { throw "Fabric capacity $($CapacityId.Split('/')[-1]) is $provisioning/$state." }
        if ((Get-Date) -gt $deadline) { throw "Fabric capacity $($CapacityId.Split('/')[-1]) did not become active within $TimeoutMinutes minutes ($provisioning/$state)." }
        Start-Sleep -Seconds 15
    }
}

function Set-FabricCapacity([string] $CapacityId, [string] $RegionName, [string] $Sku, [string[]] $Admins, [hashtable] $ResourceTags) {
    $path = "$CapacityId`?api-version=$script:FabricArmApiVersion"
    $existing = Invoke-Arm -Path $path -AllowNotFound
    if (-not $existing) {
        Write-Info "Creating Fabric capacity $($CapacityId.Split('/')[-1]) ($Sku) in $RegionName..."
        $body = @{ location = $RegionName; sku = @{ name = $Sku; tier = 'Fabric' }; properties = @{ administration = @{ members = @($Admins) } }; tags = $ResourceTags }
        try { Invoke-Arm -Method PUT -Path $path -Body $body -OkStatus 200, 201 | Out-Null }
        catch {
            if ($_.Exception.Message -match "wasn't recognized by Microsoft Fabric") {
                throw "Azure refused to create the Fabric capacity because tenant $script:TenantId has not been set up in Microsoft Fabric yet. A user must sign in once at https://app.fabric.microsoft.com (this sets up Fabric for the tenant); then re-run."
            }
            throw
        }
        return (Wait-FabricCapacity -CapacityId $CapacityId)
    }
    $capacity = $existing.Content
    $state = [string](Get-Value $capacity 'properties.state' '')
    if ($state -in 'Paused', 'Suspended') {
        Write-Info "Fabric capacity is $state; resuming it (billing restarts while it is active)..."
        Invoke-Arm -Method POST -Path "$CapacityId/resume?api-version=$script:FabricArmApiVersion" -OkStatus 200, 202 | Out-Null
    }
    $capacity = Wait-FabricCapacity -CapacityId $CapacityId
    $members = @(Get-Value $capacity 'properties.administration.members' @())
    $newAdmins = @($Admins | Where-Object { $_ -notin $members })
    $tags = @{}
    $currentTags = Get-Value $capacity 'tags'
    if ($currentTags) { foreach ($tag in $currentTags.PSObject.Properties) { $tags[$tag.Name] = $tag.Value } }
    $tagsChanged = $false
    foreach ($key in $ResourceTags.Keys) { if ($tags[$key] -ne $ResourceTags[$key]) { $tags[$key] = $ResourceTags[$key]; $tagsChanged = $true } }
    $currentSku = [string](Get-Value $capacity 'sku.name' '')
    if ($currentSku -ne $Sku -or $newAdmins.Count -gt 0 -or $tagsChanged) {
        Write-Info "Updating Fabric capacity (SKU $currentSku -> $Sku, $($newAdmins.Count) new administrator(s), tags changed: $tagsChanged)..."
        $body = @{ sku = @{ name = $Sku; tier = 'Fabric' }; properties = @{ administration = @{ members = @($members + $newAdmins) } }; tags = $tags }
        Invoke-Arm -Method PATCH -Path $path -Body $body -OkStatus 200, 202 -RetryOnConflict | Out-Null
        Start-Sleep -Seconds 10
        $capacity = Wait-FabricCapacity -CapacityId $CapacityId
    }
    return $capacity
}

function Get-FabricCapacityGuid([string] $CapacityName, [string] $RegionName, [int] $TimeoutMinutes = 10) {
    # Fabric lists the capacities the caller administers; a new capacity can take a few minutes to appear.
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ($true) {
        $match = @(Get-FabricList '/capacities' | Where-Object {
                (Get-Value $_ 'displayName' '') -ieq $CapacityName -and ([string](Get-Value $_ 'region' '')).ToLowerInvariant().Replace(' ', '') -eq $RegionName }) | Select-Object -First 1
        if ($match -and (Get-Value $match 'state' '') -eq 'Active') { return [string]$match.id }
        if ((Get-Date) -gt $deadline) { throw "Fabric capacity '$CapacityName' is not listed as active by the Fabric API. The signed-in identity must be one of its capacity administrators." }
        Start-Sleep -Seconds 15
    }
}

function Find-FabricWorkspace([string] $Name) {
    return @(Get-FabricList '/workspaces' | Where-Object { (Get-Value $_ 'displayName' '') -ieq $Name -and (Get-Value $_ 'type' '') -eq 'Workspace' }) | Select-Object -First 1
}

function Set-FabricWorkspace([string] $Name, [string] $CapacityGuid) {
    $workspace = Find-FabricWorkspace $Name
    if (-not $workspace) {
        $workspace = Invoke-Fabric -Method POST -Path '/workspaces' -Body @{ displayName = $Name; capacityId = $CapacityGuid; description = 'FinOps hub (FinOps toolkit) data store - managed by Deploy-FinOpsHub-V3-Fabric.ps1' }
        if (-not (Get-Value $workspace 'id')) { $workspace = Find-FabricWorkspace $Name }
        Write-Ok "Created Fabric workspace '$Name'"
    }
    else {
        $assigned = [string](Get-Value $workspace 'capacityId' '')
        if (-not $assigned) {
            Invoke-Fabric -Method POST -Path "/workspaces/$($workspace.id)/assignToCapacity" -Body @{ capacityId = $CapacityGuid } | Out-Null
            Write-Ok "Assigned the existing workspace '$Name' to the capacity"
        }
        elseif ($assigned -ne $CapacityGuid) { throw "Fabric workspace '$Name' is assigned to another capacity ($assigned). Use -FabricWorkspaceName with a new name." }
        else { Write-Ok "Fabric workspace '$Name' already exists on the capacity" }
    }
    $deadline = (Get-Date).AddMinutes(10)
    while ($true) {
        $current = Invoke-Fabric -Path "/workspaces/$($workspace.id)"
        $progress = [string](Get-Value $current 'capacityAssignmentProgress' 'Completed')
        if ($progress -eq 'Completed' -and (Get-Value $current 'capacityId' '') -eq $CapacityGuid) { return $current }
        if ($progress -eq 'Failed') { throw "Assigning Fabric workspace '$Name' to the capacity failed." }
        if ((Get-Date) -gt $deadline) { throw "Fabric workspace '$Name' was not assigned to the capacity within 10 minutes (progress: $progress)." }
        Start-Sleep -Seconds 10
    }
}

function Set-FabricWorkspaceIdentity([string] $WorkspaceId) {
    $identity = Get-Value (Invoke-Fabric -Path "/workspaces/$WorkspaceId") 'workspaceIdentity'
    if (-not (Get-Value $identity 'servicePrincipalId' '')) {
        Write-Info 'Provisioning the workspace identity (used for trusted access through the storage firewall)...'
        $identity = Invoke-Fabric -Method POST -Path "/workspaces/$WorkspaceId/provisionIdentity"
        if (-not (Get-Value $identity 'servicePrincipalId' '')) { $identity = Get-Value (Invoke-Fabric -Path "/workspaces/$WorkspaceId") 'workspaceIdentity' }
    }
    if (-not (Get-Value $identity 'servicePrincipalId' '')) { throw 'The Fabric workspace identity could not be provisioned.' }
    return [pscustomobject]@{ ApplicationId = [string](Get-Value $identity 'applicationId' ''); ServicePrincipalId = [string]$identity.servicePrincipalId }
}

function Set-FabricWorkspaceRole([string] $WorkspaceId, [string] $PrincipalId, [string] $PrincipalType, [string] $Role) {
    # Adds the role, or raises a lower one; never lowers an existing role.
    $rank = @{ Viewer = 1; Contributor = 2; Member = 3; Admin = 4 }
    $existing = @(Get-FabricList "/workspaces/$WorkspaceId/roleAssignments" | Where-Object { (Get-Value $_ 'principal.id' '') -eq $PrincipalId }) | Select-Object -First 1
    if ($existing) {
        $current = [string](Get-Value $existing 'role' '')
        if ($rank[$current] -ge $rank[$Role]) { return "$current (existing)" }
        Invoke-Fabric -Method PATCH -Path "/workspaces/$WorkspaceId/roleAssignments/$($existing.id)" -Body @{ role = $Role } | Out-Null
        return "$Role (raised from $current)"
    }
    Invoke-Fabric -Method POST -Path "/workspaces/$WorkspaceId/roleAssignments" -Body @{ principal = @{ id = $PrincipalId; type = $PrincipalType }; role = $Role } | Out-Null
    return $Role
}

function Set-FabricEventhouse([string] $WorkspaceId, [string] $Name) {
    $find = { @(Get-FabricList "/workspaces/$WorkspaceId/eventhouses" | Where-Object { (Get-Value $_ 'displayName' '') -ieq $Name }) | Select-Object -First 1 }
    $eventhouse = & $find
    if (-not $eventhouse) {
        Write-Info "Creating eventhouse '$Name'..."
        $eventhouse = Invoke-Fabric -Method POST -Path "/workspaces/$WorkspaceId/eventhouses" -Body @{ displayName = $Name; description = 'FinOps hub eventhouse (Ingestion and Hub databases)' }
        if (-not (Get-Value $eventhouse 'id')) { $eventhouse = & $find }
        Write-Ok "Created eventhouse '$Name'"
    }
    else { Write-Ok "Eventhouse '$Name' already exists" }
    # The query URI is available once the eventhouse is provisioned.
    $deadline = (Get-Date).AddMinutes(15)
    while ($true) {
        $eventhouse = Invoke-Fabric -Path "/workspaces/$WorkspaceId/eventhouses/$($eventhouse.id)"
        if (Get-Value $eventhouse 'properties.queryServiceUri' '') { return $eventhouse }
        if ((Get-Date) -gt $deadline) { throw "Eventhouse '$Name' has no query URI after 15 minutes." }
        Start-Sleep -Seconds 10
    }
}

function Set-FabricKqlDatabase([string] $WorkspaceId, [string] $EventhouseId, [string] $Name) {
    $find = { @(Get-FabricList "/workspaces/$WorkspaceId/kqlDatabases" | Where-Object { (Get-Value $_ 'displayName' '') -ieq $Name }) | Select-Object -First 1 }
    $database = & $find
    if ($database) {
        $parent = [string](Get-Value $database 'properties.parentEventhouseItemId' '')
        if ($parent -and $parent -ne $EventhouseId) { throw "The workspace already has a KQL database named '$Name' in another eventhouse. Use another -FabricWorkspaceName (the FinOps hub needs the Ingestion and Hub databases in one eventhouse)." }
        Write-Ok "KQL database '$Name' already exists"
    }
    else {
        $database = Invoke-Fabric -Method POST -Path "/workspaces/$WorkspaceId/kqlDatabases" -Body @{ displayName = $Name; creationPayload = @{ databaseType = 'ReadWrite'; parentEventhouseItemId = $EventhouseId } }
        if (-not (Get-Value $database 'id')) { $database = & $find }
        Write-Ok "Created KQL database '$Name'"
    }
    return (Invoke-Fabric -Path "/workspaces/$WorkspaceId/kqlDatabases/$($database.id)")
}

function Test-KustoTransientError([string] $Message) {
    # A new or resizing eventhouse briefly rejects admin commands while it moves databases between nodes.
    return $Message -match 'cannot be executed temporarily|internal state transition|BecomingSecondary|please try again later'
}

function Invoke-KustoCommand {
    <# Runs a management command (default) or a query against a Fabric eventhouse and returns the first result table. #>
    param(
        [Parameter(Mandatory)][string] $ClusterUri,
        [Parameter(Mandatory)][string] $Database,
        [Parameter(Mandatory)][string] $Command,
        [switch] $Query,
        [int] $TimeoutSec = 300,
        [int] $MaxAttempts = 4
    )
    $endpoint = if ($Query) { 'query' } else { 'mgmt' }
    for ($attempt = 1; ; $attempt++) {
        try {
            $response = Invoke-Arm -Method POST -Path "$($ClusterUri.TrimEnd('/'))/v1/rest/$endpoint" -Resource $script:KustoResource -Body @{ db = $Database; csl = $Command } -OkStatus 200 -TimeoutSec $TimeoutSec -MaxAttempts $MaxAttempts
            break
        }
        catch {
            if ($attempt -ge 6 -or -not (Test-KustoTransientError $_.Exception.Message)) { throw }
            $wait = [Math]::Min(120, 30 * $attempt)
            Write-Info "The eventhouse is busy with a temporary internal change; retrying in $wait seconds (attempt $($attempt + 1) of 6)..."
            Start-Sleep -Seconds $wait
        }
    }
    $tables = @(Get-Value $response.Content 'Tables' @())
    if ($tables.Count -eq 0) { return }
    $columns = @($tables[0].Columns | ForEach-Object { [string]$_.ColumnName })
    foreach ($row in $tables[0].Rows) {
        $record = [ordered]@{}
        for ($i = 0; $i -lt $columns.Count; $i++) { $record[$columns[$i]] = $row[$i] }
        [pscustomobject]$record
    }
}

function Invoke-FabricSetupScript([string] $QueryUri, [string] $Database, [string] $ScriptPath, [int] $RawRetentionInDays, [int] $MaxAttempts = 8) {
    # The FinOps toolkit setup scripts are single '.execute database script' commands; every inner command is checked.
    $text = (Get-Content -Path $ScriptPath -Raw).Replace('$$rawRetentionInDays$$', [string]$RawRetentionInDays)
    if ($text -notmatch '^\s*\.execute database script') { throw "$ScriptPath is not a FinOps hub Fabric setup script (.execute database script)." }
    $leftover = [regex]::Match($text, '\$\$[A-Za-z0-9_]+\$\$')
    if ($leftover.Success) { throw "$ScriptPath contains the unsupported placeholder $($leftover.Value)." }
    for ($attempt = 1; ; $attempt++) {
        $rows = @(Invoke-KustoCommand -ClusterUri $QueryUri -Database $Database -Command $text -TimeoutSec 900 -MaxAttempts 2)
        $failed = @($rows | Where-Object { [string](Get-Value $_ 'Result' '') -ne 'Completed' })
        # Re-running the idempotent script also completes commands that failed only because an earlier one was rejected.
        $transient = @($failed | Where-Object { Test-KustoTransientError ([string](Get-Value $_ 'Reason' '')) })
        if ($transient.Count -eq 0 -or $attempt -ge $MaxAttempts) { break }
        $wait = [Math]::Min(120, 30 * $attempt)
        Write-Info "The new eventhouse is still getting ready ($($transient.Count) of $($rows.Count) commands were asked to try again later); re-running the script in $wait seconds (attempt $($attempt + 1) of $MaxAttempts)..."
        Start-Sleep -Seconds $wait
    }
    return [pscustomobject]@{
        Database = $Database
        Commands = $rows.Count
        Failed   = $failed.Count
        Attempts = $attempt
        Errors   = @($failed | Select-Object -First 5 | ForEach-Object { "$(Get-Value $_ 'CommandType' ''): $(Get-Value $_ 'Reason' '')" })
    }
}

function Grant-FabricDatabaseAdmin([string] $QueryUri, [string[]] $Databases, [string] $PrincipalObjectId) {
    # Documented step "Configure Fabric access": .add database <db> admins ('aadapp=<Data Factory identity>').
    $appId = ''
    try { $appId = [string](Get-Value (Invoke-Arm -Resource 'https://graph.microsoft.com/' -Path "https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalObjectId`?`$select=appId" -MaxAttempts 3).Content 'appId' '') }
    catch { Write-Verbose "Could not read the application ID of $PrincipalObjectId from Microsoft Graph: $($_.Exception.Message)" }
    $fqn = "aadapp=$(if ($appId) { $appId } else { $PrincipalObjectId });$script:TenantId"
    $isAdmin = {
        param([string] $Name)
        @(Invoke-KustoCommand -ClusterUri $QueryUri -Database $Name -Command ".show database ['$Name'] principals" | Where-Object {
                ([string](Get-Value $_ 'Role' '')) -like '*Admin*' -and (([string](Get-Value $_ 'PrincipalObjectId' '')) -eq $PrincipalObjectId -or ($appId -and ([string](Get-Value $_ 'PrincipalFQN' '')) -like "*$appId*")) }).Count -gt 0
    }
    foreach ($database in $Databases) {
        $already = & $isAdmin $database
        if (-not $already) { Invoke-KustoCommand -ClusterUri $QueryUri -Database $database -Command ".add database ['$database'] admins ('$fqn') 'FinOps hub Data Factory'" | Out-Null }
        $granted = $already -or (& $isAdmin $database)
        if ($granted) { Write-Ok "Data Factory identity is admin of the $database database$(if ($already) { ' (existing)' })" }
        else { Write-Warn "Data Factory identity was added to the $database database but does not show as admin yet." }
        [pscustomobject]@{ Database = $database; Principal = $fqn; Admin = $granted }
    }
}

function Grant-FabricWorkspaceViewers([string] $WorkspaceId, [string[]] $PrincipalIds) {
    $ids = @($PrincipalIds | Where-Object { $_ })
    if ($ids.Count -eq 0) { Write-Info 'No -FabricViewers given; only workspace members can use the dashboard.'; return }
    $lookup = (Invoke-Arm -Method POST -Resource 'https://graph.microsoft.com/' -Path 'https://graph.microsoft.com/v1.0/directoryObjects/getByIds' -Body @{ ids = $ids; types = @('user', 'group', 'servicePrincipal') }).Content
    $found = @(Get-Value $lookup 'value' @())
    foreach ($object in $found) {
        # The '@odata.type' property name contains a dot, so it is read directly (not with Get-Value).
        $odataType = [string]$object.PSObject.Properties['@odata.type'].Value
        $type = switch ($odataType) { '#microsoft.graph.group' { 'Group' } '#microsoft.graph.servicePrincipal' { 'ServicePrincipal' } default { 'User' } }
        $result = Set-FabricWorkspaceRole -WorkspaceId $WorkspaceId -PrincipalId $object.id -PrincipalType $type -Role 'Viewer'
        Write-Ok "Workspace access for $type $($object.id): $result"
    }
    foreach ($missing in @($ids | Where-Object { $_ -notin @($found | ForEach-Object id) })) { Write-Warn "Entra object $missing was not found; no workspace access granted." }
}

function Set-FabricStorageAccess($Hub, [string] $WorkspaceId, [switch] $KeepFirewallClosed) {
    # Eventhouse ingestion can't pass a storage firewall (FinOps toolkit #2061); the template resets these rules on every deployment.
    $ruleId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourcegroups/Fabric/providers/Microsoft.Fabric/workspaces/$WorkspaceId"
    $storage = (Invoke-Arm -Path "$($Hub.StorageId)?api-version=2023-05-01").Content
    $acls = Get-Value $storage 'properties.networkAcls'
    $rules = @(Get-Value $acls 'resourceAccessRules' @())
    $hasRule = @($rules | Where-Object { (Get-Value $_ 'resourceId' '') -ieq $ruleId }).Count -gt 0
    $currentAction = [string](Get-Value $acls 'defaultAction' 'Deny')
    $defaultAction = if ($KeepFirewallClosed) { $currentAction } else { 'Allow' }
    if ($hasRule -and $currentAction -eq $defaultAction) { return [pscustomobject]@{ RuleId = $ruleId; DefaultAction = $defaultAction; Changed = $false } }
    if (-not $hasRule) { $rules += [ordered]@{ tenantId = $script:TenantId; resourceId = $ruleId } }
    $networkAcls = [ordered]@{
        bypass              = Get-Value $acls 'bypass' 'AzureServices'
        defaultAction       = $defaultAction
        ipRules             = @(Get-Value $acls 'ipRules' @())
        virtualNetworkRules = @(Get-Value $acls 'virtualNetworkRules' @())
        resourceAccessRules = $rules
    }
    Invoke-Arm -Method PATCH -Path "$($Hub.StorageId)?api-version=2023-05-01" -Body @{ properties = @{ networkAcls = $networkAcls } } -RetryOnConflict | Out-Null
    return [pscustomobject]@{ RuleId = $ruleId; DefaultAction = $defaultAction; Changed = $true }
}

function Get-FabricIngestionHealth([string] $QueryUri, [DateTime] $SinceUtc) {
    # Load failures after the storage settings took effect, and the cost rows the Hub database returns.
    $since = $SinceUtc.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $failures = @(Invoke-KustoCommand -ClusterUri $QueryUri -Database 'Ingestion' -Command ".show ingestion failures | where FailedOn > datetime($since) | summarize Failures = count() by ErrorCode" -MaxAttempts 2)
    $rows = [long](@(Invoke-KustoCommand -ClusterUri $QueryUri -Database 'Hub' -Command 'Costs() | count' -Query -MaxAttempts 2) | Select-Object -First 1 | ForEach-Object { Get-Value $_ 'Count' 0 })
    $forbidden = [long](@($failures | Where-Object { (Get-Value $_ 'ErrorCode' '') -like 'Download_Forbidden*' } | ForEach-Object { [long](Get-Value $_ 'Failures' 0) }) | Measure-Object -Sum).Sum
    return [pscustomobject]@{
        CostRows           = $rows
        StorageAccessFails = $forbidden
        OtherFailures      = @($failures | Where-Object { (Get-Value $_ 'ErrorCode' '') -notlike 'Download_Forbidden*' } | ForEach-Object { "$(Get-Value $_ 'ErrorCode' '') x$(Get-Value $_ 'Failures' 0)" })
        Since              = $since
    }
}

function Restart-FailedHubIngestion([string] $FactoryId, [int] $Days = 7) {
    # Re-queues every folder whose most recent ingestion run failed or was cancelled (for example, before storage access worked).
    $pipeline = @(Get-ArmList "$FactoryId/pipelines?api-version=2018-06-01" | Where-Object { ([string]$_.name) -like '*ingestion_ExecuteETL' }) | Select-Object -First 1
    if (-not $pipeline) { return @() }
    $window = @{
        lastUpdatedAfter  = [DateTime]::UtcNow.AddDays(-$Days).ToString('o')
        lastUpdatedBefore = [DateTime]::UtcNow.AddMinutes(5).ToString('o')
        filters           = @(@{ operand = 'PipelineName'; operator = 'Equals'; values = @([string]$pipeline.name) })
    }
    $runs = [System.Collections.Generic.List[object]]::new()
    $body = $window
    do {
        $page = (Invoke-Arm -Method POST -Path "$FactoryId/queryPipelineRuns?api-version=2018-06-01" -Body $body).Content
        foreach ($run in @(Get-Value $page 'value' @())) { $runs.Add($run) }
        $token = [string](Get-Value $page 'continuationToken' '')
        $body = if ($token) { $window + @{ continuationToken = $token } } else { $null }
    } while ($body)
    $latest = @($runs | Where-Object { Get-Value $_ 'parameters.folderPath' '' } | Group-Object { ([string](Get-Value $_ 'parameters.folderPath' '')).ToLowerInvariant() } | ForEach-Object {
            @($_.Group | Sort-Object { [DateTime](Get-Value $_ 'runStart' ([DateTime]::MinValue)) } -Descending)[0]
        })
    $restarted = foreach ($run in @($latest | Where-Object { (Get-Value $_ 'status' '') -in 'Failed', 'Cancelled' })) {
        $folder = [string](Get-Value $run 'parameters.folderPath' '')
        Invoke-Arm -Method POST -Path "$FactoryId/pipelines/$($pipeline.name)/createRun?api-version=2018-06-01" -Body @{ folderPath = $folder } | Out-Null
        $folder
    }
    return @($restarted)
}

function Invoke-HubPipeline([string] $FactoryId, [string] $NameSuffix, [int] $TimeoutMinutes = 20) {
    <# The template starts the initialization pipeline at the end of its deployment, before Data Factory can use the Fabric
       databases; that run retries (up to 2 hours) until it has access. The pipeline allows one run at a time, so a run in
       progress is awaited instead of queueing another; a new run is started when none is active or the awaited run failed. #>
    $pipeline = @(Get-ArmList "$FactoryId/pipelines?api-version=2018-06-01" | Where-Object { ([string]$_.name) -like "*$NameSuffix" }) | Select-Object -First 1
    if (-not $pipeline) { return [pscustomobject]@{ Pipeline = "*$NameSuffix"; RunId = ''; Status = 'NotFound'; Error = 'Pipeline not found in the Data Factory.' } }
    $query = @{
        lastUpdatedAfter  = [DateTime]::UtcNow.AddDays(-1).ToString('o')
        lastUpdatedBefore = [DateTime]::UtcNow.AddMinutes(5).ToString('o')
        filters           = @(@{ operand = 'PipelineName'; operator = 'Equals'; values = @([string]$pipeline.name) })
    }
    $active = @(Get-Value (Invoke-Arm -Method POST -Path "$FactoryId/queryPipelineRuns?api-version=2018-06-01" -Body $query).Content 'value' @() |
        Where-Object { (Get-Value $_ 'status' '') -in 'InProgress', 'Queued' } | Sort-Object { [DateTime](Get-Value $_ 'runStart' ([DateTime]::MaxValue)) })
    $attempts = if ($active.Count -gt 0) { @('existing', 'new') } else { @('new') }
    $result = $null
    foreach ($attempt in $attempts) {
        if ($attempt -eq 'existing') {
            $runId = [string]$active[0].runId
            Write-Info "Waiting for the initialization run the template started ($runId); it continues as soon as Data Factory can use the databases..."
        }
        else { $runId = [string](Get-Value (Invoke-Arm -Method POST -Path "$FactoryId/pipelines/$($pipeline.name)/createRun?api-version=2018-06-01" -Body @{}).Content 'runId' '') }
        $started = [DateTime]::UtcNow
        $deadline = $started.AddMinutes($TimeoutMinutes)
        do {
            Start-Sleep -Seconds 20
            $run = (Invoke-Arm -Path "$FactoryId/pipelineruns/$runId`?api-version=2018-06-01").Content
            $status = [string](Get-Value $run 'status' 'Unknown')
        } while ($status -in 'Queued', 'InProgress', 'Canceling' -and [DateTime]::UtcNow -lt $deadline)
        $errorText = ''
        if ($status -eq 'Failed') {
            try {
                $window = @{ lastUpdatedAfter = $started.AddHours(-3).ToString('o'); lastUpdatedBefore = [DateTime]::UtcNow.AddMinutes(5).ToString('o') }
                $activities = @(Get-Value (Invoke-Arm -Method POST -Path "$FactoryId/pipelineruns/$runId/queryActivityruns?api-version=2018-06-01" -Body $window).Content 'value' @())
                $failedActivity = @($activities | Where-Object { (Get-Value $_ 'status' '') -eq 'Failed' } | Sort-Object { [DateTime](Get-Value $_ 'activityRunStart' ([DateTime]::MinValue)) } -Descending) | Select-Object -First 1
                if ($failedActivity) { $errorText = "$(Get-Value $failedActivity 'activityName' ''): $(Get-Value $failedActivity 'error.message' '')" }
            }
            catch { Write-Verbose "Could not read the activity runs: $($_.Exception.Message)" }
            if (-not $errorText) { $errorText = [string](Get-Value $run 'message' '') }
        }
        $result = [pscustomobject]@{ Pipeline = [string]$pipeline.name; RunId = $runId; Status = $status; Error = $errorText }
        if ($status -ne 'Failed') { break }
    }
    return $result
}

function Import-FabricDashboard([string] $WorkspaceId, [string] $QueryUri, [string] $HubDatabaseId, [string] $Title) {
    # Same result as the documented "Replace with file" + "Data sources > Eventhouse / KQL database > Hub".
    $document = [System.Text.Json.Nodes.JsonNode]::Parse((Get-Content -Path $DashboardFile -Raw))
    foreach ($key in @('$schema', 'id', 'eTag')) { $null = $document.AsObject().Remove($key) }
    $document['title'] = [System.Text.Json.Nodes.JsonValue]::Create($Title)
    $sources = 0
    foreach ($dataSource in $document['dataSources'].AsArray()) {
        if ([string]$dataSource['kind'] -notlike '*kusto*') { continue }
        $dataSource['kind'] = [System.Text.Json.Nodes.JsonValue]::Create('kusto-trident')
        $dataSource['scopeId'] = [System.Text.Json.Nodes.JsonValue]::Create('kusto-trident')
        $dataSource['clusterUri'] = [System.Text.Json.Nodes.JsonValue]::Create($QueryUri)
        $dataSource['database'] = [System.Text.Json.Nodes.JsonValue]::Create($HubDatabaseId)
        $dataSource['workspace'] = [System.Text.Json.Nodes.JsonValue]::Create($WorkspaceId)
        $sources++
    }
    if ($sources -eq 0) { throw "No Kusto data source found in $DashboardFile." }
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($document.ToJsonString()))
    $definition = @{ parts = @(@{ path = 'RealTimeDashboard.json'; payload = $payload; payloadType = 'InlineBase64' }) }
    $find = { @(Get-FabricList "/workspaces/$WorkspaceId/kqlDashboards" | Where-Object { (Get-Value $_ 'displayName' '') -ieq $Title }) | Select-Object -First 1 }
    $existing = & $find
    if ($existing) {
        Invoke-Fabric -Method POST -Path "/workspaces/$WorkspaceId/kqlDashboards/$($existing.id)/updateDefinition?updateMetadata=false" -Body @{ definition = $definition } | Out-Null
        $dashboardId = [string]$existing.id
        Write-Ok "Updated the existing Fabric real-time dashboard '$Title'"
    }
    else {
        $created = Invoke-Fabric -Method POST -Path "/workspaces/$WorkspaceId/kqlDashboards" -Body @{ displayName = $Title; description = 'FinOps hub dashboard (FinOps toolkit)'; definition = $definition }
        $dashboardId = [string](Get-Value $created 'id' '')
        if (-not $dashboardId) { $dashboardId = [string](Get-Value (& $find) 'id' '') }
        Write-Ok "Imported the Fabric real-time dashboard '$Title'"
    }
    # Read the definition back to confirm Fabric kept the tiles and the Hub database connection.
    $tiles = 0
    $connected = $false
    $saved = Invoke-Fabric -Method POST -Path "/workspaces/$WorkspaceId/kqlDashboards/$dashboardId/getDefinition"
    $part = @(Get-Value $saved 'definition.parts' @() | Where-Object { (Get-Value $_ 'path' '') -eq 'RealTimeDashboard.json' }) | Select-Object -First 1
    if ($part) {
        $content = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$part.payload)) | ConvertFrom-Json -Depth 100
        $tiles = @(Get-Value $content 'tiles' @()).Count
        $connected = @(Get-Value $content 'dataSources' @() | Where-Object { (Get-Value $_ 'database' '') -eq $HubDatabaseId }).Count -gt 0
    }
    return [pscustomobject]@{ Id = $dashboardId; Title = $Title; Tiles = $tiles; Connected = $connected; Url = "https://app.fabric.microsoft.com/groups/$WorkspaceId/kustodashboards/$dashboardId`?experience=fabric-developer" }
}
#endregion

#region Step implementations
function Get-EffectiveTemplateParameters {
    $raw = Get-Content -Path $TemplateParameterFile -Raw | ConvertFrom-Json -AsHashtable
    $fileParameters = Get-Value $raw 'parameters' @{}
    $values = [ordered]@{}
    foreach ($key in $fileParameters.Keys) {
        $entry = $fileParameters[$key]
        if ($entry -is [System.Collections.IDictionary] -and $entry.Contains('value') -and $null -ne $entry['value']) { $values[$key] = $entry['value'] }
    }
    $values['hubName'] = Get-HubNameValue
    if ($Location) { $values['location'] = $Location }
    if (-not $values.Contains('location') -or -not $values['location']) { throw 'No location. Pass -Location or set "location" in the parameters file.' }
    $values['location'] = ([string]$values['location']).ToLowerInvariant().Replace(' ', '')
    # Fabric is the data store: never deploy Azure Data Explorer. fabricQueryUri is set once the eventhouse exists.
    $values['dataExplorerName'] = ''
    $values['fabricQueryUri'] = ''
    if ($HubVirtualNetworkAddressPrefix) { $values['virtualNetworkAddressPrefix'] = $HubVirtualNetworkAddressPrefix }
    if ($EnableRecommendations) { $values['enableRecommendations'] = $true }
    # This script creates the exports itself; managed exports stay off unless explicitly enabled in the file.
    if (-not $values.Contains('enableManagedExports')) { $values['enableManagedExports'] = $false }
    $values['enablePublicAccess'] = $false
    $mergedTags = @{}
    foreach ($source in @((Get-Value $values 'tags' @{}), $Tags)) { foreach ($key in $source.Keys) { $mergedTags[$key] = $source[$key] } }
    $values['tags'] = $mergedTags
    $prefix = [string](Get-Value $values 'virtualNetworkAddressPrefix' '10.20.30.0/26')
    if ($prefix -notmatch '^\d{1,3}(\.\d{1,3}){3}/(\d|1\d|2[0-6])$') { throw "virtualNetworkAddressPrefix '$prefix' must be a valid CIDR of /26 or larger." }
    return $values
}

function Get-HubResourceIds($Outputs, [hashtable] $TemplateValues) {
    $storageId = [string](Get-Value $Outputs 'storageAccountId.value')
    $factoryName = [string](Get-Value $Outputs 'dataFactoryName.value')
    return [pscustomobject]@{
        StorageId         = $storageId
        StorageName       = $storageId.Split('/')[-1]
        DataFactoryName   = $factoryName
        DataFactoryId     = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.DataFactory/factories/$factoryName"
        QueryUri          = [string](Get-Value $Outputs 'clusterUri.value' '')
        HubDatabase       = [string](Get-Value $Outputs 'hubDbName.value' 'Hub')
        IngestionDatabase = [string](Get-Value $Outputs 'ingestionDbName.value' 'Ingestion')
        PrincipalId       = [string](Get-Value $Outputs 'managedIdentityId.value' '')
        StorageUrlPowerBI = [string](Get-Value $Outputs 'storageUrlForPowerBI.value' '')
        Location          = [string]$TemplateValues['location']
    }
}

function Get-HubDnsZoneNames {
    # Private endpoints of a Fabric hub: storage (blob, dfs), Data Factory (dataFactory, portal); Key Vault is added when present.
    return @('privatelink.blob.core.windows.net', 'privatelink.dfs.core.windows.net', 'privatelink.datafactory.azure.net', 'privatelink.adf.azure.com')
}

function Get-PrivateDnsZonePlan([string[]] $ZoneNames, [string] $VirtualNetworkId, [string] $DnsSubscription, [string] $DnsResourceGroup) {
    <# Per zone: Reuse the zone already linked to the virtual network (any subscription), else Link the zone that exists
       in the DNS resource group, else Create it there. A virtual network can link only one zone of a given name. #>
    $linked = @{}
    $query = "resources | where type =~ 'microsoft.network/privatednszones/virtualnetworklinks' | where tolower(tostring(properties.virtualNetwork.id)) == '$($VirtualNetworkId.ToLowerInvariant())' | project id"
    foreach ($row in @(Invoke-ResourceGraph $query)) {
        $zoneId = ($row.id -split '/virtualNetworkLinks/')[0]
        $linked[$zoneId.Split('/')[-1].ToLowerInvariant()] = $zoneId
    }
    $inGroup = @{}
    foreach ($zone in @(Get-ArmList "/subscriptions/$DnsSubscription/resourceGroups/$DnsResourceGroup/providers/Microsoft.Network/privateDnsZones?api-version=2024-06-01")) {
        $inGroup[$zone.name.ToLowerInvariant()] = $zone
    }
    $hubRgPrefix = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/".ToLowerInvariant()
    foreach ($name in $ZoneNames) {
        if ($linked.ContainsKey($name)) {
            if ($linked[$name].ToLowerInvariant().StartsWith($hubRgPrefix)) {
                throw "Your virtual network is linked to the hub-internal DNS zone $name in $ResourceGroupName. Remove that link; hub-internal zones must stay linked only to the hub network."
            }
            [pscustomobject]@{ Name = $name; Id = $linked[$name]; Action = 'Reuse' }
        }
        elseif ($inGroup.ContainsKey($name)) {
            if ((Get-Value $inGroup[$name] 'tags.ftk-tool' '') -eq 'FinOps hubs') {
                throw "Zone $name in resource group $DnsResourceGroup belongs to a FinOps hub's internal network. Use the resource group that holds your own private DNS zones."
            }
            [pscustomobject]@{ Name = $name; Id = $inGroup[$name].id; Action = 'Link' }
        }
        else {
            [pscustomobject]@{ Name = $name; Id = "/subscriptions/$DnsSubscription/resourceGroups/$DnsResourceGroup/providers/Microsoft.Network/privateDnsZones/$name"; Action = 'Create' }
        }
    }
}

function Set-HubPrivateEndpoints($Hub, $VirtualNetwork, [string] $SubnetId, [string] $VnetSubscription, [string] $EndpointResourceGroup,
    [string] $DnsSubscription, [string] $DnsResourceGroup, [hashtable] $ResourceTags) {
    $zones = @{
        blob   = 'privatelink.blob.core.windows.net'
        dfs    = 'privatelink.dfs.core.windows.net'
        vault  = 'privatelink.vaultcore.azure.net'
        adf    = 'privatelink.datafactory.azure.net'
        portal = 'privatelink.adf.azure.com'
    }
    $definitions = [System.Collections.Generic.List[object]]::new()
    $add = {
        param([string] $ResourceName, [string] $ResourceId, [string] $GroupId, [string[]] $ZoneNames)
        $peName = "pe-$ResourceName-$($GroupId.ToLowerInvariant())"
        if ($peName.Length -gt 60) { $peName = $peName.Substring(0, 60) }
        $definitions.Add([pscustomobject]@{ Name = $peName; ResourceId = $ResourceId; GroupId = $GroupId; Zones = $ZoneNames })
    }
    & $add $Hub.StorageName $Hub.StorageId 'blob' @($zones.blob)
    & $add $Hub.StorageName $Hub.StorageId 'dfs' @($zones.dfs)
    foreach ($vault in @(Get-ArmList "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.KeyVault/vaults?api-version=2023-07-01")) {
        & $add $vault.name $vault.id 'vault' @($zones.vault)
    }
    & $add $Hub.DataFactoryName $Hub.DataFactoryId 'dataFactory' @($zones.adf)
    & $add $Hub.DataFactoryName $Hub.DataFactoryId 'portal' @($zones.portal)

    $zoneIds = @{}
    if (-not $SkipPrivateDnsZones) {
        $requiredZones = @($definitions | ForEach-Object { $_.Zones } | Sort-Object -Unique)
        $dnsPlan = @(Get-PrivateDnsZonePlan -ZoneNames $requiredZones -VirtualNetworkId $VirtualNetwork.id -DnsSubscription $DnsSubscription -DnsResourceGroup $DnsResourceGroup)
        foreach ($zone in $dnsPlan) {
            $zoneIds[$zone.Name] = $zone.Id
            if ($zone.Action -eq 'Reuse') { Write-Info "Reusing private DNS zone already linked to the virtual network: $($zone.Id)" }
        }
        $toLink = @($dnsPlan | Where-Object Action -ne 'Reuse')
        if ($toLink.Count -gt 0) {
            $toCreate = @($toLink | Where-Object Action -eq 'Create' | ForEach-Object Name)
            # Unique per virtual network: same-named networks in other subscriptions can share central zones.
            $linkName = "$($VirtualNetwork.name)-$((New-DeterministicGuid $VirtualNetwork.id).Substring(0, 8))"
            Write-Info "Private DNS zones in $DnsResourceGroup (subscription $DnsSubscription) - create: $($toCreate.Count), link to $($VirtualNetwork.name): $($toLink.Count)"
            $dnsTemplate = ConvertTo-Minified (Get-Content -Path (Join-Path $PSScriptRoot 'modules/private-dns-zones.json') -Raw)
            Invoke-GroupDeployment -Subscription $DnsSubscription -ResourceGroup $DnsResourceGroup -NamePrefix 'finopshub-dns' -TemplateJson $dnsTemplate -MaxAttempts 3 -TimeoutMinutes 30 -Parameters @{
                zonesToCreate    = $toCreate
                zonesToLink      = @($toLink | ForEach-Object Name)
                virtualNetworkId = $VirtualNetwork.id
                linkName         = $linkName
                tags             = $ResourceTags
            } | Out-Null
        }

        # There is a single Data Factory Studio (portal) endpoint for all factories: one portal private endpoint per
        # DNS zone. Keep ours if it exists, otherwise reuse a portal record that another private endpoint already owns.
        $portalDefinition = $definitions | Where-Object { $_.GroupId -eq 'portal' } | Select-Object -First 1
        $ourPortal = Invoke-Arm -Path "/subscriptions/$VnetSubscription/resourceGroups/$EndpointResourceGroup/providers/Microsoft.Network/privateEndpoints/$($portalDefinition.Name)?api-version=2024-05-01" -AllowNotFound
        $portalRecord = Invoke-Arm -Path "$($zoneIds[$zones.portal])/A/portal?api-version=2024-06-01" -AllowNotFound
        if (-not $ourPortal -and $portalRecord) {
            Write-Info "Data Factory Studio already resolves privately through an existing portal record in $($zones.portal); reusing it instead of creating a second portal endpoint."
            $null = $definitions.Remove($portalDefinition)
        }
    }

    $endpoints = @($definitions | ForEach-Object {
            $definition = $_
            [ordered]@{
                name                 = $definition.Name
                privateLinkServiceId = $definition.ResourceId
                groupId              = $definition.GroupId
                privateDnsZoneIds    = @(if ($SkipPrivateDnsZones) { } else { $definition.Zones | ForEach-Object { $zoneIds[$_] } })
            }
        })
    Set-ResourceGroup -Subscription $VnetSubscription -Name $EndpointResourceGroup -RegionName $VirtualNetwork.location -ResourceTags $ResourceTags | Out-Null
    Write-Info "Creating/updating $($endpoints.Count) private endpoints in $EndpointResourceGroup (subnet $PrivateEndpointSubnetName)..."
    $peTemplate = ConvertTo-Minified (Get-Content -Path (Join-Path $PSScriptRoot 'modules/private-endpoints.json') -Raw)
    Invoke-GroupDeployment -Subscription $VnetSubscription -ResourceGroup $EndpointResourceGroup -NamePrefix 'finopshub-pe' -TemplateJson $peTemplate -MaxAttempts 3 -TimeoutMinutes 45 -Parameters @{
        location         = $VirtualNetwork.location
        subnetId         = $SubnetId
        privateEndpoints = $endpoints
        tags             = $ResourceTags
    } | Out-Null

    # Approve any connection that ended up pending (for example when permissions on the target are delegated).
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($definition in $definitions) {
        $peId = "/subscriptions/$VnetSubscription/resourceGroups/$EndpointResourceGroup/providers/Microsoft.Network/privateEndpoints/$($definition.Name)"
        $pe = (Invoke-Arm -Path "$peId`?api-version=2024-05-01").Content
        $connection = @(@(Get-Value $pe 'properties.privateLinkServiceConnections' @()) + @(Get-Value $pe 'properties.manualPrivateLinkServiceConnections' @())) | Select-Object -First 1
        $status = Get-Value $connection 'properties.privateLinkServiceConnectionState.status' 'Unknown'
        if ($status -eq 'Pending') {
            $targetConnections = @(Get-Value (Invoke-Arm -Path "$($definition.ResourceId)/privateEndpointConnections?api-version=$(Get-PrivateLinkApiVersion $definition.ResourceId)").Content 'value' @())
            foreach ($targetConnection in $targetConnections) {
                if ((Get-Value $targetConnection 'properties.privateEndpoint.id' '') -ieq $peId) {
                    $approval = @{ properties = @{ privateLinkServiceConnectionState = @{ status = 'Approved'; description = 'Approved by Deploy-FinOpsHub-V3-Fabric.ps1' } } }
                    Invoke-Arm -Method PUT -Path "$($targetConnection.id)?api-version=$(Get-PrivateLinkApiVersion $definition.ResourceId)" -Body $approval | Out-Null
                    $status = 'Approved'
                }
            }
        }
        $records = [System.Collections.Generic.List[string]]::new()
        $endpointIps = [System.Collections.Generic.List[string]]::new()
        foreach ($nicRef in @(Get-Value $pe 'properties.networkInterfaces' @())) {
            $nic = (Invoke-Arm -Path "$($nicRef.id)?api-version=2024-05-01").Content
            foreach ($ipConfig in @(Get-Value $nic 'properties.ipConfigurations' @())) {
                $ip = Get-Value $ipConfig 'properties.privateIPAddress'
                $endpointIps.Add($ip)
                foreach ($fqdn in @(Get-Value $ipConfig 'properties.privateLinkConnectionProperties.fqdns' @())) { $records.Add("$fqdn=$ip") }
            }
        }
        $dnsIssues = @()
        if (-not $SkipPrivateDnsZones -and $definition.Zones.Count -gt 0) {
            $dnsIssues = @(Get-EndpointDnsIssue -PrivateEndpointId $peId -EndpointIps $endpointIps.ToArray())
            $zoneGroupPath = "$peId/privateDnsZoneGroups/default?api-version=2024-05-01"
            $zoneGroup = Invoke-Arm -Path $zoneGroupPath -AllowNotFound
            if ($zoneGroup -and @($dnsIssues | Where-Object { $_ -like '*no record*' }).Count -gt 0) {
                # Records can disappear when another private endpoint sharing the zone is deleted: re-register ours.
                Write-Info "Re-registering missing DNS records of $($definition.Name)..."
                $configs = @(Get-Value $zoneGroup.Content 'properties.privateDnsZoneConfigs' @() | ForEach-Object { @{ name = $_.name; properties = @{ privateDnsZoneId = $_.properties.privateDnsZoneId } } })
                Wait-ArmAsyncOperation (Invoke-Arm -Method DELETE -Path $zoneGroupPath -OkStatus 200, 202, 204)
                Wait-ArmAsyncOperation (Invoke-Arm -Method PUT -Path $zoneGroupPath -Body @{ properties = @{ privateDnsZoneConfigs = $configs } } -OkStatus 200, 201)
                $dnsIssues = @(Get-EndpointDnsIssue -PrivateEndpointId $peId -EndpointIps $endpointIps.ToArray())
            }
        }
        $results.Add([pscustomobject]@{ Name = $definition.Name; GroupId = $definition.GroupId; Status = $status; Records = $records.ToArray(); DnsIssues = $dnsIssues })
        if ($status -ne 'Approved') { Write-Warn "Private endpoint $($definition.Name) connection status is '$status'." }
        foreach ($issue in $dnsIssues) { Write-Warn "Private endpoint $($definition.Name): DNS record does not point to the endpoint ($issue)." }
    }
    return $results.ToArray()
}

function Get-EndpointDnsIssue([string] $PrivateEndpointId, [string[]] $EndpointIps) {
    $zoneGroup = Invoke-Arm -Path "$PrivateEndpointId/privateDnsZoneGroups/default?api-version=2024-05-01" -AllowNotFound
    if (-not $zoneGroup) { return 'DNS zone group missing' }
    foreach ($config in @(Get-Value $zoneGroup.Content 'properties.privateDnsZoneConfigs' @())) {
        $zoneId = Get-Value $config 'properties.privateDnsZoneId'
        foreach ($recordSet in @(Get-Value $config 'properties.recordSets' @() | Where-Object { (Get-Value $_ 'recordType') -eq 'A' })) {
            $record = Invoke-Arm -Path "$zoneId/A/$($recordSet.recordSetName)?api-version=2024-06-01" -AllowNotFound
            $zoneIpList = @(Get-Value $record 'Content.properties.aRecords' @() | ForEach-Object { Get-Value $_ 'ipv4Address' })
            if (@($zoneIpList | Where-Object { $EndpointIps -contains $_ }).Count -eq 0) {
                "$($recordSet.fqdn) -> $(if ($zoneIpList) { $zoneIpList -join ',' } else { 'no record' })"
            }
        }
    }
}

function Wait-ArmAsyncOperation($Response, [int] $TimeoutMinutes = 10) {
    if (-not $Response) { return }
    $url = @($Response.Headers['Azure-AsyncOperation'])[0]
    if (-not $url) { return }
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        Start-Sleep -Seconds 5
        $state = Get-Value (Invoke-Arm -Path $url).Content 'status' 'InProgress'
    } while ($state -notin 'Succeeded', 'Failed', 'Canceled' -and (Get-Date) -lt $deadline)
    if ($state -ne 'Succeeded') { throw "Asynchronous operation ended with status '$state'." }
}

function Get-PrivateLinkApiVersion([string] $ResourceId) {
    switch -Regex ($ResourceId) {
        'Microsoft.Storage/' { return '2023-05-01' }
        'Microsoft.KeyVault/' { return '2023-07-01' }
        'Microsoft.DataFactory/' { return '2018-06-01' }
        default { return '2023-05-01' }
    }
}

function Sync-ManagedPrivateEndpoints($Hub) {
    <# Data Factory caches the state of its managed private endpoints and can keep reporting 'Pending' long after the
       target approved the connection, so the target resource is used as the source of truth (and pending ones are approved). #>
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($endpoint in @(Get-ArmList "$($Hub.DataFactoryId)/managedVirtualNetworks/default/managedPrivateEndpoints?api-version=2018-06-01")) {
        $targetId = Get-Value $endpoint 'properties.privateLinkResourceId' ''
        $endpointId = Get-Value $endpoint 'properties.resourceId' ''
        $factoryStatus = Get-Value $endpoint 'properties.connectionState.status' 'Unknown'
        $status = $factoryStatus
        if ($targetId -and $endpointId) {
            try {
                $apiVersion = Get-PrivateLinkApiVersion $targetId
                $connection = @(Get-ArmList "$targetId/privateEndpointConnections?api-version=$apiVersion") |
                    Where-Object { (Get-Value $_ 'properties.privateEndpoint.id' '') -ieq $endpointId } | Select-Object -First 1
                if ($connection) {
                    $status = Get-Value $connection 'properties.privateLinkServiceConnectionState.status' $factoryStatus
                    if ($status -eq 'Pending') {
                        $approval = @{ properties = @{ privateLinkServiceConnectionState = @{ status = 'Approved'; description = 'Approved by Deploy-FinOpsHub-V3-Fabric.ps1' } } }
                        Invoke-Arm -Method PUT -Path "$($connection.id)?api-version=$apiVersion" -Body $approval -RetryOnConflict | Out-Null
                        $status = 'Approved'
                        Write-Info "Approved Data Factory managed private endpoint '$($endpoint.name)' on $(($targetId -split '/')[-1])."
                    }
                }
            }
            catch { Write-Info "Could not read the private endpoint connections of $(($targetId -split '/')[-1]): $($_.Exception.Message)" }
        }
        $results.Add([pscustomobject]@{ Name = $endpoint.name; Target = ($targetId -split '/')[-1]; FactoryStatus = $factoryStatus; Status = $status })
    }
    return $results.ToArray()
}

function Set-HubCostExport([string] $Scope, [string] $Name, [string] $Recurrence, [string] $StorageId, [string] $DataVersion) {
    $path = "$Scope/providers/Microsoft.CostManagement/exports/$Name`?api-version=$script:ExportsApiVersion"
    $existing = Invoke-Arm -Path $path -AllowNotFound
    $from = [DateTime]::UtcNow.Date.AddDays(1)
    $body = [ordered]@{
        identity   = @{ type = 'SystemAssigned' }
        location   = 'global'
        properties = [ordered]@{
            exportDescription     = "FOCUS cost export for FinOps hub storage $($StorageId.Split('/')[-1]) (Deploy-FinOpsHub-V3-Fabric.ps1)"
            schedule              = [ordered]@{
                status           = 'Active'
                recurrence       = $Recurrence
                recurrencePeriod = [ordered]@{ from = $from.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"); to = $from.AddYears(5).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }
            }
            format                = 'Parquet'
            compressionMode       = 'Snappy'
            partitionData         = $true
            dataOverwriteBehavior = 'CreateNewReport'
            deliveryInfo          = @{ destination = [ordered]@{ type = 'AzureBlob'; resourceId = $StorageId; container = 'msexports'; rootFolderPath = ($Scope.Trim('/') -replace '^providers/Microsoft.Billing/', '') } }
            definition            = [ordered]@{
                type      = 'FocusCost'
                timeframe = $(if ($Recurrence -eq 'Monthly') { 'TheLastMonth' } else { 'MonthToDate' })
                dataSet   = [ordered]@{ granularity = 'Daily'; configuration = @{ dataVersion = $DataVersion } }
            }
        }
    }
    if ($existing) { $body['eTag'] = Get-Value $existing.Content 'eTag' }
    Invoke-Arm -Method PUT -Path $path -Body $body -OkStatus 200, 201 | Out-Null
    return "$Scope/providers/Microsoft.CostManagement/exports/$Name"
}

function Invoke-HubCostExportRun([string] $ExportId, [Nullable[DateTime]] $MonthStart) {
    $body = $null
    if ($MonthStart) {
        $start = [DateTime]$MonthStart
        $end = $start.AddMonths(1).AddSeconds(-1)
        $yesterday = [DateTime]::UtcNow.Date.AddSeconds(-1)
        if ($end -gt $yesterday) { $end = $yesterday }
        $body = @{ timePeriod = @{ from = $start.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"); to = $end.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") } }
    }
    Invoke-Arm -Method POST -Path "$ExportId/run?api-version=$script:ExportsApiVersion" -Body $body -OkStatus 200, 202, 204 -MaxAttempts 10 | Out-Null
}

function Set-AllCostExports($Hub, [string[]] $Scopes, [bool] $GrantReader) {
    $results = [System.Collections.Generic.List[object]]::new()
    $currentMonth = [DateTime]::new([DateTime]::UtcNow.Year, [DateTime]::UtcNow.Month, 1, 0, 0, 0, [DateTimeKind]::Utc)
    foreach ($scope in $Scopes) {
        $result = [ordered]@{ Scope = $scope; Exports = @(); Backfilled = 0; DataVersion = $FocusDatasetVersion; Error = $null }
        try {
            if ($scope -match '^/subscriptions/([0-9a-fA-F-]{36})') {
                Register-Providers -Subscription $Matches[1] -Namespaces @('Microsoft.CostManagementExports')
            }
            $version = $FocusDatasetVersion
            $daily = $null
            try { $daily = Set-HubCostExport -Scope $scope -Name "ftk-$($Hub.StorageName)-daily" -Recurrence 'Daily' -StorageId $Hub.StorageId -DataVersion $version }
            catch {
                if ($version -ne '1.0r2' -and ([int]$_.Exception.Data['StatusCode']) -eq 400) {
                    Write-Warn "FOCUS $version was rejected for $scope ($($_.Exception.Message)); falling back to 1.0r2."
                    $version = '1.0r2'
                    $daily = Set-HubCostExport -Scope $scope -Name "ftk-$($Hub.StorageName)-daily" -Recurrence 'Daily' -StorageId $Hub.StorageId -DataVersion $version
                }
                else { throw }
            }
            $monthly = Set-HubCostExport -Scope $scope -Name "ftk-$($Hub.StorageName)-monthly" -Recurrence 'Monthly' -StorageId $Hub.StorageId -DataVersion $version
            $result.DataVersion = $version
            $result.Exports = @($daily, $monthly)
            Write-Ok "Exports ready for $scope (FOCUS $version)"

            try { Invoke-HubCostExportRun -ExportId $daily; Write-Info 'Started month-to-date export run.' }
            catch { Write-Warn "Could not start the month-to-date run for ${scope}: $($_.Exception.Message)" }
            for ($i = 1; $i -le $BackfillMonths; $i++) {
                $month = $currentMonth.AddMonths(-$i)
                try { Invoke-HubCostExportRun -ExportId $monthly -MonthStart $month; $result['Backfilled'] = $result['Backfilled'] + 1 }
                catch { Write-Warn "Backfill $($month.ToString('yyyy-MM')) failed for ${scope}: $($_.Exception.Message)" }
            }
            if ($BackfillMonths -gt 0) { Write-Info "Queued $($result.Backfilled) of $BackfillMonths backfill month(s)." }

            if ($GrantReader -and $Hub.PrincipalId) {
                $roleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
                $assignmentName = New-DeterministicGuid "$scope|$roleId|$($Hub.PrincipalId)"
                $body = @{ properties = @{ roleDefinitionId = "$scope/providers/Microsoft.Authorization/roleDefinitions/$roleId"; principalId = $Hub.PrincipalId; principalType = 'ServicePrincipal' } }
                try {
                    Invoke-Arm -Method PUT -Path "$scope/providers/Microsoft.Authorization/roleAssignments/$assignmentName`?api-version=2022-04-01" -Body $body -OkStatus 200, 201 | Out-Null
                    Write-Info 'Granted Reader to the hub Data Factory identity (recommendations).'
                }
                catch {
                    if ($_.Exception.Message -notmatch 'RoleAssignmentExists') { Write-Warn "Could not grant Reader on ${scope}: $($_.Exception.Message)" }
                }
            }
        }
        catch {
            $result.Error = $_.Exception.Message
            Write-Warn "Exports failed for ${scope}: $($_.Exception.Message)"
        }
        $results.Add([pscustomobject]$result)
    }
    return $results.ToArray()
}

function Get-DefaultExportScopes {
    $subscriptions = (Invoke-AzCli -Arguments @('account', 'list', '--all', '--output', 'json')).StdOut | ConvertFrom-Json
    return @($subscriptions | Where-Object { $_.tenantId -eq $script:TenantId -and $_.state -eq 'Enabled' } | ForEach-Object { "/subscriptions/$($_.id)" } | Sort-Object -Unique)
}
#endregion

#region Guided setup
function Test-CanPrompt {
    return [Environment]::UserInteractive -and -not [Console]::IsInputRedirected -and
    @([Environment]::GetCommandLineArgs() | Where-Object { $_ -match '^-noni' }).Count -eq 0
}

function Read-Selection([string] $Title, [object[]] $Items, [string[]] $Labels) {
    # A number picks an item (Enter = 1); any other text filters the list.
    if ($Items.Count -eq 0) { throw "Nothing to choose from: $Title" }
    $filter = ''
    while ($true) {
        $indexes = @(0..($Items.Count - 1) | Where-Object { -not $filter -or $Labels[$_].IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
        Write-Host ''
        Write-Host "  $Title" -ForegroundColor Cyan
        if ($indexes.Count -eq 0) {
            Write-Host "    Nothing matches '$filter'." -ForegroundColor Yellow
            $filter = ''
            continue
        }
        $shown = [Math]::Min($indexes.Count, 30)
        for ($n = 0; $n -lt $shown; $n++) { Write-Host ('    [{0,2}] {1}' -f ($n + 1), $Labels[$indexes[$n]]) }
        if ($indexes.Count -gt $shown) { Write-Host "    ... $($indexes.Count - $shown) more - type part of a name to filter" -ForegroundColor DarkGray }
        $answer = ([string](Read-Host '  Number (Enter = 1) or text to filter')).Trim()
        if (-not $answer) { return $Items[$indexes[0]] }
        $number = 0
        if ([int]::TryParse($answer, [ref]$number)) {
            if ($number -ge 1 -and $number -le $shown) { return $Items[$indexes[$number - 1]] }
            Write-Host "    Enter a number from 1 to $shown." -ForegroundColor Yellow
            continue
        }
        $filter = $answer
    }
}

function Read-Text([string] $Prompt, [string] $Default, [scriptblock] $Validate) {
    # $Validate gets the value and returns an error message, or nothing when the value is valid.
    while ($true) {
        $answer = ([string](Read-Host $(if ($Default) { "  $Prompt [$Default]" } else { "  $Prompt" }))).Trim()
        if (-not $answer) { $answer = $Default }
        if (-not $answer) { Write-Host '    A value is required.' -ForegroundColor Yellow; continue }
        $problem = if ($Validate) { & $Validate $answer } else { $null }
        if (-not $problem) { return $answer }
        Write-Host "    $problem" -ForegroundColor Yellow
    }
}

function Read-YesNo([string] $Prompt) {
    while ($true) {
        $answer = ([string](Read-Host "  $Prompt [Y/n]")).Trim()
        if ($answer -match '^(y|yes)?$') { return $true }
        if ($answer -match '^(n|no)$') { return $false }
    }
}

function Invoke-GuidedSetup([string] $CurrentSubscriptionId) {
    <# Asks only for values that were not passed as parameters and returns them keyed by parameter name.
       The pre-flight checks validate every answer again. The Fabric SKU is asked for by the pre-flight. #>
    $answers = @{}
    Write-Host ''
    Write-Host '  Guided setup' -ForegroundColor Cyan
    Write-Info "Tenant $($script:TenantId). For another tenant, press Ctrl+C and run 'az login --tenant <tenant-id>' first."
    Write-Info 'Lists: enter a number (Enter = 1) or type text to filter. Questions: press Enter to accept the [default].'

    $subscriptions = @(Get-ArmList '/subscriptions?api-version=2022-12-01' | Where-Object { $_.state -eq 'Enabled' -and $_.tenantId -eq $script:TenantId } |
        Sort-Object @{ Expression = { $_.subscriptionId -ne $CurrentSubscriptionId } }, displayName)
    if ($subscriptions.Count -eq 0) { throw "No enabled subscription is visible to you in tenant $($script:TenantId)." }
    $subscriptionNames = @{}
    foreach ($subscription in $subscriptions) { $subscriptionNames[$subscription.subscriptionId.ToLowerInvariant()] = $subscription.displayName }
    $subscriptionLabels = @($subscriptions | ForEach-Object { "$($_.displayName)  ($($_.subscriptionId))" })
    $nameOf = { param($Id) if ($subscriptionNames.ContainsKey($Id.ToLowerInvariant())) { $subscriptionNames[$Id.ToLowerInvariant()] } else { $Id } }

    $hubSubscription = $SubscriptionId
    if (-not $hubSubscription) {
        $hubSubscription = (Read-Selection -Title 'Subscription for the FinOps hub and the Fabric capacity' -Items $subscriptions -Labels $subscriptionLabels).subscriptionId
        $answers['SubscriptionId'] = $hubSubscription
    }

    $hubGroup = $ResourceGroupName
    if (-not $hubGroup) {
        Write-Host ''
        $hubGroup = Read-Text -Prompt 'Resource group for the FinOps hub (created if it does not exist)' -Default 'rg-finops-hub' -Validate {
            param($value)
            if ($value -notmatch '^[-\w\.\(\)]{1,90}$' -or $value.EndsWith('.')) { 'Use up to 90 letters, digits and - _ . ( ), not ending with a period.' }
        }
        $existingGroup = Invoke-Arm -Path "/subscriptions/$hubSubscription/resourcegroups/$hubGroup`?api-version=2021-04-01" -AllowNotFound
        Write-Info $(if ($existingGroup) { "Resource group $hubGroup exists ($($existingGroup.Content.location)) and will be used." } else { "Resource group $hubGroup will be created." })
        $answers['ResourceGroupName'] = $hubGroup
    }

    $vnetName = $VirtualNetworkName
    $vnetGroup = $VirtualNetworkResourceGroupName
    $vnetSubscription = $VirtualNetworkSubscriptionId
    if (-not ($vnetName -and $vnetGroup)) {
        $query = "resources | where type =~ 'microsoft.network/virtualnetworks' | where tostring(tags['ftk-tool']) != 'FinOps hubs' | project id, name, subscriptionId, location, prefixes = properties.addressSpace.addressPrefixes"
        $vnets = @(Invoke-ResourceGraph $query | Where-Object {
                (-not $vnetName -or $_.name -ieq $vnetName) -and (-not $vnetGroup -or $_.id.Split('/')[4] -ieq $vnetGroup) -and (-not $vnetSubscription -or $_.subscriptionId -ieq $vnetSubscription)
            } | Sort-Object @{ Expression = { $_.subscriptionId -ne $hubSubscription } }, name)
        if ($vnets.Count -eq 0) { throw 'No matching virtual network was found. Create the virtual network and a subnet for the private endpoints first (Reader access is enough to list it).' }
        $vnetLabels = @($vnets | ForEach-Object { '{0}  |  rg {1}  |  {2}  |  {3}  |  {4}' -f $_.name, $_.id.Split('/')[4], $_.location, (@($_.prefixes) -join ', '), (& $nameOf $_.subscriptionId) })
        $vnetChoice = Read-Selection -Title 'Existing virtual network for the private endpoints' -Items $vnets -Labels $vnetLabels
        $vnetName = $vnetChoice.name
        $vnetGroup = $vnetChoice.id.Split('/')[4]
        $vnetSubscription = $vnetChoice.subscriptionId
        $answers['VirtualNetworkName'] = $vnetName
        $answers['VirtualNetworkResourceGroupName'] = $vnetGroup
        $answers['VirtualNetworkSubscriptionId'] = $vnetSubscription
    }
    if (-not $vnetSubscription) { $vnetSubscription = $hubSubscription }
    $vnetResponse = Invoke-Arm -Path "/subscriptions/$vnetSubscription/resourceGroups/$vnetGroup/providers/Microsoft.Network/virtualNetworks/$vnetName`?api-version=2024-05-01" -AllowNotFound
    if (-not $vnetResponse) { throw "Virtual network $vnetName was not found in resource group $vnetGroup (subscription $vnetSubscription)." }
    $vnet = $vnetResponse.Content

    if (-not $PrivateEndpointSubnetName) {
        $reserved = 'GatewaySubnet', 'AzureFirewallSubnet', 'AzureFirewallManagementSubnet', 'AzureBastionSubnet', 'RouteServerSubnet'
        $subnets = @(Get-Value $vnet 'properties.subnets' @() | Where-Object { $_.name -notin $reserved -and @(Get-Value $_ 'properties.delegations' @()).Count -eq 0 } | ForEach-Object {
                $prefix = [string](Get-Value $_ 'properties.addressPrefix' '')
                if (-not $prefix) { $prefix = [string](@(Get-Value $_ 'properties.addressPrefixes' @()) | Select-Object -First 1) }
                $free = if ($prefix -match '/(\d+)$') { [Math]::Pow(2, 32 - [int]$Matches[1]) - 5 - @(Get-Value $_ 'properties.ipConfigurations' @()).Count } else { 0 }
                [pscustomobject]@{ Name = $_.name; Prefix = $prefix; Free = $free }
            } | Sort-Object @{ Expression = { $_.Name -notmatch 'private|endpoint|(^|[-_])pe([-_]|$)' } }, @{ Expression = 'Free'; Descending = $true })
        if ($subnets.Count -eq 0) { throw "Virtual network $vnetName has no subnet that can host private endpoints (one without delegation that is not a gateway, firewall, Bastion or Route Server subnet). Add one (a /28 is enough) and re-run." }
        $subnetLabels = @($subnets | ForEach-Object { '{0,-32} {1,-18} ~{2} free IPs{3}' -f $_.Name, $_.Prefix, $_.Free, $(if ($_.Free -lt 8) { '  (too small)' } else { '' }) })
        $answers['PrivateEndpointSubnetName'] = (Read-Selection -Title "Subnet in $vnetName for the private endpoints (about 5 IP addresses are used)" -Items $subnets -Labels $subnetLabels).Name
    }

    $vnetRegion = ([string]$vnet.location).ToLowerInvariant().Replace(' ', '')
    $hubRegion = $Location.ToLowerInvariant().Replace(' ', '')
    if (-not $hubRegion) {
        # The hub and the Fabric capacity share one region, which must offer Fabric and have capacity quota.
        $capacityName = if ($FabricCapacityName) { $FabricCapacityName.ToLowerInvariant() } else { Get-DefaultFabricCapacityName -Hub (Get-HubNameValue) -Subscription $hubSubscription -Group $hubGroup }
        $capacityGroup = if ($FabricCapacityResourceGroupName) { $FabricCapacityResourceGroupName } else { $hubGroup }
        $existingCapacity = Get-Value (Invoke-Arm -Path "/subscriptions/$hubSubscription/resourceGroups/$capacityGroup/providers/Microsoft.Fabric/capacities/$capacityName`?api-version=$script:FabricArmApiVersion" -AllowNotFound) 'Content'
        if ($existingCapacity) {
            $hubRegion = ([string]$existingCapacity.location).ToLowerInvariant().Replace(' ', '')
            Write-Host ''
            Write-Info "Fabric capacity $capacityName already exists in $hubRegion; the hub uses the same region."
        }
        else {
            $locations = @(Get-ArmList "/subscriptions/$hubSubscription/locations?api-version=2022-12-01" | Where-Object { (Get-Value $_ 'metadata.regionType' '') -eq 'Physical' })
            $regions = @($locations | ForEach-Object name)
            Register-Providers -Subscription $hubSubscription -Namespaces @('Microsoft.Fabric')
            Write-Host ''
            Write-Info 'The hub and its Fabric capacity must be in the same region, and the subscription needs Fabric capacity quota there.'
            $suggestion = $vnetRegion
            if ((Get-HubRegionProblem -Subscription $hubSubscription -RegionName $vnetRegion) -or (Get-FabricRegionProblem -Subscription $hubSubscription -RegionName $vnetRegion)) {
                Write-Info "The hub cannot use $vnetRegion (no Fabric capacity quota or a missing service there); looking for the nearest regions that work..."
                # Rank the Fabric regions by great-circle distance from the virtual network, then check them nearest first.
                $coordinates = @{}
                foreach ($region in $locations) {
                    $latitude = 0.0
                    $longitude = 0.0
                    $style = [Globalization.NumberStyles]::Float
                    $culture = [Globalization.CultureInfo]::InvariantCulture
                    if ([double]::TryParse([string](Get-Value $region 'metadata.latitude' ''), $style, $culture, [ref]$latitude) -and
                        [double]::TryParse([string](Get-Value $region 'metadata.longitude' ''), $style, $culture, [ref]$longitude)) { $coordinates[[string]$region.name] = @($latitude, $longitude) }
                }
                $distance = {
                    param([string] $Name)
                    $from = $coordinates[$vnetRegion]
                    $to = $coordinates[$Name]
                    if (-not $from -or -not $to) { return [double]::MaxValue }
                    $radians = [Math]::PI / 180
                    $h = [Math]::Pow([Math]::Sin(($to[0] - $from[0]) * $radians / 2), 2) +
                    [Math]::Cos($from[0] * $radians) * [Math]::Cos($to[0] * $radians) * [Math]::Pow([Math]::Sin(($to[1] - $from[1]) * $radians / 2), 2)
                    return 12742 * [Math]::Asin([Math]::Sqrt($h))
                }
                $null = Get-FabricRegionSkus -Subscription $hubSubscription -RegionName ''
                $fabricRegions = @($script:FabricSkuCatalog | Where-Object Sku -eq 'F2' | ForEach-Object Region | Sort-Object -Unique | Where-Object { $regions -contains $_ } | Sort-Object { & $distance $_ })
                $candidates = @(Get-FabricRegionsWithQuota -Subscription $hubSubscription -Regions $fabricRegions -Limit 6)
                if ($candidates.Count -eq 0) { throw 'The subscription has no Microsoft Fabric capacity quota in any region where the hub can be deployed. Request quota (Azure portal > Quotas > Microsoft Fabric) or use another subscription. Nothing was deployed.' }
                $suggestion = $candidates[0]
                Write-Info "Nearest regions with Fabric capacity quota: $($candidates -join ', ')"
            }
            $hubRegion = (Read-Text -Prompt "Azure region for the hub and the Fabric capacity (the virtual network is in $vnetRegion)" -Default $suggestion -Validate {
                    param($value)
                    $name = $value.ToLowerInvariant().Replace(' ', '')
                    if ($regions.Count -gt 0 -and $regions -notcontains $name) { return "Unknown region '$value' (example: swedencentral)." }
                    $hubProblem = Get-HubRegionProblem -Subscription $hubSubscription -RegionName $name
                    if ($hubProblem) { return $hubProblem }
                    Get-FabricRegionProblem -Subscription $hubSubscription -RegionName $name
                }).ToLowerInvariant().Replace(' ', '')
        }
        $answers['Location'] = $hubRegion
    }

    if (-not $SkipPrivateDnsZones -and -not $PrivateDnsZoneResourceGroupName) {
        $needed = @(Get-HubDnsZoneNames)
        $query = "resources | where type =~ 'microsoft.network/privatednszones' and name startswith 'privatelink.' | where tostring(tags['ftk-tool']) != 'FinOps hubs' | project id, name"
        $groups = @(Invoke-ResourceGraph $query | Group-Object { ($_.id -split '/providers/')[0].ToLowerInvariant() } | ForEach-Object {
                $parts = $_.Group[0].id.Split('/')
                $names = @($_.Group | ForEach-Object { ([string]$_.name).ToLowerInvariant() })
                [pscustomobject]@{ SubscriptionId = $parts[2]; ResourceGroup = $parts[4]; Matching = @($needed | Where-Object { $names -contains $_ }).Count }
            } | Where-Object Matching -gt 0 | Sort-Object Matching -Descending)
        $options = [System.Collections.Generic.List[object]]::new()
        foreach ($group in $groups) {
            $options.Add([pscustomobject]@{ Mode = 'Group'; SubscriptionId = $group.SubscriptionId; ResourceGroup = $group.ResourceGroup
                    Label = "Existing zones in $($group.ResourceGroup) ($(& $nameOf $group.SubscriptionId)): $($group.Matching) of $($needed.Count) found, missing ones created there" })
        }
        if (-not @($groups | Where-Object { $_.SubscriptionId -ieq $vnetSubscription -and $_.ResourceGroup -ieq $vnetGroup }).Count) {
            $options.Add([pscustomobject]@{ Mode = 'Group'; SubscriptionId = $vnetSubscription; ResourceGroup = $vnetGroup; Label = "Create the zones in the virtual network resource group ($vnetGroup)" })
        }
        $options.Add([pscustomobject]@{ Mode = 'Other'; Label = 'Another subscription and resource group (you enter it)' })
        $options.Add([pscustomobject]@{ Mode = 'Skip'; Label = 'Skip: DNS is managed by Azure Policy or a DNS team (the script prints the records to create)' })
        Write-Info "Zones already linked to $vnetName are always reused, wherever they are."
        $choice = Read-Selection -Title "Private DNS zones for the private endpoints ($($needed.Count) zones needed, plus Key Vault's when the hub has one)" -Items $options.ToArray() -Labels @($options | ForEach-Object Label)
        switch ($choice.Mode) {
            'Skip' { $answers['SkipPrivateDnsZones'] = $true }
            'Other' {
                $dnsSubscription = (Read-Selection -Title 'Subscription that holds (or will hold) the private DNS zones' -Items $subscriptions -Labels $subscriptionLabels).subscriptionId
                Write-Host ''
                $answers['PrivateDnsZoneResourceGroupName'] = Read-Text -Prompt 'Resource group for the private DNS zones (must exist)' -Validate {
                    param($value)
                    if ($value -notmatch '^[-\w\.\(\)]{1,90}$') { return 'That is not a valid resource group name.' }
                    try { $found = Invoke-Arm -Path "/subscriptions/$dnsSubscription/resourcegroups/$value`?api-version=2021-04-01" -AllowNotFound }
                    catch { return "Cannot read resource group '$value': $($_.Exception.Message)" }
                    if (-not $found) { return "Resource group '$value' was not found in that subscription." }
                }
                $answers['PrivateDnsZoneSubscriptionId'] = $dnsSubscription
            }
            default {
                $answers['PrivateDnsZoneSubscriptionId'] = $choice.SubscriptionId
                $answers['PrivateDnsZoneResourceGroupName'] = $choice.ResourceGroup
            }
        }
    }
    return $answers
}
#endregion

#region Main
$logDirectory = Join-Path $PSScriptRoot 'logs'
New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
$runStamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
Start-Transcript -Path (Join-Path $logDirectory "Deploy-FinOpsHub-V3-Fabric-$runStamp.log") -UseMinimalHeader | Out-Null
$overallStart = Get-Date
try {
    Write-Banner

    # --- 1. Pre-flight -------------------------------------------------------------------------------------
    Write-Step 'Pre-flight checks'
    $missing = @('SubscriptionId', 'ResourceGroupName', 'VirtualNetworkName', 'VirtualNetworkResourceGroupName', 'PrivateEndpointSubnetName' | Where-Object { -not (Get-Variable -Name $_ -ValueOnly) })
    $guided = $missing.Count -gt 0
    if ($guided -and -not (Test-CanPrompt)) {
        throw "Missing parameter(s): -$($missing -join ', -'). Pass them (see Get-Help $PSCommandPath -Full) or run the script in an interactive PowerShell session for guided setup."
    }
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI (az) is not installed. See https://aka.ms/azcli.' }
    $ingestionScript = Join-Path $FabricSetupScriptFolder 'finops-hub-fabric-setup-Ingestion.kql'
    $hubScript = Join-Path $FabricSetupScriptFolder 'finops-hub-fabric-setup-Hub.kql'
    foreach ($file in @($TemplateFile, $TemplateParameterFile, (Join-Path $PSScriptRoot 'modules/private-endpoints.json'), (Join-Path $PSScriptRoot 'modules/private-dns-zones.json'), $ingestionScript, $hubScript)) {
        if (-not (Test-Path $file)) { throw "Required file not found: $file (the Fabric setup scripts are FinOps toolkit release assets: https://github.com/microsoft/finops-toolkit/releases)" }
    }
    if (-not $SkipDashboard -and -not (Test-Path $DashboardFile)) { throw "Dashboard file not found: $DashboardFile" }

    $account = Invoke-AzCli -Arguments @('account', 'show', '--output', 'json') -AllowFailure
    if ($account.ExitCode -ne 0) {
        Write-Info 'Not signed in to Azure CLI. Starting az login...'
        & az login --output none
        if ($LASTEXITCODE -ne 0) { throw 'az login failed.' }
    }
    $cloud = (Invoke-AzCli -Arguments @('cloud', 'show', '--query', 'name', '--output', 'tsv')).StdOut
    if ($cloud -ne 'AzureCloud') { throw "Only the Azure public cloud is supported (current: $cloud)." }
    $signedIn = (Invoke-AzCli -Arguments @('account', 'show', '--output', 'json')).StdOut | ConvertFrom-Json
    $script:TenantId = $signedIn.tenantId

    # Fabric first: without Fabric API access no other step can complete, so fail before asking any question.
    $fabricProblem = Get-FabricAccessProblem -UserName $signedIn.user.name
    if ($fabricProblem) { throw $fabricProblem }
    Write-Ok "Microsoft Fabric API access verified for $($signedIn.user.name)"

    if ($guided) {
        $answers = Invoke-GuidedSetup -CurrentSubscriptionId $signedIn.id
        foreach ($name in $answers.Keys) { Set-Variable -Name $name -Value $answers[$name] }
        Write-Host ''
    }
    Invoke-AzCli -Arguments @('account', 'set', '--subscription', $SubscriptionId) | Out-Null
    $account = (Invoke-AzCli -Arguments @('account', 'show', '--output', 'json')).StdOut | ConvertFrom-Json
    $script:TenantId = $account.tenantId
    if ($account.tenantId -ne $signedIn.tenantId) {
        # The subscription is in another tenant: drop tokens of the first tenant and check Fabric there.
        $script:TokenCache = @{}
        $fabricProblem = Get-FabricAccessProblem -UserName $account.user.name
        if ($fabricProblem) { throw $fabricProblem }
    }
    Write-Ok "Signed in as $($account.user.name) | subscription '$($account.name)' | tenant $($script:TenantId)"

    if (-not $VirtualNetworkSubscriptionId) { $VirtualNetworkSubscriptionId = $SubscriptionId }
    if ($PrivateDnsZoneSubscriptionId -and $PrivateDnsZoneSubscriptionId -ne $VirtualNetworkSubscriptionId -and -not $PrivateDnsZoneResourceGroupName) {
        throw 'Pass -PrivateDnsZoneResourceGroupName together with -PrivateDnsZoneSubscriptionId (the existing resource group that holds your private DNS zones).'
    }
    if (-not $PrivateDnsZoneSubscriptionId) { $PrivateDnsZoneSubscriptionId = $VirtualNetworkSubscriptionId }
    if (-not $PrivateDnsZoneResourceGroupName) { $PrivateDnsZoneResourceGroupName = $VirtualNetworkResourceGroupName }
    if (-not $PrivateEndpointResourceGroupName) {
        $PrivateEndpointResourceGroupName = if ($VirtualNetworkSubscriptionId -eq $SubscriptionId) { $ResourceGroupName } else { $VirtualNetworkResourceGroupName }
    }
    if (-not $SkipPrivateDnsZones -and $PrivateDnsZoneSubscriptionId -eq $SubscriptionId -and $PrivateDnsZoneResourceGroupName -ieq $ResourceGroupName) {
        throw 'PrivateDnsZoneResourceGroupName cannot be the hub resource group: the hub creates its own internal zones with the same names there.'
    }

    $templateValues = Get-EffectiveTemplateParameters
    $hubLocation = [string]$templateValues['location']
    $resourceTags = [hashtable]$templateValues['tags']
    $rawRetentionInDays = [int](Get-Value $templateValues 'dataExplorerRawRetentionInDays' 0)
    Write-Ok "Hub '$($templateValues['hubName'])' in $hubLocation with Microsoft Fabric as the data store"
    $leftoverClusters = @()
    try { $leftoverClusters = @(Get-ArmList "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Kusto/clusters?api-version=2023-08-15") }
    catch { Write-Verbose "No Data Explorer clusters listed (the resource group may not exist yet): $($_.Exception.Message)" }
    foreach ($cluster in $leftoverClusters) {
        Write-Warn "Azure Data Explorer cluster $($cluster.name) is in $ResourceGroupName (for example from version 1). This version switches the hub to Fabric, so the cluster is no longer used; delete it to stop its cost."
    }

    $hubProviders = @('Microsoft.Storage', 'Microsoft.DataFactory', 'Microsoft.EventGrid', 'Microsoft.ManagedIdentity', 'Microsoft.Network', 'Microsoft.ContainerInstance', 'Microsoft.KeyVault', 'Microsoft.CostManagementExports', 'Microsoft.Fabric')
    Register-Providers -Subscription $SubscriptionId -Namespaces $hubProviders
    if ($VirtualNetworkSubscriptionId -ne $SubscriptionId) { Register-Providers -Subscription $VirtualNetworkSubscriptionId -Namespaces @('Microsoft.Network') }
    Write-Ok 'Resource providers registered'
    $hubRegionProblem = Get-HubRegionProblem -Subscription $SubscriptionId -RegionName $hubLocation
    if ($hubRegionProblem) { throw "$hubRegionProblem Use -Location with another region." }

    # Fabric capacity: same region as the hub, SKU offered there, enough quota, valid name, caller is an administrator.
    $capacityGroup = if ($FabricCapacityResourceGroupName) { $FabricCapacityResourceGroupName } else { $ResourceGroupName }
    $FabricCapacityName = if ($FabricCapacityName) { $FabricCapacityName.ToLowerInvariant() } else { Get-DefaultFabricCapacityName -Hub $templateValues['hubName'] -Subscription $SubscriptionId -Group $ResourceGroupName }
    $capacityArmId = "/subscriptions/$SubscriptionId/resourceGroups/$capacityGroup/providers/Microsoft.Fabric/capacities/$FabricCapacityName"
    $existingCapacity = Get-Value (Invoke-Arm -Path "$capacityArmId`?api-version=$script:FabricArmApiVersion" -AllowNotFound) 'Content'
    if ($existingCapacity) {
        $capacityRegion = ([string]$existingCapacity.location).ToLowerInvariant().Replace(' ', '')
        if ($capacityRegion -ne $hubLocation) { throw "Fabric capacity $FabricCapacityName is in $capacityRegion; the hub must be in the same region. Use -Location $capacityRegion or another -FabricCapacityName." }
    }
    $regionSkus = @(Get-FabricRegionSkus -Subscription $SubscriptionId -RegionName $hubLocation)
    if ($regionSkus.Count -eq 0) {
        $withQuota = @(Get-FabricRegionsWithQuota -Subscription $SubscriptionId -Limit 8)
        throw "Microsoft Fabric capacities are not offered in $hubLocation for this subscription. Regions where the hub can be deployed with Fabric quota include: $(if ($withQuota) { $withQuota -join ', ' } else { 'none' }). Use -Location."
    }
    $existingUnits = if ($existingCapacity) { Get-FabricSkuUnits ([string](Get-Value $existingCapacity 'sku.name' 'F2')) } else { 0 }
    $quota = Get-FabricQuota -Subscription $SubscriptionId -RegionName $hubLocation
    $availableUnits = if ($quota) { $quota.Available + $existingUnits } else { $null }
    if ($null -ne $availableUnits -and $availableUnits -lt 2) {
        $withQuota = @(Get-FabricRegionsWithQuota -Subscription $SubscriptionId -Limit 8)
        throw "The subscription has no Fabric capacity quota left in $hubLocation ($($quota.Used) of $($quota.Limit) CU used). Regions where the hub can be deployed with Fabric quota include: $(if ($withQuota) { $withQuota -join ', ' } else { 'none' }). Use -Location, or request quota (Azure portal > Quotas > Microsoft Fabric). Nothing was deployed."
    }
    $fabricPrice = Get-FabricUnitPrice -RegionName $hubLocation
    $currentSku = [string](Get-Value $existingCapacity 'sku.name' '')
    if (-not $FabricCapacitySku) {
        if (Test-CanPrompt) { $FabricCapacitySku = Read-FabricCapacitySku -Skus $regionSkus -Price $fabricPrice -AvailableUnits $availableUnits -CurrentSku $currentSku -RegionName $hubLocation }
        else {
            $FabricCapacitySku = if ($currentSku) { $currentSku } else { 'F2' }
            Write-Warn "No -FabricCapacitySku in a non-interactive session; using $FabricCapacitySku."
        }
    }
    $FabricCapacitySku = $FabricCapacitySku.ToUpperInvariant()
    if ($regionSkus -notcontains $FabricCapacitySku) { throw "Fabric SKU $FabricCapacitySku is not offered in $hubLocation. Offered: $($regionSkus -join ', ')." }
    $capacityUnits = Get-FabricSkuUnits $FabricCapacitySku
    if ($null -ne $availableUnits -and $capacityUnits -gt $availableUnits) {
        throw "Fabric SKU $FabricCapacitySku needs $capacityUnits CU but only $availableUnits CU of quota is available in $hubLocation. Choose a smaller SKU or request quota (Azure portal > Quotas > Microsoft Fabric)."
    }
    if (-not $existingCapacity) {
        $nameCheck = (Invoke-Arm -Method POST -Path "/subscriptions/$SubscriptionId/providers/Microsoft.Fabric/locations/$hubLocation/checkNameAvailability?api-version=$script:FabricArmApiVersion" -Body @{ name = $FabricCapacityName; type = 'Microsoft.Fabric/capacities' }).Content
        if (-not (Get-Value $nameCheck 'nameAvailable' $false)) { throw "Fabric capacity name '$FabricCapacityName' is not available: $(Get-Value $nameCheck 'message' (Get-Value $nameCheck 'reason' ''))" }
    }
    $claims = Get-TokenClaims $script:ArmResource
    $caller = if (Get-Value $claims 'scp') { [string](Get-Value $claims 'upn' (Get-Value $claims 'unique_name' $account.user.name)) } else { [string]$claims.oid }
    $FabricCapacityAdmins = @(@($FabricCapacityAdmins) + $caller | Where-Object { $_ } | Sort-Object -Unique)
    $templateValues['fabricCapacityUnits'] = [Math]::Min(2048, $capacityUnits)
    Write-Ok ("Fabric capacity {0}: {1} ({2} CU, {3}) in {4} | {5} | quota: {6}" -f $FabricCapacityName, $FabricCapacitySku, $capacityUnits, (Format-FabricCost -Price $fabricPrice -Units $capacityUnits),
        $hubLocation, $(if ($existingCapacity) { "existing ($currentSku, $(Get-Value $existingCapacity 'properties.state' ''))" } else { 'new' }), $(if ($quota) { "$($quota.Available) of $($quota.Limit) CU available" } else { 'unknown' }))

    if (-not $FabricWorkspaceName) { $FabricWorkspaceName = "FinOps hub - $ResourceGroupName" }
    $existingWorkspace = Find-FabricWorkspace $FabricWorkspaceName
    if ($existingWorkspace) {
        $assigned = [string](Get-Value $existingWorkspace 'capacityId' '')
        if ($assigned) {
            $owner = @(Get-FabricList '/capacities' | Where-Object { (Get-Value $_ 'id' '') -eq $assigned }) | Select-Object -First 1
            $ownerName = [string](Get-Value $owner 'displayName' '')
            if ($ownerName -ine $FabricCapacityName) { throw "Fabric workspace '$FabricWorkspaceName' already exists on capacity '$(if ($ownerName) { $ownerName } else { $assigned })'. Pass -FabricWorkspaceName with another name, or -FabricCapacityName $(if ($ownerName) { $ownerName } else { '<that capacity>' })." }
        }
        Write-Ok "Fabric workspace '$FabricWorkspaceName' exists and will be reused (eventhouse '$FabricEventhouseName', databases Ingestion + Hub)"
    }
    else { Write-Ok "Fabric workspace '$FabricWorkspaceName' will be created (eventhouse '$FabricEventhouseName', databases Ingestion + Hub)" }

    $vnetPath = "/subscriptions/$VirtualNetworkSubscriptionId/resourceGroups/$VirtualNetworkResourceGroupName/providers/Microsoft.Network/virtualNetworks/$VirtualNetworkName"
    $vnetResponse = Invoke-Arm -Path "$vnetPath`?api-version=2024-05-01" -AllowNotFound
    if (-not $vnetResponse) { throw "Virtual network $VirtualNetworkName was not found in resource group $VirtualNetworkResourceGroupName (subscription $VirtualNetworkSubscriptionId)." }
    $vnet = $vnetResponse.Content
    $subnet = @(Get-Value $vnet 'properties.subnets' @() | Where-Object { $_.name -eq $PrivateEndpointSubnetName })
    if ($subnet.Count -eq 0) { throw "Subnet $PrivateEndpointSubnetName was not found in virtual network $VirtualNetworkName." }
    $subnet = $subnet[0]
    if (@(Get-Value $subnet 'properties.delegations' @()).Count -gt 0) { throw "Subnet $PrivateEndpointSubnetName is delegated to a service; private endpoints need a subnet without delegations." }
    $subnetPrefix = [string](Get-Value $subnet 'properties.addressPrefix' '')
    if (-not $subnetPrefix) { $subnetPrefix = [string](@(Get-Value $subnet 'properties.addressPrefixes' @()) | Select-Object -First 1) }
    if ($subnetPrefix -notmatch '/\d+$') { throw "Could not read the address prefix of subnet $PrivateEndpointSubnetName." }
    $freeIps = [Math]::Pow(2, 32 - [int]$subnetPrefix.Split('/')[1]) - 5 - @(Get-Value $subnet 'properties.ipConfigurations' @()).Count
    Write-Ok "Virtual network $VirtualNetworkName ($($vnet.location)) | subnet $PrivateEndpointSubnetName $subnetPrefix | ~$freeIps free IPs"
    if ($freeIps -lt 8) { Write-Warn "Subnet $PrivateEndpointSubnetName has only ~$freeIps free IP addresses; the private endpoints use about 5." }
    $vnetRegion = ([string]$vnet.location).ToLowerInvariant().Replace(' ', '')
    if ($vnetRegion -ne $hubLocation) { Write-Info "The hub and Fabric capacity ($hubLocation) are in another region than the virtual network ($vnetRegion); private endpoints work across regions." }
    $dnsServers = @(Get-Value $vnet 'properties.dhcpOptions.dnsServers' @())
    if ($dnsServers.Count -gt 0 -and -not $SkipPrivateDnsZones) {
        Write-Warn "The virtual network uses custom DNS servers ($($dnsServers -join ', ')). They must resolve the privatelink zones, for example by forwarding to Azure DNS (168.63.129.16) from a network linked to the zones, or through Azure DNS Private Resolver."
    }
    $hubPrefix = [string](Get-Value $templateValues 'virtualNetworkAddressPrefix' '10.20.30.0/26')
    foreach ($space in @(Get-Value $vnet 'properties.addressSpace.addressPrefixes' @())) {
        if (Test-CidrOverlap $hubPrefix $space) { Write-Warn "Hub internal network $hubPrefix overlaps your virtual network range $space. That is fine for private endpoints, but blocks peering later. Use -HubVirtualNetworkAddressPrefix to change it." }
    }

    $dnsPlan = @()
    if ($SkipPrivateDnsZones) { Write-Info 'Private DNS: not managed (-SkipPrivateDnsZones). Create the records printed at step 5 in your DNS.' }
    else {
        if (-not (Invoke-Arm -Path "/subscriptions/$PrivateDnsZoneSubscriptionId/resourcegroups/$PrivateDnsZoneResourceGroupName`?api-version=2021-04-01" -AllowNotFound)) {
            throw "Private DNS zone resource group '$PrivateDnsZoneResourceGroupName' was not found in subscription $PrivateDnsZoneSubscriptionId. Create it first, or pass the resource group that holds your private DNS zones."
        }
        $dnsPlan = @(Get-PrivateDnsZonePlan -ZoneNames (Get-HubDnsZoneNames) -VirtualNetworkId $vnet.id -DnsSubscription $PrivateDnsZoneSubscriptionId -DnsResourceGroup $PrivateDnsZoneResourceGroupName)
        Write-Ok ("Private DNS zones: {0} already linked to the virtual network, {1} to link, {2} to create (in {3}, subscription {4})" -f @($dnsPlan | Where-Object Action -eq 'Reuse').Count, @($dnsPlan | Where-Object Action -eq 'Link').Count, @($dnsPlan | Where-Object Action -eq 'Create').Count, $PrivateDnsZoneResourceGroupName, $PrivateDnsZoneSubscriptionId)
        foreach ($zone in $dnsPlan) {
            $parts = $zone.Id.Split('/')
            $where = if ($zone.Action -eq 'Reuse') { "$($parts[4]) (subscription $($parts[2]))" } else { "$PrivateDnsZoneResourceGroupName (subscription $PrivateDnsZoneSubscriptionId)" }
            Write-Info ("  {0,-42} {1,-7} {2}" -f $zone.Name, $zone.Action.ToLowerInvariant(), $where)
        }
    }

    $hubScope = if (Invoke-Arm -Path "/subscriptions/$SubscriptionId/resourcegroups/$ResourceGroupName`?api-version=2021-04-01" -AllowNotFound) { "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName" } else { "/subscriptions/$SubscriptionId" }
    $capacityScope = if (Invoke-Arm -Path "/subscriptions/$SubscriptionId/resourcegroups/$capacityGroup`?api-version=2021-04-01" -AllowNotFound) { "/subscriptions/$SubscriptionId/resourceGroups/$capacityGroup" } else { "/subscriptions/$SubscriptionId" }
    $peScope = if (Invoke-Arm -Path "/subscriptions/$VirtualNetworkSubscriptionId/resourcegroups/$PrivateEndpointResourceGroupName`?api-version=2021-04-01" -AllowNotFound) { "/subscriptions/$VirtualNetworkSubscriptionId/resourceGroups/$PrivateEndpointResourceGroupName" } else { "/subscriptions/$VirtualNetworkSubscriptionId" }
    $requiredPermissions = [System.Collections.Generic.List[object]]::new()
    $require = {
        param([string] $Scope, [string] $Action, [string] $Why)
        if (-not @($requiredPermissions | Where-Object { $_.Scope -eq $Scope -and $_.Action -eq $Action }).Count) { $requiredPermissions.Add(@{ Scope = $Scope; Action = $Action; Why = $Why }) }
    }
    & $require $hubScope 'Microsoft.Resources/deployments/write' 'deploy the hub'
    & $require $hubScope 'Microsoft.Authorization/roleAssignments/write' 'grant hub managed identities access (Owner or User Access Administrator)'
    & $require $hubScope 'Microsoft.Storage/storageAccounts/write' 'set the storage firewall for Fabric ingestion'
    & $require $capacityScope 'Microsoft.Fabric/capacities/write' 'create or update the Fabric capacity'
    & $require $subnet.id 'Microsoft.Network/virtualNetworks/subnets/join/action' 'place private endpoints in the subnet'
    & $require $peScope 'Microsoft.Network/privateEndpoints/write' 'create private endpoints'
    & $require $peScope 'Microsoft.Resources/deployments/write' 'deploy the private endpoints'
    $dnsScope = "/subscriptions/$PrivateDnsZoneSubscriptionId/resourceGroups/$PrivateDnsZoneResourceGroupName"
    foreach ($zone in $dnsPlan) {
        $zoneScope = if ($zone.Action -eq 'Create') { $dnsScope } else { $zone.Id }
        & $require $zoneScope 'Microsoft.Network/privateDnsZones/join/action' "register DNS records in $($zone.Name)"
        if ($zone.Action -ne 'Reuse') {
            & $require $dnsScope 'Microsoft.Resources/deployments/write' 'deploy private DNS zones and links'
            & $require $vnet.id 'Microsoft.Network/virtualNetworks/join/action' 'link private DNS zones to the virtual network'
            & $require $zoneScope 'Microsoft.Network/privateDnsZones/virtualNetworkLinks/write' "link $($zone.Name) to the virtual network"
        }
        if ($zone.Action -eq 'Create') { & $require $dnsScope 'Microsoft.Network/privateDnsZones/write' 'create missing private DNS zones' }
    }
    $missingPermissions = @($requiredPermissions | Where-Object { -not (Test-ArmPermission -Scope $_.Scope -Action $_.Action) })
    if ($missingPermissions.Count -gt 0) {
        throw "Missing permissions: " + (($missingPermissions | ForEach-Object { "$($_.Action) on $($_.Scope) (to $($_.Why))" }) -join '; ')
    }
    Write-Ok "Permissions verified ($($requiredPermissions.Count) checks: deployments, role assignments, storage, Fabric capacity, subnet, private endpoints$(if ($dnsPlan.Count) { ', private DNS zones and links' }))"

    if ($guided) {
        $planScopes = if ($SkipExports) { 0 } elseif ($ExportScopes) { @($ExportScopes).Count } else { @(Get-DefaultExportScopes).Count }
        $exportPlan = if ($SkipExports) { 'skipped' } elseif ($ExportScopes) { "$planScopes scope(s), $BackfillMonths month(s) of history" } else { "$planScopes subscription(s) (every enabled subscription you can see), $BackfillMonths month(s) of history" }
        Write-Host ''
        Write-Host '  Deployment plan' -ForegroundColor Cyan
        Write-Info "FinOps hub:        $($templateValues['hubName']) in resource group $ResourceGroupName ($hubLocation), subscription '$($account.name)'"
        Write-Info "Fabric capacity:   $FabricCapacityName $FabricCapacitySku ($capacityUnits CU) in $capacityGroup - $(Format-FabricCost -Price $fabricPrice -Units $capacityUnits) while active$(if ($existingCapacity) { ' (existing)' })"
        Write-Info "Fabric workspace:  $FabricWorkspaceName - eventhouse $FabricEventhouseName with the Ingestion and Hub databases, real-time dashboard"
        Write-Info "Private endpoints: $VirtualNetworkName / $PrivateEndpointSubnetName (endpoint resources in $PrivateEndpointResourceGroupName)"
        $dnsSummary = if ($SkipPrivateDnsZones) { 'not managed by this script' } else {
            '{0} already linked (reused); {1} to link and {2} to create in {3} (subscription {4})' -f @($dnsPlan | Where-Object Action -eq 'Reuse').Count,
            @($dnsPlan | Where-Object Action -eq 'Link').Count, @($dnsPlan | Where-Object Action -eq 'Create').Count, $PrivateDnsZoneResourceGroupName, $PrivateDnsZoneSubscriptionId
        }
        Write-Info "Private DNS zones: $dnsSummary"
        Write-Info "Cost exports:      $exportPlan"
        Write-Info "Storage firewall:  $(if ($KeepStorageFirewallClosed) { 'kept closed (-KeepStorageFirewallClosed): data will not reach Fabric' } else { 'allows all networks with Entra ID/RBAC (required for Fabric ingestion)' })"
        Write-Info 'Duration:          about 35-60 minutes'
        if ($planScopes -gt 0) { Write-Info "Data in Fabric:    first data about 30-60 minutes after the deployment, full history $(Get-DataArrivalEstimate -Scopes $planScopes -Months ($BackfillMonths + 1))" }
        if (-not (Read-YesNo 'Start the deployment?')) {
            Write-Host '    Cancelled. Nothing was deployed.' -ForegroundColor Yellow
            return
        }
    }

    # --- 2. Fabric capacity --------------------------------------------------------------------------------
    Write-Step "Fabric capacity $FabricCapacityName ($FabricCapacitySku)"
    Set-ResourceGroup -Subscription $SubscriptionId -Name $ResourceGroupName -RegionName $hubLocation -ResourceTags $resourceTags -MergeTags | Out-Null
    if ($capacityGroup -ne $ResourceGroupName) { Set-ResourceGroup -Subscription $SubscriptionId -Name $capacityGroup -RegionName $hubLocation -ResourceTags $resourceTags -MergeTags | Out-Null }
    $capacity = Set-FabricCapacity -CapacityId $capacityArmId -RegionName $hubLocation -Sku $FabricCapacitySku -Admins $FabricCapacityAdmins -ResourceTags $resourceTags
    Write-Ok "Fabric capacity $FabricCapacityName is $(Get-Value $capacity 'properties.state' '') ($(Get-Value $capacity 'sku.name' '')) | administrators: $(@(Get-Value $capacity 'properties.administration.members' @()) -join ', ')"
    $capacityGuid = Get-FabricCapacityGuid -CapacityName $FabricCapacityName -RegionName $hubLocation
    Write-Ok "Capacity is active in Fabric (capacity ID $capacityGuid)"

    # --- 3. Fabric workspace, eventhouse and databases ----------------------------------------------------
    Write-Step 'Fabric workspace, eventhouse and databases'
    $workspace = Set-FabricWorkspace -Name $FabricWorkspaceName -CapacityGuid $capacityGuid
    $workspaceId = [string]$workspace.id
    $workspaceIdentity = Set-FabricWorkspaceIdentity -WorkspaceId $workspaceId
    $identityRole = Set-FabricWorkspaceRole -WorkspaceId $workspaceId -PrincipalId $workspaceIdentity.ServicePrincipalId -PrincipalType 'ServicePrincipal' -Role 'Contributor'
    Write-Ok "Workspace identity $($workspaceIdentity.ApplicationId) | workspace role: $identityRole"
    $eventhouse = Set-FabricEventhouse -WorkspaceId $workspaceId -Name $FabricEventhouseName
    $queryUri = ([string](Get-Value $eventhouse 'properties.queryServiceUri' '')).TrimEnd('/')
    Write-Ok "Eventhouse query URI: $queryUri"
    $ingestionDatabase = Set-FabricKqlDatabase -WorkspaceId $workspaceId -EventhouseId $eventhouse.id -Name 'Ingestion'
    $hubDatabase = Set-FabricKqlDatabase -WorkspaceId $workspaceId -EventhouseId $eventhouse.id -Name 'Hub'
    $setupResults = [System.Collections.Generic.List[object]]::new()
    foreach ($setup in @(@{ Database = 'Ingestion'; Path = $ingestionScript }, @{ Database = 'Hub'; Path = $hubScript })) {
        Write-Info "Running $(Split-Path $setup.Path -Leaf) in the $($setup.Database) database (raw retention $rawRetentionInDays day(s))..."
        $result = Invoke-FabricSetupScript -QueryUri $queryUri -Database $setup.Database -ScriptPath $setup.Path -RawRetentionInDays $rawRetentionInDays
        $setupResults.Add($result)
        if ($result.Failed -gt 0) { throw "The $($setup.Database) setup script had $($result.Failed) failed command(s) of $($result.Commands) after $($result.Attempts) attempt(s): $($result.Errors -join ' | '). Re-run the script (the setup scripts are idempotent)." }
        Write-Ok "$($setup.Database) database schema: $($result.Commands) commands completed$(if ($result.Attempts -gt 1) { " (attempt $($result.Attempts))" })"
    }
    $templateValues['fabricQueryUri'] = $queryUri

    # --- 4. FinOps hub template ----------------------------------------------------------------------------
    Write-Step 'Deploying the FinOps hub template (private access, Fabric data store)'
    if ($SkipHubDeployment) {
        $previous = @(Get-ArmList "/subscriptions/$SubscriptionId/resourcegroups/$ResourceGroupName/providers/Microsoft.Resources/deployments?api-version=2024-03-01" |
            Where-Object { $_.name -like "$script:DeploymentPrefix-*" -and $_.properties.provisioningState -eq 'Succeeded' } |
            Sort-Object { [DateTime](Get-Value $_ 'properties.timestamp') } -Descending)
        if ($previous.Count -eq 0) { throw "-SkipHubDeployment was used but no successful '$script:DeploymentPrefix-*' deployment exists in $ResourceGroupName." }
        $hubDeployment = [pscustomobject]@{ Name = $previous[0].name; Outputs = (Get-Value $previous[0] 'properties.outputs') }
        Write-Ok "Reusing outputs of deployment '$($hubDeployment.Name)'"
    }
    else {
        if (-not $templateValues['fabricQueryUri']) { throw 'The eventhouse query URI is missing; the template cannot be deployed without it.' }
        Write-Info 'This takes 20-35 minutes (private networking, deployment scripts).'
        $templateJson = ConvertTo-Minified (Get-Content -Path $TemplateFile -Raw)
        $hubDeployment = Invoke-GroupDeployment -Subscription $SubscriptionId -ResourceGroup $ResourceGroupName -NamePrefix $script:DeploymentPrefix `
            -TemplateJson $templateJson -Parameters ([hashtable]$templateValues) -MaxAttempts $MaxDeploymentAttempts -TimeoutMinutes 180 -ShowNestedProgress -ResumeRunning `
            -BeforeAttempt { Clear-HubDeploymentScripts -Subscription $SubscriptionId -ResourceGroup $ResourceGroupName }
    }
    $hub = Get-HubResourceIds -Outputs $hubDeployment.Outputs -TemplateValues ([hashtable]$templateValues)
    if (-not $hub.StorageId) { throw 'The deployment outputs do not contain the storage account.' }
    if ($hub.QueryUri -and $hub.QueryUri.TrimEnd('/') -ne $queryUri) { Write-Warn "The hub deployment points to $($hub.QueryUri), not to eventhouse $queryUri. Re-run without -SkipHubDeployment." }
    $factoryPrincipalId = [string](Get-Value (Invoke-Arm -Path "$($hub.DataFactoryId)?api-version=2018-06-01").Content 'identity.principalId' $hub.PrincipalId)
    Write-Ok "Storage: $($hub.StorageName) | Data Factory: $($hub.DataFactoryName) | data store: $queryUri"

    # --- 5. Private endpoints ------------------------------------------------------------------------------
    Write-Step "Private endpoints in $VirtualNetworkName/$PrivateEndpointSubnetName"
    $privateEndpoints = @(Set-HubPrivateEndpoints -Hub $hub -VirtualNetwork $vnet -SubnetId $subnet.id -VnetSubscription $VirtualNetworkSubscriptionId `
            -EndpointResourceGroup $PrivateEndpointResourceGroupName -DnsSubscription $PrivateDnsZoneSubscriptionId -DnsResourceGroup $PrivateDnsZoneResourceGroupName -ResourceTags $resourceTags)
    foreach ($endpoint in $privateEndpoints) {
        Write-Ok "$($endpoint.Name) [$($endpoint.GroupId)] $($endpoint.Status)"
        foreach ($record in $endpoint.Records) { Write-Info "      $record" }
    }

    # --- 6. Hardening ------------------------------------------------------------------------------------------
    Write-Step 'Network hardening and Fabric storage access'
    if (-not $AllowDataFactoryPublicAccess) {
        Invoke-Arm -Method PATCH -Path "$($hub.DataFactoryId)?api-version=2018-06-01" -Body @{ properties = @{ publicNetworkAccess = 'Disabled' } } -RetryOnConflict | Out-Null
        Write-Ok 'Data Factory public network access disabled (self-hosted integration runtime traffic only through private link)'
    }
    else { Write-Info 'Data Factory public network access left enabled (-AllowDataFactoryPublicAccess).' }
    $storageAccess = Set-FabricStorageAccess -Hub $hub -WorkspaceId $workspaceId -KeepFirewallClosed:$KeepStorageFirewallClosed
    $storageAccessUtc = [DateTime]::UtcNow
    $fabricRuleId = $storageAccess.RuleId
    $storage = (Invoke-Arm -Path "$($hub.StorageId)?api-version=2023-05-01").Content
    $fabricRuleCount = @(Get-Value $storage 'properties.networkAcls.resourceAccessRules' @() | Where-Object { (Get-Value $_ 'resourceId' '') -ieq $fabricRuleId }).Count
    $firewallText = "default action $(Get-Value $storage 'properties.networkAcls.defaultAction'), bypass $(Get-Value $storage 'properties.networkAcls.bypass'), Fabric workspace rule $(if ($fabricRuleCount) { 'present' } else { 'MISSING' })"
    if ($KeepStorageFirewallClosed) { Write-Warn "Storage firewall kept closed (-KeepStorageFirewallClosed): $firewallText. Fabric eventhouses cannot load data through a storage firewall, so cost data will stay in storage." }
    else { Write-Ok "Storage firewall: $firewallText. All networks are allowed (Entra ID/RBAC still required) because Fabric eventhouse ingestion cannot pass a storage firewall." }
    foreach ($managed in @(Sync-ManagedPrivateEndpoints -Hub $hub)) {
        $note = if ($managed.FactoryStatus -ne $managed.Status) { " (Data Factory still shows '$($managed.FactoryStatus)'; the target resource is authoritative)" } else { '' }
        if ($managed.Status -eq 'Approved') { Write-Ok "Data Factory managed private endpoint to $($managed.Target): Approved$note" }
        else { Write-Warn "Data Factory managed private endpoint to $($managed.Target): $($managed.Status)$note" }
    }

    # --- 7. Fabric access ----------------------------------------------------------------------------------
    Write-Step 'Fabric access: Data Factory, dashboard users and hub initialization'
    $adminResults = @(Grant-FabricDatabaseAdmin -QueryUri $queryUri -Databases @('Ingestion', 'Hub') -PrincipalObjectId $factoryPrincipalId)
    Grant-FabricWorkspaceViewers -WorkspaceId $workspaceId -PrincipalIds $FabricViewers
    Write-Info 'Running the hub initialization pipeline again now that Data Factory can use the databases...'
    $initialization = Invoke-HubPipeline -FactoryId $hub.DataFactoryId -NameSuffix '_InitializeHub'
    if ($initialization.Status -eq 'Succeeded') { Write-Ok "Pipeline $($initialization.Pipeline) succeeded (run $($initialization.RunId))" }
    else { Write-Warn "Pipeline $($initialization.Pipeline) is $($initialization.Status) (run $($initialization.RunId)): $($initialization.Error)" }
    $restartedFolders = @()
    if (-not $KeepStorageFirewallClosed) {
        $restartedFolders = @(Restart-FailedHubIngestion -FactoryId $hub.DataFactoryId)
        if ($restartedFolders.Count -gt 0) { Write-Ok "Re-queued $($restartedFolders.Count) data load(s) that failed earlier (for example while the storage firewall was closed)" }
        else { Write-Info 'No failed data loads to re-run.' }
    }

    # --- 8. Cost Management exports ------------------------------------------------------------------------
    Write-Step 'Cost Management exports'
    $exportResults = @()
    if ($SkipExports) { Write-Info 'Skipped (-SkipExports).' }
    else {
        if (-not $ExportScopes -or $ExportScopes.Count -eq 0) { $ExportScopes = Get-DefaultExportScopes }
        Write-Info "Scopes: $($ExportScopes.Count) | FOCUS $FocusDatasetVersion | Parquet/Snappy | container msexports | backfill $BackfillMonths month(s)"
        $grantReader = [bool](Get-Value $templateValues 'enableRecommendations' $false)
        $exportResults = @(Set-AllCostExports -Hub $hub -Scopes $ExportScopes -GrantReader $grantReader)
    }

    # --- 9. Dashboard -------------------------------------------------------------------------------------------
    Write-Step 'Fabric real-time dashboard'
    $dashboard = $null
    if ($SkipDashboard) { Write-Info 'Skipped (-SkipDashboard).' }
    else {
        try {
            $dashboard = Import-FabricDashboard -WorkspaceId $workspaceId -QueryUri $queryUri -HubDatabaseId $hubDatabase.id -Title "FinOps hub - $($templateValues['hubName'])"
            Write-Info "Tiles: $($dashboard.Tiles) | connected to the Hub database: $($dashboard.Connected)"
            Write-Info "URL: $($dashboard.Url)"
            if (-not $NoBrowser) { try { Start-Process $dashboard.Url } catch { Write-Info 'Open the URL above in your browser.' } }
        }
        catch { Write-Warn "Dashboard import failed: $($_.Exception.Message)" }
    }

    # --- 10. Verification ---------------------------------------------------------------------------------------
    Write-Step 'Verification'
    $checks = [System.Collections.Generic.List[object]]::new()
    $capacityNow = (Invoke-Arm -Path "$capacityArmId`?api-version=$script:FabricArmApiVersion").Content
    $checks.Add([pscustomobject]@{ Check = 'Fabric capacity active'; Result = "$(Get-Value $capacityNow 'sku.name' '') $(Get-Value $capacityNow 'properties.state' '')"; Pass = ((Get-Value $capacityNow 'properties.state' '') -eq 'Active') })
    $workspaceNow = Invoke-Fabric -Path "/workspaces/$workspaceId"
    $checks.Add([pscustomobject]@{ Check = 'Fabric workspace on the capacity'; Result = $FabricWorkspaceName; Pass = ((Get-Value $workspaceNow 'capacityId' '') -eq $capacityGuid) })
    $checks.Add([pscustomobject]@{ Check = 'Fabric workspace identity'; Result = $workspaceIdentity.ApplicationId; Pass = [bool]$workspaceIdentity.ServicePrincipalId })
    $schemaOk = @($setupResults | Where-Object { $_.Failed -eq 0 -and $_.Commands -gt 0 }).Count -eq 2
    $checks.Add([pscustomobject]@{ Check = 'Ingestion and Hub database schema'; Result = (($setupResults | ForEach-Object { "$($_.Database): $($_.Commands) commands" }) -join ', '); Pass = $schemaOk })
    $adminOk = @($adminResults | Where-Object Admin).Count -eq 2
    $checks.Add([pscustomobject]@{ Check = 'Data Factory admin of both databases'; Result = (($adminResults | ForEach-Object { "$($_.Database)=$($_.Admin)" }) -join ', '); Pass = $adminOk })
    $checks.Add([pscustomobject]@{ Check = 'Hub initialization pipeline'; Result = $initialization.Status; Pass = ($initialization.Status -eq 'Succeeded') })
    $storageNow = (Invoke-Arm -Path "$($hub.StorageId)?api-version=2023-05-01").Content
    $actionNow = [string](Get-Value $storageNow 'properties.networkAcls.defaultAction' '')
    $expectedAction = if ($KeepStorageFirewallClosed) { 'Deny' } else { 'Allow' }
    $checks.Add([pscustomobject]@{ Check = 'Storage firewall'; Result = "defaultAction=$actionNow (expected $expectedAction$(if (-not $KeepStorageFirewallClosed) { ' for Fabric ingestion' }))"; Pass = ($actionNow -eq $expectedAction) })
    $ruleNow = @(Get-Value $storageNow 'properties.networkAcls.resourceAccessRules' @() | Where-Object { (Get-Value $_ 'resourceId' '') -ieq $fabricRuleId }).Count -gt 0
    $checks.Add([pscustomobject]@{ Check = 'Fabric workspace resource instance rule'; Result = $(if ($ruleNow) { 'present' } else { 'missing' }); Pass = $ruleNow })
    # Firewall changes take up to about a minute to apply; loads that failed before that are re-run in step 7.
    $ingestion = Get-FabricIngestionHealth -QueryUri $queryUri -SinceUtc $storageAccessUtc.AddMinutes(2)
    $ingestionText = if ($ingestion.StorageAccessFails -gt 0) { "$($ingestion.StorageAccessFails) storage access failure(s) since $($ingestion.Since)" }
    elseif ($KeepStorageFirewallClosed) { 'storage firewall kept closed (-KeepStorageFirewallClosed): data cannot reach Fabric' }
    elseif ($ingestion.CostRows -gt 0) { "$($ingestion.CostRows) cost rows in Hub.Costs(), no storage access failures" }
    else { 'no loads yet (exports are still running), no storage access failures' }
    $checks.Add([pscustomobject]@{ Check = 'Fabric data loads'; Result = $ingestionText; Pass = ($ingestion.StorageAccessFails -eq 0 -and -not $KeepStorageFirewallClosed) })
    $factory = (Invoke-Arm -Path "$($hub.DataFactoryId)?api-version=2018-06-01").Content
    $factoryAccess = Get-Value $factory 'properties.publicNetworkAccess' 'Enabled'
    $checks.Add([pscustomobject]@{ Check = 'Data Factory public access'; Result = $factoryAccess; Pass = ($AllowDataFactoryPublicAccess -or $factoryAccess -eq 'Disabled') })
    $approved = @($privateEndpoints | Where-Object Status -eq 'Approved').Count
    $checks.Add([pscustomobject]@{ Check = 'Private endpoints approved'; Result = "$approved of $($privateEndpoints.Count)"; Pass = ($approved -eq $privateEndpoints.Count) })
    if (-not $SkipPrivateDnsZones) {
        $dnsIssueCount = @($privateEndpoints | ForEach-Object { $_.DnsIssues }).Count
        $checks.Add([pscustomobject]@{ Check = 'Private DNS records point to endpoints'; Result = $(if ($dnsIssueCount) { "$dnsIssueCount issue(s)" } else { 'all records OK' }); Pass = ($dnsIssueCount -eq 0) })
    }
    $managedEndpoints = @(Sync-ManagedPrivateEndpoints -Hub $hub)
    $managedApproved = @($managedEndpoints | Where-Object Status -eq 'Approved').Count
    $checks.Add([pscustomobject]@{ Check = 'Data Factory managed private endpoints'; Result = "$managedApproved of $($managedEndpoints.Count) approved ($(($managedEndpoints | ForEach-Object { $_.Target }) -join ', '))"; Pass = ($managedEndpoints.Count -gt 0 -and $managedApproved -eq $managedEndpoints.Count) })
    $triggers = @(Get-ArmList "$($hub.DataFactoryId)/triggers?api-version=2018-06-01")
    $started = @($triggers | Where-Object { (Get-Value $_ 'properties.runtimeState') -eq 'Started' }).Count
    $checks.Add([pscustomobject]@{ Check = 'Data Factory triggers started'; Result = "$started of $($triggers.Count)"; Pass = ($started -gt 0) })
    if (-not $SkipExports) {
        $okScopes = @($exportResults | Where-Object { -not $_.Error }).Count
        $checks.Add([pscustomobject]@{ Check = 'Export scopes configured'; Result = "$okScopes of $($exportResults.Count)"; Pass = ($okScopes -eq $exportResults.Count -and $okScopes -gt 0) })
    }
    if (-not $SkipDashboard) {
        $checks.Add([pscustomobject]@{ Check = 'Fabric dashboard imported'; Result = $(if ($dashboard) { "$($dashboard.Tiles) tiles, Hub connected: $($dashboard.Connected)" } else { 'failed' }); Pass = ([bool]$dashboard -and $dashboard.Connected -and $dashboard.Tiles -gt 0) })
    }
    foreach ($check in $checks) {
        if ($check.Pass) { Write-Ok ("{0,-42} {1}" -f $check.Check, $check.Result) } else { Write-Warn ("{0,-42} {1}" -f $check.Check, $check.Result) }
    }
    if ($ingestion.StorageAccessFails -gt 0) {
        Write-Warn "The Fabric eventhouse could not read storage account $($hub.StorageName) ($($ingestion.StorageAccessFails) Download_Forbidden failure(s) since $($ingestion.Since)). Check that no policy closes the storage firewall again, then re-run the script to re-queue the failed loads."
    }
    if ($ingestion.OtherFailures.Count -gt 0) { Write-Warn "Other Fabric ingestion failures since $($ingestion.Since): $($ingestion.OtherFailures -join ', ')" }

    $summary = [ordered]@{
        completedUtc     = [DateTime]::UtcNow.ToString('o')
        durationMinutes  = [Math]::Round(((Get-Date) - $overallStart).TotalMinutes, 1)
        hubDeployment    = $hubDeployment.Name
        subscriptionId   = $SubscriptionId
        resourceGroup    = $ResourceGroupName
        hub              = $hub
        fabric           = [ordered]@{
            capacityId         = $capacityArmId
            capacitySku        = $FabricCapacitySku
            capacityUnits      = $capacityUnits
            region             = $hubLocation
            fabricCapacityGuid = $capacityGuid
            workspaceId        = $workspaceId
            workspaceName      = $FabricWorkspaceName
            workspaceUrl       = "https://app.fabric.microsoft.com/groups/$workspaceId`?experience=fabric-developer"
            workspaceIdentity  = $workspaceIdentity
            eventhouseId       = [string]$eventhouse.id
            queryUri           = $queryUri
            ingestionDatabase  = [string]$ingestionDatabase.id
            hubDatabase        = [string]$hubDatabase.id
            setupScripts       = $setupResults
            databaseAdmins     = $adminResults
            initialization     = $initialization
            storageFirewall    = $storageAccess
            restartedLoads     = $restartedFolders
            ingestion          = $ingestion
        }
        privateEndpoints = $privateEndpoints
        exports          = $exportResults
        dashboard        = $dashboard
        checks           = $checks
        warnings         = $script:Warnings
    }
    $summaryPath = Join-Path $logDirectory "deployment-summary-v3-fabric-$runStamp.json"
    $summary | ConvertTo-Json -Depth 10 | Set-Content -Path $summaryPath -Encoding utf8

    $links = [ordered]@{}
    if ($dashboard) { $links['Dashboard'] = $dashboard.Url }
    $links['Fabric workspace'] = "https://app.fabric.microsoft.com/groups/$workspaceId`?experience=fabric-developer"
    $links['Eventhouse (KQL)'] = "$queryUri (databases Ingestion and Hub)"
    $links['Storage (Power BI)'] = $hub.StorageUrlPowerBI
    $links['Summary'] = $summaryPath
    $exportedScopes = @($exportResults | Where-Object { -not $_.Error } | ForEach-Object { $_.Scope })
    $scopeLabel = if (@($exportedScopes | Where-Object { $_ -notmatch '^/subscriptions/' }).Count) { 'export scope(s)' } else { 'subscription(s)' }
    Write-CompletionSummary -Checks $checks -Duration ((Get-Date) - $overallStart) -Links $links -ExportScopes $exportedScopes.Count -Months ($BackfillMonths + 1) -ScopeLabel $scopeLabel -Notes @(
        "Fabric capacity $FabricCapacityName ($FabricCapacitySku) is billed while active: $(Format-FabricCost -Price $fabricPrice -Units $capacityUnits)."
        "  Pause:  az rest --method post --url `"https://management.azure.com$capacityArmId/suspend?api-version=$script:FabricArmApiVersion`""
        "  Resume: az rest --method post --url `"https://management.azure.com$capacityArmId/resume?api-version=$script:FabricArmApiVersion`" (or re-run this script)"
    )
}
catch {
    Write-Host ''
    Write-Host "DEPLOYMENT FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Re-run the script after fixing the issue; all steps are idempotent." -ForegroundColor Red
    throw
}
finally {
    Stop-Transcript | Out-Null
}
#endregion
