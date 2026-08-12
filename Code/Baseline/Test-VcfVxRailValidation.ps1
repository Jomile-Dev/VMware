<#
.SYNOPSIS
    Menu-driven VCF on VxRail validation toolkit.

.DESCRIPTION
    Supports:
      1. Standard sanity check
      2. Create pre-change baseline
      3. Validate one relocated host
      4. Post-migration validation
      5. Exit

    The operator can select:
      - one cluster
      - several clusters
      - all clusters

    Standard sanity checks, baseline creation and post-migration validation
    process every ESXi host in the selected cluster or clusters.

    Relocated-host validation processes one selected ESXi host.

    The script is read-only. It does not enter or exit maintenance mode and
    does not make configuration changes.

.NOTES
    Test this script in a non-production environment against the exact
    PowerCLI, vCenter, ESXi, VCF, VxRail and vSAN versions in use.
#>

#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$OutputRoot = 'C:\VCF-Validation',

    [PSCredential]$Credential,

    [switch]$SkipCertificateCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

###############################################################################
# PARALLELISM  --  EDIT THE NUMBER BELOW
#
#   1  = serial: validate hosts one at a time. Reliable for every mode
#        (sanity check, baseline, relocated host, post-migration), single
#        cluster or all. Use this for anything real.
#
#   2+ = validate that many hosts at once. Faster on large clusters, but less
#        reliable with PowerCLI (may throw connection or Get-EsxCli errors).
#        Test it against a non-production cluster before trusting it.
###############################################################################

$ThrottleLimit = 1

###############################################################################
# OPTIONAL CHECK TUNABLES  --  SAFE TO EDIT
#
#   $JumboFrameSize      Payload bytes for the don't-fragment jumbo vmkping.
#                        8972 = 9000 MTU (9000 - 28 overhead). Set to the
#                        payload your vSAN / vMotion / overlay MTU expects.
#   $CertExpiryWarnDays  Warn when an ESXi host SSL certificate expires within
#                        this many days (the "no certs expiring during the
#                        migration window" item; ESXi host machine cert only).
#   $VsanN1SafetyFactor  Free space must exceed one host's share times this
#                        factor for the N-1 evacuation-headroom estimate to
#                        pass. Advisory only; dedupe/compression make raw
#                        free-space math approximate.
###############################################################################

$JumboFrameSize     = 8972
$CertExpiryWarnDays = 60
$VsanN1SafetyFactor = 1.25

###############################################################################
# ENVIRONMENT CONFIGURATION
#
# Update only this section with the real vCenter and cluster names.
###############################################################################

$EnvironmentMap = [ordered]@{
    'm01' = [pscustomobject]@{
        DisplayName = 'Management'
        VCenter     = 'test-m01-vc.test.test'
        Cluster     = 'abc21-m01-cl01'
    }

    'w01' = [pscustomobject]@{
        DisplayName = 'Workload 01'
        VCenter     = 'test-w01-vc.test.test'
        Cluster     = 'abc21-w01-cl01'
    }

    'w02' = [pscustomobject]@{
        DisplayName = 'Workload 02'
        VCenter     = 'test-w02-vc.test.test'
        Cluster     = 'abc21-w02-cl01'
    }

    'w03' = [pscustomobject]@{
        DisplayName = 'Workload 03'
        VCenter     = 'test-w03-vc.test.test'
        Cluster     = 'abc21-w03-cl01'
    }

    'w04' = [pscustomobject]@{
        DisplayName = 'Workload 04'
        VCenter     = 'test-w04-vc.test.test'
        Cluster     = 'abc21-w04-cl01'
    }
}

###############################################################################
# END ENVIRONMENT CONFIGURATION
###############################################################################

function ConvertTo-SafeFileName {
    param([Parameter(Mandatory)][string]$Name)
    return ($Name -replace '[\\/:*?"<>|]', '_')
}

function Test-HostQueryable {
    param([Parameter(Mandatory)]$HostObject)
    # Live host queries (Get-VMHostNetworkAdapter, QueryNetworkHint, Get-EsxCli)
    # are only permitted when the host is Connected or in Maintenance. Any other
    # state (Disconnected, NotResponding, powered off) makes them throw.
    return ([string]$HostObject.ConnectionState -in @('Connected', 'Maintenance'))
}

function Write-Section {
    param([string]$Text)

    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkGray
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkGray
}

function Read-MenuChoice {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string[]]$AllowedValues
    )

    while ($true) {
        $choice = (Read-Host $Prompt).Trim()

        if ($AllowedValues -contains $choice.ToUpperInvariant()) {
            return $choice.ToUpperInvariant()
        }

        Write-Warning "Invalid selection: $choice"
    }
}

function Select-Operation {
    Write-Section 'VCF on VxRail Validation Toolkit'

    Write-Host '1. Standard sanity check'
    Write-Host '2. Create baseline'
    Write-Host '3. Validate relocated host'
    Write-Host '4. Post-migration validation'
    Write-Host '5. Exit'

    $choice = Read-MenuChoice -Prompt 'Select operation' -AllowedValues @('1','2','3','4','5')

    switch ($choice) {
        '1' { return 'SanityCheck' }
        '2' { return 'CreateBaseline' }
        '3' { return 'ValidateHostMove' }
        '4' { return 'PostMigration' }
        '5' { return 'Exit' }
    }
}

function Select-Environments {
    Write-Section 'Select cluster scope'

    $keys = @($EnvironmentMap.Keys)

    for ($index = 0; $index -lt $keys.Count; $index++) {
        $key = $keys[$index]
        $env = $EnvironmentMap[$key]

        Write-Host ("{0}. {1}  [{2}]  vCenter: {3}" -f
            ($index + 1),
            $env.Cluster,
            $env.DisplayName,
            $env.VCenter)
    }

    Write-Host 'A. All clusters'
    Write-Host ''
    Write-Host 'You may enter one selection, several selections such as 1,3,5, or A.'

    while ($true) {
        $raw = (Read-Host 'Select cluster(s)').Trim()

        if ($raw.ToUpperInvariant() -eq 'A') {
            return $keys
        }

        $numbers = @(
            $raw -split ',' |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -match '^\d+$' } |
            ForEach-Object { [int]$_ }
        )

        if ($numbers.Count -eq 0) {
            Write-Warning 'No valid cluster selection was entered.'
            continue
        }

        $invalid = $numbers | Where-Object { $_ -lt 1 -or $_ -gt $keys.Count }

        if ($invalid) {
            Write-Warning "Invalid cluster selection: $($invalid -join ', ')"
            continue
        }

        return @(
            $numbers |
            Select-Object -Unique |
            ForEach-Object { $keys[$_ - 1] }
        )
    }
}

function Select-HostFromCluster {
    param(
        [Parameter(Mandatory)]$Cluster,
        [Parameter(Mandatory)][string]$VCenterName
    )

    $hosts = @(Get-VMHost -Location $Cluster -Server $VCenterName | Sort-Object Name)

    if ($hosts.Count -eq 0) {
        throw "No ESXi hosts were found in cluster $($Cluster.Name)."
    }

    Write-Section "Select relocated host: $($Cluster.Name)"

    for ($index = 0; $index -lt $hosts.Count; $index++) {
        $hostObject = $hosts[$index]
        Write-Host ("{0}. {1}  Connection: {2}  Maintenance: {3}" -f
            ($index + 1),
            $hostObject.Name,
            $hostObject.ConnectionState,
            $hostObject.ExtensionData.Runtime.InMaintenanceMode)
    }

    while ($true) {
        $raw = (Read-Host 'Select host').Trim()

        if ($raw -match '^\d+$') {
            $number = [int]$raw

            if ($number -ge 1 -and $number -le $hosts.Count) {
                return $hosts[$number - 1]
            }
        }

        Write-Warning "Invalid host selection: $raw"
    }
}

function New-RunContext {
    param(
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$VCenterName,
        [Parameter(Mandatory)][string]$ClusterName,
        [string]$HostName
    )

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $vcSafe = ConvertTo-SafeFileName $VCenterName
    $clusterSafe = ConvertTo-SafeFileName $ClusterName

    switch ($Mode) {
        'SanityCheck' {
            $runRoot = Join-Path $OutputRoot "Sanity-Checks\$vcSafe\$clusterSafe\$timestamp"
        }

        'CreateBaseline' {
            $runRoot = Join-Path $OutputRoot "Baselines\$vcSafe\$clusterSafe\$timestamp"
        }

        'ValidateHostMove' {
            $hostSafe = ConvertTo-SafeFileName $HostName
            $runRoot = Join-Path $OutputRoot "Migration\$vcSafe\$clusterSafe\Hosts\$hostSafe\$timestamp"
        }

        'PostMigration' {
            $runRoot = Join-Path $OutputRoot "Migration\$vcSafe\$clusterSafe\Post-Migration\$timestamp"
        }

        default {
            throw "Unsupported mode: $Mode"
        }
    }

    $clusterFolder = Join-Path $runRoot 'Cluster'
    $hostsFolder = Join-Path $runRoot 'Hosts'

    New-Item -ItemType Directory -Path $clusterFolder -Force | Out-Null
    New-Item -ItemType Directory -Path $hostsFolder -Force | Out-Null

    return [pscustomobject]@{
        RunRoot       = (Resolve-Path $runRoot).Path
        ClusterFolder = (Resolve-Path $clusterFolder).Path
        HostsFolder   = (Resolve-Path $hostsFolder).Path
        Timestamp     = $timestamp
    }
}

function Export-CsvSafe {
    param(
        [Parameter(ValueFromPipeline)]$InputObject,
        [Parameter(Mandatory)][string]$Path
    )

    begin {
        $items = [System.Collections.Generic.List[object]]::new()
    }

    process {
        if ($null -ne $InputObject) {
            $items.Add($InputObject)
        }
    }

    end {
        $items | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    }
}

function Get-HostSummary {
    param([Parameter(Mandatory)]$Hosts)

    foreach ($hostObject in $Hosts) {
        $view = Get-View -Id $hostObject.Id
        $hardware = $view.Summary.Hardware

        [pscustomobject]@{
            Host              = $hostObject.Name
            ConnectionState   = $hostObject.ConnectionState
            PowerState        = $hostObject.PowerState
            InMaintenanceMode = $hostObject.ExtensionData.Runtime.InMaintenanceMode
            Version           = $hostObject.Version
            Build             = $hostObject.Build
            Manufacturer      = $hostObject.Manufacturer
            Model             = $hostObject.Model
            CpuModel          = $hardware.CpuModel
            CpuSockets        = $hardware.NumCpuPkgs
            CpuCores          = $hardware.NumCpuCores
            CpuThreads        = $hardware.NumCpuThreads
            MemoryGB          = [math]::Round($hostObject.MemoryTotalGB, 2)
            OverallStatus     = $view.OverallStatus
            BootTime          = $view.Runtime.BootTime
        }
    }
}

function Get-PhysicalNicDetail {
    param([Parameter(Mandatory)]$Hosts)

    foreach ($hostObject in $Hosts) {
        if (-not (Test-HostQueryable -HostObject $hostObject)) {
            Write-Warning ("Skipping physical NIC query for {0}: connection state is {1}." -f $hostObject.Name, $hostObject.ConnectionState)
            continue
        }

        foreach ($nic in (Get-VMHostNetworkAdapter -VMHost $hostObject -Physical | Sort-Object Name)) {
            $link = $nic.ExtensionData.LinkSpeed

            [pscustomobject]@{
                Host       = $hostObject.Name
                Device     = $nic.Name
                Mac        = $nic.Mac
                LinkUp     = $null -ne $link
                SpeedMb    = if ($link) { $link.SpeedMb } else { $null }
                FullDuplex = if ($link) { $link.Duplex } else { $null }
                Driver     = $nic.ExtensionData.Driver
                Pci        = $nic.ExtensionData.Pci
            }
        }
    }
}

function Get-PhysicalNicNeighbor {
    param([Parameter(Mandatory)]$Hosts)

    foreach ($hostObject in $Hosts) {
        if (-not (Test-HostQueryable -HostObject $hostObject)) {
            Write-Warning ("Skipping LLDP/CDP query for {0}: connection state is {1}." -f $hostObject.Name, $hostObject.ConnectionState)
            continue
        }

        $networkSystem = Get-View -Id $hostObject.ExtensionData.ConfigManager.NetworkSystem
        $hints = @($networkSystem.QueryNetworkHint($null))

        foreach ($nic in (Get-VMHostNetworkAdapter -VMHost $hostObject -Physical | Sort-Object Name)) {
            $hint = $hints |
                Where-Object Device -eq $nic.Name |
                Select-Object -First 1

            $link = $nic.ExtensionData.LinkSpeed

            $protocol = 'NONE_DETECTED'
            $systemName = $null
            $deviceId = $null
            $portId = $null
            $managementAddress = $null
            $vlan = $null
            $mtu = $null
            $details = [System.Collections.Generic.List[string]]::new()

            if ($hint -and $hint.ConnectedSwitchPort) {
                $protocol = 'CDP'
                $cdp = $hint.ConnectedSwitchPort
                $systemName = $cdp.DevId
                $deviceId = $cdp.DevId
                $portId = $cdp.PortId
                $managementAddress = $cdp.MgmtAddr
                $vlan = $cdp.Vlan
                $mtu = $cdp.Mtu
            }
            elseif ($hint -and $hint.LldpInfo) {
                $protocol = 'LLDP'
                $lldp = $hint.LldpInfo
                $deviceId = $lldp.ChassisId
                $portId = $lldp.PortId

                foreach ($parameter in @($lldp.Parameter)) {
                    switch -Regex ($parameter.Key) {
                        'System Name' {
                            $systemName = $parameter.Value
                        }

                        'Management Address' {
                            $managementAddress = $parameter.Value
                        }

                        'VLAN' {
                            $vlan = $parameter.Value
                        }

                        'MTU' {
                            $mtu = $parameter.Value
                        }

                        default {
                            $details.Add("$($parameter.Key)=$($parameter.Value)")
                        }
                    }
                }
            }

            [pscustomobject]@{
                Host              = $hostObject.Name
                Pnic              = $nic.Name
                Mac               = $nic.Mac
                LinkUp            = $null -ne $link
                SpeedMb           = if ($link) { $link.SpeedMb } else { $null }
                DiscoveryProtocol = $protocol
                SwitchSystemName  = $systemName
                SwitchDeviceId    = $deviceId
                SwitchPortId      = $portId
                ManagementAddress = $managementAddress
                AdvertisedVlan    = $vlan
                AdvertisedMtu     = $mtu
                AdditionalDetails = ($details -join '; ')
            }
        }
    }
}

function Get-VmkDetail {
    param([Parameter(Mandatory)]$Hosts)

    foreach ($hostObject in $Hosts) {
        if (-not (Test-HostQueryable -HostObject $hostObject)) {
            Write-Warning ("Skipping VMkernel query for {0}: connection state is {1}." -f $hostObject.Name, $hostObject.ConnectionState)
            continue
        }

        foreach ($vmk in (Get-VMHostNetworkAdapter -VMHost $hostObject -VMKernel | Sort-Object Name)) {
            [pscustomobject]@{
                Host           = $hostObject.Name
                Device         = $vmk.Name
                PortGroup      = $vmk.PortGroupName
                IP             = $vmk.IP
                SubnetMask     = $vmk.SubnetMask
                Mtu            = $vmk.Mtu
                VMotionEnabled = $vmk.VMotionEnabled
                VsanEnabled    = $vmk.VsanTrafficEnabled
                Management     = $vmk.ManagementTrafficEnabled
            }
        }
    }
}

function Get-VdsHostMapping {
    param([Parameter(Mandatory)]$Hosts)

    foreach ($hostObject in $Hosts) {
        $networkSystem = Get-View -Id $hostObject.ExtensionData.ConfigManager.NetworkSystem

        foreach ($proxySwitch in @($networkSystem.NetworkInfo.ProxySwitch)) {
            foreach ($pnicSpec in @($proxySwitch.Spec.Backing.PnicSpec)) {
                [pscustomobject]@{
                    Host          = $hostObject.Name
                    DvsName       = $proxySwitch.DvsName
                    DvsUuid       = $proxySwitch.DvsUuid
                    Pnic          = $pnicSpec.PnicDevice
                    UplinkPortKey = $pnicSpec.UplinkPortKey
                }
            }
        }
    }
}

function Get-DistributedPortgroupDetail {
    param([Parameter(Mandatory)][string]$VCenterName)

    foreach ($switch in (Get-VDSwitch -Server $VCenterName | Sort-Object Name)) {
        foreach ($portgroup in (Get-VDPortgroup -VDSwitch $switch | Sort-Object Name)) {
            $defaultPortConfig = $portgroup.ExtensionData.Config.DefaultPortConfig
            $teaming = if ($defaultPortConfig) { $defaultPortConfig.UplinkTeamingPolicy } else { $null }
            $portOrder = if ($teaming) { $teaming.UplinkPortOrder } else { $null }

            [pscustomobject]@{
                VDSwitch      = $switch.Name
                Portgroup     = $portgroup.Name
                Vlan          = ($portgroup.VlanConfiguration | Out-String).Trim()
                NumPorts      = $portgroup.NumPorts
                PortBinding   = $portgroup.PortBinding
                ActiveUplink  = if ($portOrder) { $portOrder.ActiveUplinkPort -join ',' } else { $null }
                StandbyUplink = if ($portOrder) { $portOrder.StandbyUplinkPort -join ',' } else { $null }
                LoadBalance   = if ($teaming -and $teaming.Policy) { $teaming.Policy.Value } else { $null }
            }
        }
    }
}

function Get-VmNetworkInventory {
    param([Parameter(Mandatory)]$Location)

    foreach ($vm in (Get-VM -Location $Location | Sort-Object Name)) {
        foreach ($adapter in (Get-NetworkAdapter -VM $vm)) {
            [pscustomobject]@{
                VM             = $vm.Name
                PowerState     = $vm.PowerState
                Host           = if ($vm.VMHost) { $vm.VMHost.Name } else { $null }
                Adapter        = $adapter.Name
                Type           = $adapter.Type
                MacAddress     = $adapter.MacAddress
                NetworkName    = $adapter.NetworkName
                Connected      = $adapter.ConnectionState.Connected
                StartConnected = $adapter.ConnectionState.StartConnected
            }
        }
    }
}

function Get-RecentCriticalEvents {
    param(
        [Parameter(Mandatory)]$Entity,
        [int]$Hours = 24
    )

    Get-VIEvent -Entity $Entity -Start (Get-Date).AddHours(-$Hours) -MaxSamples 5000 |
        Where-Object {
            $_.GetType().Name -match 'Error|Warning|Failure|Lost|Disconnected|Degraded'
        } |
        Select-Object CreatedTime,
                      @{ Name = 'Type'; Expression = { $_.GetType().Name } },
                      FullFormattedMessage
}

function Get-VsanHealthSafe {
    param([Parameter(Mandatory)]$Cluster)

    if (-not (Get-Command Get-VsanView -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{
            Status = 'UNKNOWN'
            Note   = 'Get-VsanView is unavailable; cannot query vSAN health.'
        }
    }

    try {
        $healthSystem = Get-VsanView -Id 'VsanVcClusterHealthSystem-vsan-cluster-health-system' -ErrorAction Stop
        $summary = $healthSystem.VsanQueryVcClusterHealthSummary(
            $Cluster.ExtensionData.MoRef,   # cluster MoRef
            $null,                           # vmCreateTimeout
            $null,                           # objUuids
            $true,                           # includeObjUuids
            $null,                           # fields
            $null,                           # fetchFromCache
            'defaultView'                    # perspective
        )

        return [pscustomobject]@{
            Status       = $summary.OverallHealth
            HealthGroups = (
                @($summary.Groups) |
                    ForEach-Object { "$($_.GroupName)=$($_.GroupHealth)" }
            ) -join '; '
        }
    }
    catch {
        return [pscustomobject]@{
            Status = 'UNKNOWN'
            Note   = $_.Exception.Message
        }
    }
}

function Get-VsanResyncSafe {
    param([Parameter(Mandatory)]$Cluster)

    if (-not (Get-Command Get-VsanResyncingComponent -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{
            Status = 'UNKNOWN'
            Note   = 'Get-VsanResyncingComponent is unavailable in the installed PowerCLI version.'
        }
    }

    try {
        $components = @(Get-VsanResyncingComponent -Cluster $Cluster -ErrorAction Stop)

        if ($components.Count -eq 0) {
            return [pscustomobject]@{
                Status         = 'NONE'
                ComponentCount = 0
                Note           = 'No components are resyncing.'
            }
        }

        $bytesLeft = ($components | Measure-Object -Property BytesLeftToSync -Sum).Sum

        return [pscustomobject]@{
            Status         = 'RESYNCING'
            ComponentCount = $components.Count
            GBLeftToSync   = [math]::Round((([double]$bytesLeft) / 1GB), 2)
        }
    }
    catch {
        return [pscustomobject]@{
            Status = 'ERROR'
            Note   = $_.Exception.Message
        }
    }
}

function Get-IPv4Network {
    param(
        [string]$IPAddress,
        [string]$SubnetMask
    )

    if ([string]::IsNullOrWhiteSpace($IPAddress) -or [string]::IsNullOrWhiteSpace($SubnetMask)) {
        return $null
    }

    try {
        $ipBytes   = ([System.Net.IPAddress]::Parse($IPAddress)).GetAddressBytes()
        $maskBytes = ([System.Net.IPAddress]::Parse($SubnetMask)).GetAddressBytes()

        $networkBytes = for ($index = 0; $index -lt 4; $index++) {
            $ipBytes[$index] -band $maskBytes[$index]
        }

        return ($networkBytes -join '.')
    }
    catch {
        return $null
    }
}

function Find-PingCount {
    param(
        $InputObject,
        [Parameter(Mandatory)][string[]]$Names,
        [int]$Depth = 0
    )

    if ($null -eq $InputObject -or $Depth -gt 5) {
        return $null
    }

    foreach ($name in $Names) {
        $property = $InputObject.PSObject.Properties[$name]
        if ($property -and "$($property.Value)" -match '^\d+$') {
            return [int]$property.Value
        }
    }

    foreach ($property in $InputObject.PSObject.Properties) {
        $value = $property.Value

        if ($null -eq $value -or $value -is [string] -or $value -is [System.ValueType]) {
            continue
        }

        if ($value -is [System.Collections.IEnumerable]) {
            foreach ($item in $value) {
                $found = Find-PingCount -InputObject $item -Names $Names -Depth ($Depth + 1)
                if ($null -ne $found) {
                    return $found
                }
            }
        }
        else {
            $found = Find-PingCount -InputObject $value -Names $Names -Depth ($Depth + 1)
            if ($null -ne $found) {
                return $found
            }
        }
    }

    return $null
}

function Test-VsanVmkConnectivity {
    param(
        [Parameter(Mandatory)]$SourceHost,
        [Parameter(Mandatory)]$AllHosts,
        [int]$PingCount = 5
    )

    if (-not (Test-HostQueryable -HostObject $SourceHost)) {
        return [pscustomobject]@{
            SourceHost = $SourceHost.Name
            Result     = 'SKIP'
            Detail     = "Source host connection state is $($SourceHost.ConnectionState); vSAN ping test skipped."
        }
    }

    $sourceVmks = @(
        Get-VMHostNetworkAdapter -VMHost $SourceHost -VMKernel |
            Where-Object VsanTrafficEnabled |
            Sort-Object Name
    )

    if ($sourceVmks.Count -eq 0) {
        return [pscustomobject]@{
            SourceHost = $SourceHost.Name
            Result     = 'FAIL'
            Detail     = 'No vSAN VMkernel adapter was found.'
        }
    }

    # Get-EsxCli -V2 is not safe to build in several runspaces at once and
    # null-references under concurrency. Serialise just its creation with the
    # shared mutex. In serial runs the mutex is uncontended, so this costs
    # almost nothing.
    $esxcliMutex = New-Object System.Threading.Mutex($false, 'VcfVxRailValidationViConnect')

    try {
        try {
            [void]$esxcliMutex.WaitOne()
        }
        catch [System.Threading.AbandonedMutexException] {
        }

        try {
            $esxcli = Get-EsxCli -VMHost $SourceHost -V2
        }
        finally {
            $esxcliMutex.ReleaseMutex()
        }
    }
    finally {
        $esxcliMutex.Dispose()
    }

    foreach ($targetHost in ($AllHosts | Where-Object Name -ne $SourceHost.Name)) {
        if (-not (Test-HostQueryable -HostObject $targetHost)) {
            [pscustomobject]@{
                SourceHost = $SourceHost.Name
                TargetHost = $targetHost.Name
                Result     = 'SKIP'
                Detail     = "Target host connection state is $($targetHost.ConnectionState); skipped."
            }

            continue
        }

        $targetVmks = @(
            Get-VMHostNetworkAdapter -VMHost $targetHost -VMKernel |
                Where-Object VsanTrafficEnabled |
                Sort-Object Name
        )

        if ($targetVmks.Count -eq 0) {
            [pscustomobject]@{
                SourceHost = $SourceHost.Name
                TargetHost = $targetHost.Name
                Result     = 'FAIL'
                Detail     = 'Target host has no vSAN VMkernel adapter.'
            }

            continue
        }

        # Pair a source and target vSAN VMkernel that share an IP subnet.
        # When more than one vSAN subnet is present (for example a stretched
        # cluster), pinging across subnets tests a path that is not expected
        # to succeed and would report a misleading failure.
        $sourceVmk  = $null
        $targetVmk  = $null
        $sameSubnet = $false

        foreach ($candidateSource in $sourceVmks) {
            $sourceNetwork = Get-IPv4Network -IPAddress $candidateSource.IP -SubnetMask $candidateSource.SubnetMask

            if ($null -eq $sourceNetwork) {
                continue
            }

            $candidateTarget = $targetVmks |
                Where-Object {
                    (Get-IPv4Network -IPAddress $_.IP -SubnetMask $_.SubnetMask) -eq $sourceNetwork
                } |
                Select-Object -First 1

            if ($candidateTarget) {
                $sourceVmk  = $candidateSource
                $targetVmk  = $candidateTarget
                $sameSubnet = $true
                break
            }
        }

        if (-not $sourceVmk) {
            $sourceVmk = $sourceVmks[0]
            $targetVmk = $targetVmks[0]
        }

        $arguments = $esxcli.network.diag.ping.CreateArgs()
        $arguments.host = $targetVmk.IP
        $arguments.interface = $sourceVmk.Name
        $arguments.count = $PingCount
        $arguments.size = 1472

        # Only override the netstack when the vSAN VMkernel is on a non-default
        # stack. Forcing the default stack name here can make the esxcli ping
        # behave differently from a manual "vmkping -I vmkX", which uses the
        # interface's own stack.
        $netstackKey = $sourceVmk.ExtensionData.Spec.NetStackInstanceKey
        if ($netstackKey -and $netstackKey -ne 'defaultTcpipStack') {
            try {
                if ($arguments.ContainsKey('netstack')) {
                    $arguments.netstack = $netstackKey
                }
            }
            catch {
                # esxcli argument set does not expose netstack on this build; ignore.
            }
        }

        try {
            $result = $esxcli.network.diag.ping.Invoke($arguments)

            # Read the packet counts from wherever this build placed them.
            # esxcli returns them under Summary on some builds, at the top
            # level on others, and occasionally inside a nested array, so the
            # whole result graph is searched. VMware spells the received field
            # "Recieved" on many builds.
            $transmitted = Find-PingCount -InputObject $result -Names @('Transmitted', 'Trasmitted', 'Sent')
            $received    = Find-PingCount -InputObject $result -Names @('Recieved', 'Received')

            if ($null -ne $transmitted -and $null -ne $received -and $transmitted -gt 0) {
                $lossPercent = [math]::Round((1 - ($received / $transmitted)) * 100, 2)
                $pingResult  = if ($lossPercent -eq 0) { 'PASS' } else { 'FAIL' }

                $pingDetail = if (-not $sameSubnet) {
                    "Src=$($sourceVmk.Name)($($sourceVmk.IP)) -> $($targetHost.Name)($($targetVmk.IP)); " +
                    "Sent=$transmitted; Recv=$received; Loss=$lossPercent%; " +
                    "NOTE=source and target vSAN VMkernel are on different subnets"
                }
                else {
                    $null
                }
            }
            else {
                # The ping ran without throwing, but its counts could not be
                # read on this build. This is not evidence of a failure - a
                # working path would be flagged wrongly - so surface it for a
                # manual check instead of reporting a loss.
                $transmitted = if ($null -ne $transmitted) { $transmitted } else { 0 }
                $received    = if ($null -ne $received) { $received } else { 0 }
                $lossPercent = $null
                $pingResult  = 'INFO'
                $pingDetail  = "Src=$($sourceVmk.Name)($($sourceVmk.IP)) -> $($targetHost.Name)($($targetVmk.IP)); " +
                    "ping ran but packet counts could not be read on this PowerCLI build; " +
                    "verify by hand: vmkping -I $($sourceVmk.Name) $($targetVmk.IP)"
            }

            [pscustomobject]@{
                SourceHost  = $SourceHost.Name
                SourceVmk   = $sourceVmk.Name
                SourceIP    = $sourceVmk.IP
                TargetHost  = $targetHost.Name
                TargetIP    = $targetVmk.IP
                Received    = $received
                Transmitted = $transmitted
                LossPercent = $lossPercent
                Result      = $pingResult
                Detail      = $pingDetail
            }
        }
        catch {
            [pscustomobject]@{
                SourceHost = $SourceHost.Name
                SourceVmk  = $sourceVmk.Name
                SourceIP   = $sourceVmk.IP
                TargetHost = $targetHost.Name
                TargetIP   = $targetVmk.IP
                Result     = 'ERROR'
                Detail     = $_.Exception.Message
            }
        }
    }
}

function Test-VmkJumboConnectivity {
    # Don't-fragment, jumbo-sized vmkping between same-subnet VMkernel peers,
    # per traffic type. This is the check the DC-migration runbook asks for
    # ("vmkping -I vmkX -d -s 8972 host to host, per VMkernel network"): a
    # standard-MTU ping proves reachability but not that the path carries the
    # full jumbo frame unfragmented. vSAN and vMotion are matched by their
    # adapter flags; host TEP (overlay) is matched by netstack name as a
    # best-effort - confirm any TEP result by hand. Edge TEP lives on edge
    # transport nodes, not ESXi hosts, so it is out of scope here.
    param(
        [Parameter(Mandatory)]$SourceHost,
        [Parameter(Mandatory)]$AllHosts,
        [int]$Size = 8972,
        [bool]$DontFragment = $true,
        [int]$PingCount = 3
    )

    if (-not (Test-HostQueryable -HostObject $SourceHost)) {
        return [pscustomobject]@{
            TrafficType = 'ALL'
            SourceHost  = $SourceHost.Name
            TargetHost  = $null
            Result      = 'SKIP'
            Detail      = "Source host connection state is $($SourceHost.ConnectionState); jumbo ping test skipped."
        }
    }

    $trafficTypes = @(
        [pscustomobject]@{
            Name  = 'vSAN'
            Match = { param($vmk) [bool]$vmk.VsanTrafficEnabled }
        }
        [pscustomobject]@{
            Name  = 'vMotion'
            Match = { param($vmk) [bool]$vmk.VMotionEnabled }
        }
        [pscustomobject]@{
            Name  = 'hostTEP'
            Match = {
                param($vmk)
                $stack = $vmk.ExtensionData.Spec.NetStackInstanceKey
                [bool]($stack -and ($stack -match 'vxlan|overlay'))
            }
        }
    )

    # Get-EsxCli -V2 is not safe to build in several runspaces at once, so
    # serialise its creation with the shared mutex (uncontended in serial runs).
    $esxcliMutex = New-Object System.Threading.Mutex($false, 'VcfVxRailValidationViConnect')

    try {
        try {
            [void]$esxcliMutex.WaitOne()
        }
        catch [System.Threading.AbandonedMutexException] {
        }

        try {
            $esxcli = Get-EsxCli -VMHost $SourceHost -V2
        }
        finally {
            $esxcliMutex.ReleaseMutex()
        }
    }
    finally {
        $esxcliMutex.Dispose()
    }

    foreach ($trafficType in $trafficTypes) {
        $sourceVmks = @(
            Get-VMHostNetworkAdapter -VMHost $SourceHost -VMKernel |
                Where-Object { & $trafficType.Match $_ } |
                Sort-Object Name
        )

        if ($sourceVmks.Count -eq 0) {
            # This traffic type is not present on the source host; skip quietly.
            continue
        }

        foreach ($targetHost in ($AllHosts | Where-Object Name -ne $SourceHost.Name)) {
            if (-not (Test-HostQueryable -HostObject $targetHost)) {
                [pscustomobject]@{
                    TrafficType = $trafficType.Name
                    SourceHost  = $SourceHost.Name
                    SourceVmk   = $null
                    SourceIP    = $null
                    TargetHost  = $targetHost.Name
                    TargetIP    = $null
                    Size        = $Size
                    Result      = 'SKIP'
                    Detail      = "Target host connection state is $($targetHost.ConnectionState); skipped."
                }

                continue
            }

            $targetVmks = @(
                Get-VMHostNetworkAdapter -VMHost $targetHost -VMKernel |
                    Where-Object { & $trafficType.Match $_ } |
                    Sort-Object Name
            )

            if ($targetVmks.Count -eq 0) {
                [pscustomobject]@{
                    TrafficType = $trafficType.Name
                    SourceHost  = $SourceHost.Name
                    SourceVmk   = $null
                    SourceIP    = $null
                    TargetHost  = $targetHost.Name
                    TargetIP    = $null
                    Size        = $Size
                    DF          = $false
                    Received    = 0
                    Transmitted = 0
                    LossPercent = $null
                    Result      = 'INFO'
                    Detail      = "Target host has no $($trafficType.Name) VMkernel adapter; nothing to test."
                }

                continue
            }

            # Pair a source and target VMkernel that share an IP subnet, so a
            # stretched cluster's second subnet is not pinged across a path that
            # is not expected to work.
            $sourceVmk  = $null
            $targetVmk  = $null
            $sameSubnet = $false

            foreach ($candidateSource in $sourceVmks) {
                $sourceNetwork = Get-IPv4Network -IPAddress $candidateSource.IP -SubnetMask $candidateSource.SubnetMask

                if ($null -eq $sourceNetwork) {
                    continue
                }

                $candidateTarget = $targetVmks |
                    Where-Object {
                        (Get-IPv4Network -IPAddress $_.IP -SubnetMask $_.SubnetMask) -eq $sourceNetwork
                    } |
                    Select-Object -First 1

                if ($candidateTarget) {
                    $sourceVmk  = $candidateSource
                    $targetVmk  = $candidateTarget
                    $sameSubnet = $true
                    break
                }
            }

            if (-not $sourceVmk) {
                $sourceVmk = $sourceVmks[0]
                $targetVmk = $targetVmks[0]
            }

            $arguments = $esxcli.network.diag.ping.CreateArgs()
            $arguments.host      = $targetVmk.IP
            $arguments.interface = $sourceVmk.Name
            $arguments.count     = $PingCount
            $arguments.size      = $Size

            $dfApplied = $false
            if ($arguments.ContainsKey('df')) {
                try {
                    $arguments.df = $DontFragment
                    $dfApplied = [bool]$DontFragment
                }
                catch {
                    # This esxcli build does not accept the df argument; leave it.
                }
            }

            $netstackKey = $sourceVmk.ExtensionData.Spec.NetStackInstanceKey
            if ($netstackKey -and $netstackKey -ne 'defaultTcpipStack' -and $arguments.ContainsKey('netstack')) {
                try {
                    $arguments.netstack = $netstackKey
                }
                catch {
                    # esxcli argument set does not expose netstack on this build; ignore.
                }
            }

            try {
                $result = $esxcli.network.diag.ping.Invoke($arguments)

                $transmitted = Find-PingCount -InputObject $result -Names @('Transmitted', 'Trasmitted', 'Sent')
                $received    = Find-PingCount -InputObject $result -Names @('Recieved', 'Received')

                $subnetNote = if (-not $sameSubnet) {
                    ' NOTE=source and target are on different subnets'
                }
                else {
                    ''
                }

                if ($null -ne $transmitted -and $null -ne $received -and $transmitted -gt 0) {
                    $lossPercent = [math]::Round((1 - ($received / $transmitted)) * 100, 2)

                    if ($lossPercent -eq 0 -and $dfApplied) {
                        $pingResult = 'PASS'
                        $pingNote   = "jumbo frame ($Size B, DF set) passed"
                    }
                    elseif ($lossPercent -eq 0 -and -not $dfApplied) {
                        $pingResult = 'INFO'
                        $pingNote   = "sent $Size B but this build would not set don't-fragment, so an unfragmented jumbo path is not proven; verify by hand"
                    }
                    else {
                        $pingResult = 'FAIL'
                        $pingNote   = "loss with DF set means the path does not carry $Size B unfragmented (MTU or VLAN issue)"
                    }

                    $pingDetail = "Src=$($sourceVmk.Name)($($sourceVmk.IP)) -> $($targetHost.Name)($($targetVmk.IP)); " +
                        "Sent=$transmitted; Recv=$received; Loss=$lossPercent%; DF=$dfApplied; Size=$Size; $pingNote.$subnetNote"
                }
                else {
                    $transmitted = if ($null -ne $transmitted) { $transmitted } else { 0 }
                    $received    = if ($null -ne $received) { $received } else { 0 }
                    $lossPercent = $null
                    $pingResult  = 'INFO'
                    $pingDetail  = "Src=$($sourceVmk.Name)($($sourceVmk.IP)) -> $($targetHost.Name)($($targetVmk.IP)); " +
                        "ping ran but packet counts could not be read on this PowerCLI build; " +
                        "verify by hand: vmkping -I $($sourceVmk.Name) -d -s $Size $($targetVmk.IP).$subnetNote"
                }

                [pscustomobject]@{
                    TrafficType = $trafficType.Name
                    SourceHost  = $SourceHost.Name
                    SourceVmk   = $sourceVmk.Name
                    SourceIP    = $sourceVmk.IP
                    TargetHost  = $targetHost.Name
                    TargetIP    = $targetVmk.IP
                    Size        = $Size
                    DF          = $dfApplied
                    Received    = $received
                    Transmitted = $transmitted
                    LossPercent = $lossPercent
                    Result      = $pingResult
                    Detail      = $pingDetail
                }
            }
            catch {
                [pscustomobject]@{
                    TrafficType = $trafficType.Name
                    SourceHost  = $SourceHost.Name
                    SourceVmk   = $sourceVmk.Name
                    SourceIP    = $sourceVmk.IP
                    TargetHost  = $targetHost.Name
                    TargetIP    = $targetVmk.IP
                    Size        = $Size
                    DF          = $dfApplied
                    Received    = 0
                    Transmitted = 0
                    LossPercent = $null
                    Result      = 'ERROR'
                    Detail      = $_.Exception.Message
                }
            }
        }
    }
}

function Get-VMHostCertExpirySafe {
    param(
        [Parameter(Mandatory)]$HostObject,
        [int]$WarnDays = 60
    )

    if (-not (Get-Command Get-VIMachineCertificate -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{
            Result = 'INFO'
            Detail = 'Get-VIMachineCertificate is unavailable in this PowerCLI build; check the host SSL certificate expiry by hand.'
        }
    }

    try {
        $certs = @(Get-VIMachineCertificate -VMHost $HostObject -ErrorAction Stop)

        if ($certs.Count -eq 0) {
            return [pscustomobject]@{
                Result = 'INFO'
                Detail = 'No host certificate was returned.'
            }
        }

        $soonest = $null

        foreach ($cert in $certs) {
            $notAfter = $null

            foreach ($propertyName in @('NotValidAfter', 'NotAfter')) {
                if ($cert.PSObject.Properties[$propertyName] -and $cert.$propertyName) {
                    try {
                        $notAfter = [datetime]$cert.$propertyName
                    }
                    catch {
                        $notAfter = $null
                    }

                    if ($notAfter) {
                        break
                    }
                }
            }

            if (-not $notAfter -and $cert.PSObject.Properties['Certificate'] -and $cert.Certificate) {
                try {
                    $notAfter = [datetime]$cert.Certificate.NotAfter
                }
                catch {
                    $notAfter = $null
                }
            }

            if ($notAfter -and (($null -eq $soonest) -or ($notAfter -lt $soonest))) {
                $soonest = $notAfter
            }
        }

        if ($null -eq $soonest) {
            return [pscustomobject]@{
                Result = 'INFO'
                Detail = 'A host certificate was returned but no expiry date could be read from it.'
            }
        }

        $daysLeft = [math]::Round(($soonest - (Get-Date)).TotalDays, 1)

        $result = if ($daysLeft -lt 0) {
            'FAIL'
        }
        elseif ($daysLeft -le $WarnDays) {
            'WARN'
        }
        else {
            'PASS'
        }

        return [pscustomobject]@{
            Result = $result
            Detail = "Host SSL certificate expires $($soonest.ToString('yyyy-MM-dd')) (in $daysLeft days); warn threshold is $WarnDays days. Covers the ESXi host machine certificate only, not vCenter, NSX, SDDC Manager, or service-account passwords."
        }
    }
    catch {
        return [pscustomobject]@{
            Result = 'INFO'
            Detail = "Could not read the host certificate: $($_.Exception.Message)"
        }
    }
}

function Get-VsanClusterPostureSafe {
    param([Parameter(Mandatory)]$Cluster)

    if (-not (Get-Command Get-VsanClusterConfiguration -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{
            Result = 'INFO'
            Detail = 'Get-VsanClusterConfiguration is unavailable; confirm dedupe/compression and encryption status by hand.'
        }
    }

    try {
        $configuration = Get-VsanClusterConfiguration -Cluster $Cluster -ErrorAction Stop

        $spaceEfficiency = if ($configuration.PSObject.Properties['SpaceEfficiencyEnabled']) {
            $configuration.SpaceEfficiencyEnabled
        }
        else {
            'unknown'
        }

        $encryption = if ($configuration.PSObject.Properties['EncryptionEnabled']) {
            $configuration.EncryptionEnabled
        }
        else {
            'unknown'
        }

        $kms = if ($configuration.PSObject.Properties['KmsCluster'] -and $configuration.KmsCluster) {
            [string]$configuration.KmsCluster
        }
        else {
            $null
        }

        $detail = "Dedupe/compression=$spaceEfficiency; encryption=$encryption"

        if ($kms) {
            $detail += "; KMS=$kms"
        }

        $detail += '. Dedupe/compression lengthens data evacuation; if encryption is on, confirm the KMS is reachable from the new site.'

        return [pscustomobject]@{
            Result = 'INFO'
            Detail = $detail
        }
    }
    catch {
        return [pscustomobject]@{
            Result = 'INFO'
            Detail = "Could not read the vSAN cluster configuration: $($_.Exception.Message)"
        }
    }
}

function Get-VsanCapacitySafe {
    param(
        [Parameter(Mandatory)]$Cluster,
        [Parameter(Mandatory)][int]$HostCount,
        [double]$SafetyFactor = 1.25
    )

    try {
        $datastores = @(
            Get-Datastore -RelatedObject $Cluster -ErrorAction Stop |
                Where-Object { $_.Type -eq 'vsan' }
        )

        if ($datastores.Count -eq 0) {
            return [pscustomobject]@{
                Result = 'INFO'
                Detail = 'No vSAN datastore was found for this cluster.'
            }
        }

        $vsanDatastore = $datastores | Select-Object -First 1
        $capacityGB    = [double]$vsanDatastore.CapacityGB
        $freeGB        = [double]$vsanDatastore.FreeSpaceGB

        if ($capacityGB -le 0 -or $HostCount -le 1) {
            return [pscustomobject]@{
                Result = 'INFO'
                Detail = "vSAN capacity=$([math]::Round($capacityGB, 1))GB, free=$([math]::Round($freeGB, 1))GB, hosts=$HostCount; not enough to estimate N-1 headroom."
            }
        }

        $usedGB       = $capacityGB - $freeGB
        $usedPercent  = [math]::Round(($usedGB / $capacityGB) * 100, 1)
        $perHostShare = [math]::Round($capacityGB / $HostCount, 1)
        $requiredFree = [math]::Round($perHostShare * $SafetyFactor, 1)

        $result  = if ($freeGB -ge $requiredFree) { 'INFO' } else { 'WARN' }
        $verdict = if ($freeGB -ge $requiredFree) { 'above' } else { 'BELOW' }

        $detail = "vSAN used $usedPercent% (used $([math]::Round($usedGB, 1))GB of $([math]::Round($capacityGB, 1))GB, free $([math]::Round($freeGB, 1))GB). " +
            "Rough N-1 estimate: one host's share ~$perHostShare GB x $SafetyFactor = $requiredFree GB free needed to evacuate a host; free space is $verdict that. " +
            "Estimate only - dedupe/compression and uneven component layout change the real figure; confirm with a vSAN full-data-migration simulation."

        return [pscustomobject]@{
            Result = $result
            Detail = $detail
        }
    }
    catch {
        return [pscustomobject]@{
            Result = 'INFO'
            Detail = "Could not read vSAN capacity: $($_.Exception.Message)"
        }
    }
}

function Compare-CsvFile {
    param(
        [Parameter(Mandatory)][string]$BaselineFile,
        [Parameter(Mandatory)][string]$CurrentFile,
        [Parameter(Mandatory)][string[]]$KeyProperties,
        [Parameter(Mandatory)][string[]]$CompareProperties
    )

    if (-not (Test-Path $BaselineFile)) {
        return [pscustomobject]@{
            Result     = 'WARN'
            Object     = 'File'
            Key        = $BaselineFile
            Difference = 'Baseline file was not found.'
        }
    }

    if (-not (Test-Path $CurrentFile)) {
        return [pscustomobject]@{
            Result     = 'WARN'
            Object     = 'File'
            Key        = $CurrentFile
            Difference = 'Current file was not found.'
        }
    }

    $baseline = Import-Csv $BaselineFile
    $current = Import-Csv $CurrentFile
    $results = [System.Collections.Generic.List[object]]::new()

    foreach ($item in $current) {
        $match = $baseline |
            Where-Object {
                $candidate = $_
                -not ($KeyProperties |
                    Where-Object { $candidate.$_ -ne $item.$_ })
            } |
            Select-Object -First 1

        $key = (
            $KeyProperties |
            ForEach-Object { "$_=$($item.$_)" }
        ) -join '; '

        if (-not $match) {
            $results.Add([pscustomobject]@{
                Result     = 'FAIL'
                Object     = 'Missing baseline match'
                Key        = $key
                Difference = 'The current object does not match any baseline record.'
            })

            continue
        }

        foreach ($property in $CompareProperties) {
            if ($match.$property -ne $item.$property) {
                $results.Add([pscustomobject]@{
                    Result     = 'FAIL'
                    Object     = $property
                    Key        = $key
                    Difference = "Expected='$($match.$property)' Actual='$($item.$property)'"
                })
            }
        }
    }

    if ($results.Count -eq 0) {
        $results.Add([pscustomobject]@{
            Result     = 'PASS'
            Object     = 'Comparison'
            Key        = ($KeyProperties -join ',')
            Difference = 'No differences were detected.'
        })
    }

    return $results
}

function Write-HtmlReport {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)]$Checks,
        [Parameter(Mandatory)][string]$Path
    )

    $rows = foreach ($check in $Checks) {
        $class = switch ($check.Result) {
            'PASS' { 'pass' }
            'FAIL' { 'fail' }
            'ERROR' { 'fail' }
            'INFO' { 'info' }
            default { 'warn' }
        }

        $resultCell = [System.Net.WebUtility]::HtmlEncode([string]$check.Result)
        $checkCell  = [System.Net.WebUtility]::HtmlEncode([string]$check.Check)
        $detailCell = [System.Net.WebUtility]::HtmlEncode([string]$check.Detail)

        "<tr class='$class'><td>$resultCell</td><td>$checkCell</td><td>$detailCell</td></tr>"
    }

    $titleEncoded = [System.Net.WebUtility]::HtmlEncode([string]$Title)

    $overall = if ($Checks.Result -contains 'FAIL' -or $Checks.Result -contains 'ERROR') {
        'NOT READY'
    }
    elseif ($Checks.Result -contains 'WARN' -or $Checks.Result -contains 'REVIEW') {
        'READY WITH WARNINGS'
    }
    else {
        'READY'
    }

    $html = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>$titleEncoded</title>
<style>
body { font-family: Arial, sans-serif; margin: 30px; }
h1 { margin-bottom: 5px; }
.summary { font-size: 1.1em; margin-top: 8px; }
.overall { font-size: 1.3em; font-weight: bold; margin-top: 14px; }
table { border-collapse: collapse; width: 100%; margin-top: 20px; }
th, td { border: 1px solid #cccccc; padding: 8px; text-align: left; }
.pass { background: #e8f5e9; }
.warn { background: #fff8e1; }
.fail { background: #ffebee; }
.info { background: #eceff1; }
</style>
</head>
<body>
<h1>$titleEncoded</h1>
<div class="summary">Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</div>
<div class="overall">Overall result: $overall</div>
<table>
<thead>
<tr><th>Result</th><th>Check</th><th>Detail</th></tr>
</thead>
<tbody>
$($rows -join "`n")
</tbody>
</table>
</body>
</html>
"@

    Set-Content -Path $Path -Value $html -Encoding UTF8
}

function Write-RunSummaryHtml {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$VCenter,
        [Parameter(Mandatory)][string]$Cluster,
        [Parameter(Mandatory)][string]$Mode,
        $VsanHealth,
        $VsanResync,
        [int]$PortgroupCount,
        [int]$EventCount,
        [Parameter(Mandatory)]$HostRollups
    )

    $healthStatus = if ($VsanHealth) { [string]$VsanHealth.Status } else { 'n/a' }
    $resyncStatus = if ($VsanResync) { [string]$VsanResync.Status } else { 'n/a' }

    $rows = foreach ($item in $HostRollups) {
        $class = switch ($item.Overall) {
            'NOT READY'           { 'fail' }
            'READY WITH WARNINGS' { 'warn' }
            default               { 'pass' }
        }

        $hostCell = [System.Net.WebUtility]::HtmlEncode([string]$item.Host)
        $href = [System.Net.WebUtility]::HtmlEncode([string]$item.ReportRelative)
        $overallCell = [System.Net.WebUtility]::HtmlEncode([string]$item.Overall)

        "<tr class='$class'>" +
        "<td><a href='$href'>$hostCell</a></td>" +
        "<td>$overallCell</td>" +
        "<td>$($item.Pass)</td>" +
        "<td>$($item.Warn)</td>" +
        "<td>$($item.Fail)</td>" +
        "</tr>"
    }

    $overall = if (@($HostRollups | Where-Object { $_.Overall -eq 'NOT READY' }).Count -gt 0) {
        'NOT READY'
    }
    elseif (@($HostRollups | Where-Object { $_.Overall -eq 'READY WITH WARNINGS' }).Count -gt 0) {
        'READY WITH WARNINGS'
    }
    else {
        'READY'
    }

    $clusterEnc = [System.Net.WebUtility]::HtmlEncode($Cluster)
    $vcEnc      = [System.Net.WebUtility]::HtmlEncode($VCenter)
    $modeEnc    = [System.Net.WebUtility]::HtmlEncode($Mode)
    $healthEnc  = [System.Net.WebUtility]::HtmlEncode($healthStatus)
    $resyncEnc  = [System.Net.WebUtility]::HtmlEncode($resyncStatus)

    $html = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>$clusterEnc - $modeEnc - validation summary</title>
<style>
body { font-family: Arial, sans-serif; margin: 30px; }
h1 { margin-bottom: 5px; }
.meta { color: #555; margin-bottom: 4px; }
.overall { font-size: 1.3em; font-weight: bold; margin: 16px 0; }
table { border-collapse: collapse; width: 100%; margin-top: 16px; }
th, td { border: 1px solid #cccccc; padding: 8px; text-align: left; }
.pass { background: #e8f5e9; }
.warn { background: #fff8e1; }
.fail { background: #ffebee; }
a { text-decoration: none; color: #1565c0; }
</style>
</head>
<body>
<h1>$clusterEnc</h1>
<div class="meta">vCenter: $vcEnc</div>
<div class="meta">Mode: $modeEnc</div>
<div class="meta">Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</div>
<div class="overall">Overall: $overall</div>

<table>
<tr><th>Cluster item</th><th>Value</th></tr>
<tr><td>vSAN health</td><td>$healthEnc</td></tr>
<tr><td>vSAN resync</td><td>$resyncEnc</td></tr>
<tr><td>Distributed port groups</td><td>$PortgroupCount</td></tr>
<tr><td>Recent warnings/errors (24h)</td><td>$EventCount</td></tr>
</table>

<table>
<thead>
<tr><th>Host</th><th>Status</th><th>Pass</th><th>Warn</th><th>Fail</th></tr>
</thead>
<tbody>
$($rows -join "`n")
</tbody>
</table>
</body>
</html>
"@

    Set-Content -Path $Path -Value $html -Encoding UTF8
}

function Export-HostEvidence {
    param(
        [Parameter(Mandatory)]$HostObject,
        [Parameter(Mandatory)]$RunContext
    )

    $hostSafe = ConvertTo-SafeFileName $HostObject.Name
    $folder = Join-Path $RunContext.HostsFolder $hostSafe
    New-Item -ItemType Directory -Path $folder -Force | Out-Null

    Get-HostSummary -Hosts @($HostObject) |
        Export-CsvSafe -Path (Join-Path $folder 'Host-Summary.csv')

    Get-PhysicalNicDetail -Hosts @($HostObject) |
        Export-CsvSafe -Path (Join-Path $folder 'Physical-NICs.csv')

    Get-PhysicalNicNeighbor -Hosts @($HostObject) |
        Export-CsvSafe -Path (Join-Path $folder 'LLDP-CDP.csv')

    Get-VmkDetail -Hosts @($HostObject) |
        Export-CsvSafe -Path (Join-Path $folder 'VMkernel.csv')

    Get-VdsHostMapping -Hosts @($HostObject) |
        Export-CsvSafe -Path (Join-Path $folder 'VDS-Uplinks.csv')

    Get-VmNetworkInventory -Location $HostObject |
        Export-CsvSafe -Path (Join-Path $folder 'VM-Networks.csv')

    return $folder
}

function Get-VsanStretchedFaultDomainSafe {
    # Stretched-cluster preferred fault domain and witness, for the management
    # cluster. Returns Result='SKIP' on a non-stretched cluster so the caller
    # can omit the row on workload clusters.
    param([Parameter(Mandatory)]$Cluster)

    if (-not (Get-Command Get-VsanClusterConfiguration -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{
            Result = 'INFO'
            Detail = 'Get-VsanClusterConfiguration is unavailable; confirm preferred fault domain and witness placement by hand.'
        }
    }

    try {
        $configuration = Get-VsanClusterConfiguration -Cluster $Cluster -ErrorAction Stop

        $stretched = if ($configuration.PSObject.Properties['StretchedClusterEnabled']) {
            [bool]$configuration.StretchedClusterEnabled
        }
        else {
            $false
        }

        if (-not $stretched) {
            return [pscustomobject]@{
                Result = 'SKIP'
                Detail = 'Not a stretched cluster.'
            }
        }

        $preferred = if ($configuration.PSObject.Properties['PreferredFaultDomain'] -and $configuration.PreferredFaultDomain) {
            [string]$configuration.PreferredFaultDomain
        }
        else {
            'unknown'
        }

        $witness = if ($configuration.PSObject.Properties['WitnessHost'] -and $configuration.WitnessHost) {
            $configuration.WitnessHost
        }
        else {
            $null
        }

        $witnessName = if ($witness -and $witness.PSObject.Properties['Name'] -and $witness.Name) {
            [string]$witness.Name
        }
        else {
            'unknown'
        }

        $witnessState = if ($witness -and $witness.PSObject.Properties['ConnectionState'] -and $witness.ConnectionState) {
            [string]$witness.ConnectionState
        }
        else {
            'unknown'
        }

        $result = if ($witness -and $witnessState -ne 'Connected' -and $witnessState -ne 'unknown') {
            'WARN'
        }
        else {
            'INFO'
        }

        return [pscustomobject]@{
            Result = $result
            Detail = "Stretched cluster: preferred fault domain=$preferred; witness=$witnessName (state=$witnessState). Confirm the witness runs outside the migrating site and that the preferred site is where you intend for the move."
        }
    }
    catch {
        return [pscustomobject]@{
            Result = 'INFO'
            Detail = "Could not read stretched-cluster configuration: $($_.Exception.Message)"
        }
    }
}

function Get-VsanRepairTimerSafe {
    # Current vSAN object repair timer (VSAN.ClomRepairDelay, in minutes). The
    # migration runbook may extend this from the 60-minute default for the move
    # and revert it after; this row lets you confirm the current value.
    param([Parameter(Mandatory)]$HostObject)

    try {
        $setting = Get-AdvancedSetting `
            -Entity $HostObject `
            -Name 'VSAN.ClomRepairDelay' `
            -ErrorAction Stop |
            Select-Object -First 1

        if (-not $setting) {
            return [pscustomobject]@{
                Result = 'INFO'
                Detail = 'VSAN.ClomRepairDelay was not found on this host.'
            }
        }

        return [pscustomobject]@{
            Result = 'INFO'
            Detail = "vSAN object repair timer (VSAN.ClomRepairDelay) = $([string]$setting.Value) minutes. Default is 60; if it was extended for the move, confirm it is reverted afterwards."
        }
    }
    catch {
        return [pscustomobject]@{
            Result = 'INFO'
            Detail = "Could not read VSAN.ClomRepairDelay: $($_.Exception.Message)"
        }
    }
}

function Get-VMHostActiveTasks {
    # Running and recently failed vCenter tasks for a host, so a "connected /
    # yellow" host also shows what it is actually doing - entering maintenance,
    # a vSAN reconfigure, a health remediation, a vMotion, and so on.
    param(
        [Parameter(Mandatory)]$View
    )

    $tasks = [System.Collections.Generic.List[object]]::new()

    if (-not $View.RecentTask) {
        return $tasks
    }

    foreach ($taskRef in @($View.RecentTask)) {
        try {
            $taskView = Get-View -Id $taskRef -ErrorAction Stop
            $info = $taskView.Info

            $name = if ($info.PSObject.Properties['DescriptionId'] -and $info.DescriptionId) {
                [string]$info.DescriptionId
            }
            elseif ($info.PSObject.Properties['EntityName'] -and $info.EntityName) {
                [string]$info.EntityName
            }
            else {
                'task'
            }

            $progress = if ($info.PSObject.Properties['Progress'] -and $null -ne $info.Progress) {
                [string]$info.Progress
            }
            else {
                $null
            }

            $errorMessage = if ($info.Error -and $info.Error.LocalizedMessage) {
                [string]$info.Error.LocalizedMessage
            }
            else {
                $null
            }

            $tasks.Add([pscustomobject]@{
                Name     = $name
                State    = [string]$info.State
                Progress = $progress
                Error    = $errorMessage
            })
        }
        catch {
            # Task view could not be resolved (already cleared, or a permissions
            # edge); skip it rather than fail the host.
        }
    }

    return $tasks
}

function Get-HostChecks {
    param(
        [Parameter(Mandatory)]$TargetHost,
        [Parameter(Mandatory)]$Cluster,
        [Parameter(Mandatory)]$AllHosts,
        $VsanResync
    )

    $checks = [System.Collections.Generic.List[object]]::new()
    $view = Get-View -Id $TargetHost.Id

    # Optional-check tunables. Read the script-level values when present (serial
    # runs) and fall back to defaults otherwise: parallel worker runspaces do
    # not inherit them. -ErrorAction keeps this StrictMode-safe.
    $jumboSize = Get-Variable -Name JumboFrameSize     -ValueOnly -ErrorAction SilentlyContinue
    $certWarn  = Get-Variable -Name CertExpiryWarnDays -ValueOnly -ErrorAction SilentlyContinue
    $n1Factor  = Get-Variable -Name VsanN1SafetyFactor -ValueOnly -ErrorAction SilentlyContinue
    if ($null -eq $jumboSize) { $jumboSize = 8972 }
    if ($null -eq $certWarn)  { $certWarn  = 60 }
    if ($null -eq $n1Factor)  { $n1Factor  = 1.25 }

    # Physical NICs that are actually assigned as distributed switch uplinks.
    # A NIC that is down but not an uplink is a spare and is not a fault.
    $uplinkPnics = @(
        Get-VdsHostMapping -Hosts @($TargetHost) |
            Select-Object -ExpandProperty Pnic -Unique
    )

    $checks.Add([pscustomobject]@{
        Check  = 'vCenter connection'
        Result = if ($TargetHost.ConnectionState -eq 'Connected') { 'PASS' } else { 'FAIL' }
        Detail = $TargetHost.ConnectionState
    })

    $checks.Add([pscustomobject]@{
        Check  = 'Host power state'
        Result = if ($TargetHost.PowerState -eq 'PoweredOn') { 'PASS' } else { 'FAIL' }
        Detail = $TargetHost.PowerState
    })

    $overallStatus = [string]$view.OverallStatus

    $statusReasons = [System.Collections.Generic.List[string]]::new()

    if ($view.TriggeredAlarmState) {
        foreach ($alarmState in $view.TriggeredAlarmState) {
            if ($null -eq $alarmState -or $alarmState.OverallStatus -eq 'green') {
                continue
            }

            $alarmName = try {
                (Get-View -Id $alarmState.Alarm).Info.Name
            }
            catch {
                'unknown alarm'
            }

            $statusReasons.Add("alarm [$($alarmState.OverallStatus)]: $alarmName")
        }
    }

    if ($view.ConfigIssue) {
        foreach ($issue in $view.ConfigIssue) {
            if ($issue -and $issue.FullFormattedMessage) {
                $statusReasons.Add("config issue: $($issue.FullFormattedMessage)")
            }
        }
    }

    # Hardware health sensors are a common reason a host is yellow/red with no
    # alarm text (failed PSU, fan, memory, temperature, and so on). Surface any
    # non-green numeric sensor so the status carries its own explanation.
    if ($view.Runtime -and
        $view.Runtime.HealthSystemRuntime -and
        $view.Runtime.HealthSystemRuntime.SystemHealthInfo) {

        foreach ($sensor in @($view.Runtime.HealthSystemRuntime.SystemHealthInfo.NumericSensorInfo)) {
            if ($null -eq $sensor -or -not $sensor.HealthState) {
                continue
            }

            $sensorState = [string]$sensor.HealthState.Key

            if ($sensorState -and $sensorState -ne 'green' -and $sensorState -ne 'unknown') {
                $statusReasons.Add("hardware [$sensorState]: $($sensor.Name)")
            }
        }
    }

    $overallDetail = if ($statusReasons.Count -gt 0) {
        "$overallStatus - " + ($statusReasons -join '; ')
    }
    else {
        $overallStatus
    }

    $overallResult = switch ($overallStatus) {
        'green'  { 'PASS' }
        'yellow' { 'WARN' }
        'red'    { 'FAIL' }
        default  { 'WARN' }
    }

    $checks.Add([pscustomobject]@{
        Check  = 'Host overall status'
        Result = $overallResult
        Detail = $overallDetail
    })

    $hostTasks    = Get-VMHostActiveTasks -View $view
    $runningTasks = @($hostTasks | Where-Object { $_.State -eq 'running' })
    $failedTasks  = @($hostTasks | Where-Object { $_.State -eq 'error' })

    if ($runningTasks.Count -gt 0) {
        foreach ($task in $runningTasks) {
            $progressText = if ($null -ne $task.Progress) { " ($($task.Progress)%)" } else { '' }

            $checks.Add([pscustomobject]@{
                Check  = 'Host running task'
                Result = 'INFO'
                Detail = "$($task.Name)$progressText is in progress on this host."
            })
        }
    }
    else {
        $checks.Add([pscustomobject]@{
            Check  = 'Host running task'
            Result = 'INFO'
            Detail = 'No vCenter task is currently running on this host.'
        })
    }

    foreach ($task in $failedTasks) {
        $checks.Add([pscustomobject]@{
            Check  = 'Host recent task failure'
            Result = 'WARN'
            Detail = "$($task.Name) recently failed" + $(if ($task.Error) { ": $($task.Error)" } else { '.' })
        })
    }

    foreach ($nic in (Get-PhysicalNicDetail -Hosts @($TargetHost))) {
        $nicInUse = $uplinkPnics -contains $nic.Device

        $nicResult = if ($nic.LinkUp) {
            'PASS'
        }
        elseif ($nicInUse) {
            'FAIL'
        }
        else {
            'INFO'
        }

        $nicUsage = if ($nicInUse) { 'uplink' } else { 'unused' }

        $checks.Add([pscustomobject]@{
            Check  = "Physical NIC $($nic.Device)"
            Result = $nicResult
            Detail = "Link=$($nic.LinkUp); SpeedMb=$($nic.SpeedMb); MAC=$($nic.Mac); Usage=$nicUsage"
        })
    }

    foreach ($neighbor in (Get-PhysicalNicNeighbor -Hosts @($TargetHost))) {
        $neighborInUse = $uplinkPnics -contains $neighbor.Pnic
        $noNeighbor    = $neighbor.DiscoveryProtocol -eq 'NONE_DETECTED'

        $neighborResult = if (-not $noNeighbor) {
            'PASS'
        }
        elseif ($neighborInUse) {
            'WARN'
        }
        else {
            'INFO'
        }

        $checks.Add([pscustomobject]@{
            Check  = "LLDP/CDP $($neighbor.Pnic)"
            Result = $neighborResult
            Detail = (
                "$($neighbor.DiscoveryProtocol); " +
                "Switch=$($neighbor.SwitchSystemName); " +
                "Port=$($neighbor.SwitchPortId)"
            )
        })
    }

    foreach ($ping in (Test-VsanVmkConnectivity -SourceHost $TargetHost -AllHosts $AllHosts)) {
        $checks.Add([pscustomobject]@{
            Check  = "vSAN vmkping to $($ping.TargetHost)"
            Result = $ping.Result
            Detail = if ($ping.Detail) {
                $ping.Detail
            }
            else {
                "Src=$($ping.SourceVmk)($($ping.SourceIP)) -> $($ping.TargetHost)($($ping.TargetIP)); " +
                "Sent=$($ping.Transmitted); Recv=$($ping.Received); Loss=$($ping.LossPercent)%"
            }
        })
    }

    foreach ($ping in (Test-VmkJumboConnectivity -SourceHost $TargetHost -AllHosts $AllHosts -Size $jumboSize)) {
        $checks.Add([pscustomobject]@{
            Check  = "Jumbo $($ping.TrafficType) vmkping to $($ping.TargetHost) ($($ping.Size)B, DF)"
            Result = $ping.Result
            Detail = $ping.Detail
        })
    }

    $resync = if ($null -ne $VsanResync) {
        $VsanResync
    }
    else {
        Get-VsanResyncSafe -Cluster $Cluster
    }

    $checks.Add([pscustomobject]@{
        Check  = 'vSAN resynchronisation'
        Result = switch ($resync.Status) {
            'NONE'      { 'PASS' }
            'RESYNCING' { 'WARN' }
            'ERROR'     { 'FAIL' }
            'UNKNOWN'   { 'WARN' }
            default     { 'REVIEW' }
        }
        Detail = ($resync | Out-String).Trim()
    })

    $certExpiry = Get-VMHostCertExpirySafe -HostObject $TargetHost -WarnDays $certWarn

    $checks.Add([pscustomobject]@{
        Check  = 'ESXi host certificate expiry'
        Result = $certExpiry.Result
        Detail = $certExpiry.Detail
    })

    $vsanPosture = Get-VsanClusterPostureSafe -Cluster $Cluster

    $checks.Add([pscustomobject]@{
        Check  = 'vSAN dedupe/compression and encryption'
        Result = $vsanPosture.Result
        Detail = $vsanPosture.Detail
    })

    $vsanCapacity = Get-VsanCapacitySafe -Cluster $Cluster -HostCount (@($AllHosts).Count) -SafetyFactor $n1Factor

    $checks.Add([pscustomobject]@{
        Check  = 'vSAN N-1 evacuation headroom (estimate)'
        Result = $vsanCapacity.Result
        Detail = $vsanCapacity.Detail
    })

    $faultDomain = Get-VsanStretchedFaultDomainSafe -Cluster $Cluster

    if ($faultDomain.Result -ne 'SKIP') {
        $checks.Add([pscustomobject]@{
            Check  = 'vSAN stretched fault domain / witness'
            Result = $faultDomain.Result
            Detail = $faultDomain.Detail
        })
    }

    $repairTimer = Get-VsanRepairTimerSafe -HostObject $TargetHost

    $checks.Add([pscustomobject]@{
        Check  = 'vSAN object repair timer'
        Result = $repairTimer.Result
        Detail = $repairTimer.Detail
    })

    return $checks
}

function Get-BaselinePathForEnvironment {
    param(
        [Parameter(Mandatory)][string]$VCenterName,
        [Parameter(Mandatory)][string]$ClusterName
    )

    Write-Host ''
    Write-Host "Baseline required for $ClusterName on $VCenterName." -ForegroundColor Yellow
    Write-Host 'Enter the complete baseline folder path.'
    Write-Host 'Example:'
    Write-Host (
        "  $OutputRoot\Baselines\$VCenterName\$ClusterName\20260717-140000"
    ) -ForegroundColor DarkGray

    while ($true) {
        $path = (Read-Host 'Baseline path').Trim()

        if (Test-Path $path) {
            return (Resolve-Path $path).Path
        }

        Write-Warning "Baseline path does not exist: $path"
    }
}

function Invoke-HostValidation {
    param(
        [Parameter(Mandatory)]$HostObject,
        [Parameter(Mandatory)]$Cluster,
        [Parameter(Mandatory)]$AllHosts,
        $VsanResync,
        [Parameter(Mandatory)]$Run,
        [string]$BaselinePath,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$ClusterName
    )

    $hostFolder = Export-HostEvidence -HostObject $HostObject -RunContext $Run

    $checks = @(
        Get-HostChecks `
            -TargetHost $HostObject `
            -Cluster $Cluster `
            -AllHosts $AllHosts `
            -VsanResync $VsanResync
    )

    if ($BaselinePath) {
        $baselineHostFolder = Join-Path `
            $BaselinePath `
            "Hosts\$(ConvertTo-SafeFileName $HostObject.Name)"

        $comparisons = @()

        $comparisons += Compare-CsvFile `
            -BaselineFile (Join-Path $baselineHostFolder 'Physical-NICs.csv') `
            -CurrentFile (Join-Path $hostFolder 'Physical-NICs.csv') `
            -KeyProperties @('Host', 'Device') `
            -CompareProperties @('Mac', 'LinkUp', 'SpeedMb', 'Driver', 'Pci')

        $comparisons += Compare-CsvFile `
            -BaselineFile (Join-Path $baselineHostFolder 'LLDP-CDP.csv') `
            -CurrentFile (Join-Path $hostFolder 'LLDP-CDP.csv') `
            -KeyProperties @('Host', 'Pnic') `
            -CompareProperties @(
                'DiscoveryProtocol',
                'SwitchSystemName',
                'SwitchDeviceId',
                'SwitchPortId',
                'SpeedMb'
            )

        $comparisons += Compare-CsvFile `
            -BaselineFile (Join-Path $baselineHostFolder 'VMkernel.csv') `
            -CurrentFile (Join-Path $hostFolder 'VMkernel.csv') `
            -KeyProperties @('Host', 'Device') `
            -CompareProperties @(
                'PortGroup',
                'IP',
                'SubnetMask',
                'Mtu',
                'VMotionEnabled',
                'VsanEnabled',
                'Management'
            )

        $comparisons |
            Export-Csv `
                -Path (Join-Path $hostFolder 'Baseline-Differences.csv') `
                -NoTypeInformation `
                -Encoding UTF8

        foreach ($comparison in $comparisons) {
            $checks += [pscustomobject]@{
                Check  = "Baseline comparison: $($comparison.Object)"
                Result = $comparison.Result
                Detail = "$($comparison.Key): $($comparison.Difference)"
            }
        }
    }

    $checks |
        Export-Csv `
            -Path (Join-Path $hostFolder 'Readiness-Checks.csv') `
            -NoTypeInformation `
            -Encoding UTF8

    $hostSafe = ConvertTo-SafeFileName $HostObject.Name

    Write-HtmlReport `
        -Title "$($HostObject.Name) - $Mode - $ClusterName" `
        -Checks $checks `
        -Path (Join-Path $hostFolder "$hostSafe-Report.html")

    $failCount = @($checks | Where-Object { $_.Result -eq 'FAIL' -or $_.Result -eq 'ERROR' }).Count
    $warnCount = @($checks | Where-Object { $_.Result -eq 'WARN' -or $_.Result -eq 'REVIEW' }).Count
    $passCount = @($checks | Where-Object { $_.Result -eq 'PASS' }).Count

    $hostOverall = if ($failCount -gt 0) {
        'NOT READY'
    }
    elseif ($warnCount -gt 0) {
        'READY WITH WARNINGS'
    }
    else {
        'READY'
    }

    # Echo the outcome to the console as the run proceeds, so the operator sees
    # what and why on screen instead of only the final summary. Every WARN /
    # FAIL / ERROR check is listed with its detail; the full record is still in
    # the host's HTML report and Readiness-Checks.csv.
    $consoleNotables = @(
        $checks |
            Where-Object {
                $_.Result -eq 'FAIL' -or
                $_.Result -eq 'ERROR' -or
                $_.Result -eq 'WARN' -or
                $_.Result -eq 'REVIEW'
            }
    )

    $overallColor = switch ($hostOverall) {
        'NOT READY'           { 'Red' }
        'READY WITH WARNINGS' { 'Yellow' }
        default               { 'Green' }
    }

    Write-Host (
        "  {0}: {1} (Pass={2} Warn={3} Fail={4})" -f
            $HostObject.Name, $hostOverall, $passCount, $warnCount, $failCount
    ) -ForegroundColor $overallColor

    foreach ($notable in $consoleNotables) {
        $notableColor = if ($notable.Result -eq 'FAIL' -or $notable.Result -eq 'ERROR') {
            'Red'
        }
        else {
            'Yellow'
        }

        Write-Host ("      [{0}] {1} - {2}" -f $notable.Result, $notable.Check, $notable.Detail) -ForegroundColor $notableColor
    }

    return [pscustomobject]@{
        Host           = $HostObject.Name
        Overall        = $hostOverall
        Pass           = $passCount
        Warn           = $warnCount
        Fail           = $failCount
        ReportRelative = "Hosts/$hostSafe/$hostSafe-Report.html"
        Error          = $null
    }
}

function Invoke-HostValidationParallel {
    param(
        [Parameter(Mandatory)][string[]]$HostNames,
        [Parameter(Mandatory)][string]$VCenterName,
        [Parameter(Mandatory)][string]$ClusterName,
        [Parameter(Mandatory)]$Credential,
        [Parameter(Mandatory)]$Run,
        $VsanResync,
        [string]$BaselinePath,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][bool]$IgnoreCert,
        [Parameter(Mandatory)][int]$ThrottleLimit
    )

    # Carry this script's own functions into each worker runspace. Runspaces do
    # not inherit session functions, so each is added to the initial session
    # state. They are added by name (not by file path or a session diff) so this
    # works when the script is pasted into the ISE editor and run unsaved, and on
    # repeated runs in the same ISE session.
    $sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()

    $functionNames = @(
        'ConvertTo-SafeFileName'
        'Test-HostQueryable'
        'Export-CsvSafe'
        'Get-HostSummary'
        'Get-PhysicalNicDetail'
        'Get-PhysicalNicNeighbor'
        'Get-VmkDetail'
        'Get-VdsHostMapping'
        'Get-VmNetworkInventory'
        'Get-VsanResyncSafe'
        'Get-IPv4Network'
        'Find-PingCount'
        'Test-VsanVmkConnectivity'
        'Test-VmkJumboConnectivity'
        'Get-VMHostCertExpirySafe'
        'Get-VsanClusterPostureSafe'
        'Get-VsanCapacitySafe'
        'Get-VMHostActiveTasks'
        'Get-VsanStretchedFaultDomainSafe'
        'Get-VsanRepairTimerSafe'
        'Compare-CsvFile'
        'Write-HtmlReport'
        'Export-HostEvidence'
        'Get-HostChecks'
        'Invoke-HostValidation'
    )

    foreach ($functionName in $functionNames) {
        $functionInfo = Get-Item -Path "Function:\$functionName" -ErrorAction SilentlyContinue

        if (-not $functionInfo) {
            throw "Required function '$functionName' was not found in the session; run the whole script so all functions are defined before validating."
        }

        $entry = New-Object `
            System.Management.Automation.Runspaces.SessionStateFunctionEntry `
            -ArgumentList $functionInfo.Name, $functionInfo.Definition

        $sessionState.Commands.Add($entry)
    }

    $pool = [runspacefactory]::CreateRunspacePool(1, $ThrottleLimit, $sessionState, $Host)
    $pool.Open()

    $worker = {
        param(
            $HostName,
            $VCenterName,
            $ClusterName,
            $Credential,
            $Run,
            $VsanResync,
            $BaselinePath,
            $Mode,
            $IgnoreCert
        )

        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        $connection = $null

        $connectMutex = New-Object System.Threading.Mutex($false, 'VcfVxRailValidationViConnect')

        try {
            # Import PowerCLI fully inside the worker (a partial session-state
            # load leaves Get-EsxCli -V2 null-referencing), but serialise it:
            # importing this module in several runspaces at once modifies shared
            # collections and fails with "Collection was modified". The import is
            # a one-time cost per worker, so serialising it barely matters.
            try {
                [void]$connectMutex.WaitOne()
            }
            catch [System.Threading.AbandonedMutexException] {
            }

            try {
                Import-Module VMware.VimAutomation.Core -ErrorAction Stop

                if ($IgnoreCert) {
                    Set-PowerCLIConfiguration `
                        -InvalidCertificateAction Ignore `
                        -Scope Session `
                        -Confirm:$false | Out-Null
                }
            }
            finally {
                $connectMutex.ReleaseMutex()
            }

            try {
                [void]$connectMutex.WaitOne()
            }
            catch [System.Threading.AbandonedMutexException] {
                # A previous worker exited without releasing; ownership is now ours.
            }

            try {
                $connection = Connect-VIServer -Server $VCenterName -Credential $Credential
            }
            finally {
                $connectMutex.ReleaseMutex()
            }

            $clusterObject = Get-Cluster -Name $ClusterName -Server $connection
            $allHosts = @(Get-VMHost -Location $clusterObject -Server $connection | Sort-Object Name)
            $hostObject = $allHosts | Where-Object { $_.Name -eq $HostName } | Select-Object -First 1

            if (-not $hostObject) {
                throw "Host $HostName was not found in cluster $ClusterName."
            }

            Invoke-HostValidation `
                -HostObject $hostObject `
                -Cluster $clusterObject `
                -AllHosts $allHosts `
                -VsanResync $VsanResync `
                -Run $Run `
                -BaselinePath $BaselinePath `
                -Mode $Mode `
                -ClusterName $ClusterName
        }
        catch {
            [pscustomobject]@{
                Host           = $HostName
                Overall        = 'NOT READY'
                Pass           = 0
                Warn           = 0
                Fail           = 1
                ReportRelative = $null
                Error          = $_.Exception.Message
            }
        }
        finally {
            if ($connection) {
                try {
                    [void]$connectMutex.WaitOne()
                }
                catch [System.Threading.AbandonedMutexException] {
                }

                try {
                    Disconnect-VIServer `
                        -Server $connection `
                        -Confirm:$false `
                        -ErrorAction SilentlyContinue
                }
                finally {
                    $connectMutex.ReleaseMutex()
                }
            }

            $connectMutex.Dispose()
        }
    }

    $running = foreach ($hostName in $HostNames) {
        $shell = [powershell]::Create()
        $shell.RunspacePool = $pool

        [void]$shell.AddScript($worker).
            AddArgument($hostName).
            AddArgument($VCenterName).
            AddArgument($ClusterName).
            AddArgument($Credential).
            AddArgument($Run).
            AddArgument($VsanResync).
            AddArgument($BaselinePath).
            AddArgument($Mode).
            AddArgument($IgnoreCert)

        [pscustomobject]@{
            Shell  = $shell
            Handle = $shell.BeginInvoke()
            Name   = $hostName
        }
    }

    $rollups = [System.Collections.Generic.List[object]]::new()

    foreach ($item in $running) {
        try {
            $output = $item.Shell.EndInvoke($item.Handle)

            foreach ($result in $output) {
                $rollups.Add($result)
            }
        }
        catch {
            $rollups.Add([pscustomobject]@{
                Host           = $item.Name
                Overall        = 'NOT READY'
                Pass           = 0
                Warn           = 0
                Fail           = 1
                ReportRelative = $null
                Error          = $_.Exception.Message
            })
        }
        finally {
            $item.Shell.Dispose()
        }
    }

    $pool.Close()
    $pool.Dispose()

    return $rollups
}

function Invoke-EnvironmentValidation {
    param(
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$EnvironmentKey,
        [Parameter(Mandatory)][PSCredential]$Credential
    )

    $environment = $EnvironmentMap[$EnvironmentKey]
    $vCenterName = $environment.VCenter
    $clusterName = $environment.Cluster
    $connection = $null
    $baselinePath = $null
    $selectedHost = $null
    $stage        = 'starting'

    Write-Section "$($environment.DisplayName): $clusterName"
    Write-Host "vCenter : $vCenterName"
    Write-Host "Cluster : $clusterName"
    Write-Host "Mode    : $Mode"

    try {
        Write-Host ''
        Write-Host "Connecting to $vCenterName..." -ForegroundColor Cyan

        $stage = "connecting to vCenter $vCenterName"
        $connection = Connect-VIServer `
            -Server $vCenterName `
            -Credential $Credential `
            -ErrorAction Stop

        Write-Host 'Connected.' -ForegroundColor Green

        $stage = "finding cluster $clusterName"
        $cluster = Get-Cluster `
            -Server $connection `
            -Name $clusterName `
            -ErrorAction Stop

        $stage = "listing hosts in $clusterName"
        $allHosts = @(Get-VMHost -Location $cluster -Server $connection | Sort-Object Name)

        Write-Host ("Found {0} host(s) in {1}." -f $allHosts.Count, $clusterName) -ForegroundColor DarkGray

        if ($allHosts.Count -eq 0) {
            throw "No ESXi hosts were found in cluster $clusterName."
        }

        if ($Mode -eq 'ValidateHostMove') {
            $selectedHost = Select-HostFromCluster `
                -Cluster $cluster `
                -VCenterName $vCenterName

            $baselinePath = Get-BaselinePathForEnvironment `
                -VCenterName $vCenterName `
                -ClusterName $clusterName
        }
        elseif ($Mode -eq 'PostMigration') {
            $baselinePath = Get-BaselinePathForEnvironment `
                -VCenterName $vCenterName `
                -ClusterName $clusterName
        }

        $targetHosts = @(
            if ($Mode -eq 'ValidateHostMove') {
                $selectedHost
            }
            else {
                $allHosts
            }
        )

        $stage = 'creating run folders'
        $run = New-RunContext `
            -Mode $Mode `
            -VCenterName $vCenterName `
            -ClusterName $clusterName `
            -HostName $(if ($selectedHost) { $selectedHost.Name } else { $null })

        $stage = 'reading distributed port groups'
        $portgroups = @(Get-DistributedPortgroupDetail -VCenterName $vCenterName)
        $portgroups | Export-CsvSafe -Path (Join-Path $run.ClusterFolder 'VDS-Portgroups.csv')

        $stage = 'reading recent events'
        $recentEvents = @(Get-RecentCriticalEvents -Entity $cluster -Hours 24)
        $recentEvents | Export-CsvSafe -Path (Join-Path $run.ClusterFolder 'Recent-Warnings-Errors.csv')

        $stage = 'reading vSAN health'
        $vsanHealth = Get-VsanHealthSafe -Cluster $cluster
        $vsanHealth | Export-Clixml -Path (Join-Path $run.ClusterFolder 'vSAN-Health.xml')

        $stage = 'reading vSAN resync'
        $vsanResync = Get-VsanResyncSafe -Cluster $cluster
        $vsanResync | Export-Clixml -Path (Join-Path $run.ClusterFolder 'vSAN-Resync.xml')

        Write-Host 'Cluster-level checks done; validating hosts...' -ForegroundColor DarkGray

        $stage = 'validating hosts'
        $hostRollups = [System.Collections.Generic.List[object]]::new()

        if ($ThrottleLimit -gt 1 -and @($targetHosts).Count -gt 1) {
            Write-Warning (
                "PARALLEL mode is ON (throttle $ThrottleLimit): validating " +
                "$(@($targetHosts).Count) hosts at once. This is faster but less " +
                "reliable with PowerCLI. If you hit connection or Get-EsxCli " +
                "errors, set `$ThrottleLimit = 1 near the top of the script."
            )

            $parallelRollups = Invoke-HostValidationParallel `
                -HostNames @($targetHosts | ForEach-Object { $_.Name }) `
                -VCenterName $vCenterName `
                -ClusterName $clusterName `
                -Credential $Credential `
                -Run $run `
                -VsanResync $vsanResync `
                -BaselinePath $baselinePath `
                -Mode $Mode `
                -IgnoreCert ([bool]$SkipCertificateCheck) `
                -ThrottleLimit $ThrottleLimit

            foreach ($rollup in $parallelRollups) {
                if ($rollup.PSObject.Properties['Error'] -and $rollup.Error) {
                    Write-Warning "Host $($rollup.Host) failed: $($rollup.Error)"
                }

                $hostRollups.Add($rollup)
            }
        }
        else {
            foreach ($hostObject in $targetHosts) {
                Write-Host "Validating host: $($hostObject.Name)" -ForegroundColor Cyan

                $rollup = Invoke-HostValidation `
                    -HostObject $hostObject `
                    -Cluster $cluster `
                    -AllHosts $allHosts `
                    -VsanResync $vsanResync `
                    -Run $run `
                    -BaselinePath $baselinePath `
                    -Mode $Mode `
                    -ClusterName $clusterName

                $hostRollups.Add($rollup)
            }
        }

        Write-RunSummaryHtml `
            -Path (Join-Path $run.RunRoot 'Index.html') `
            -VCenter $vCenterName `
            -Cluster $clusterName `
            -Mode $Mode `
            -VsanHealth $vsanHealth `
            -VsanResync $vsanResync `
            -PortgroupCount $portgroups.Count `
            -EventCount $recentEvents.Count `
            -HostRollups $hostRollups

        $manifest = [pscustomobject]@{
            EnvironmentKey = $EnvironmentKey
            DisplayName    = $environment.DisplayName
            VCenter        = $vCenterName
            Cluster        = $clusterName
            Mode           = $Mode
            HostName       = if ($selectedHost) { $selectedHost.Name } else { $null }
            BaselinePath   = $baselinePath
            HostCount      = @($targetHosts).Count
            Generated      = Get-Date
            OutputPath     = $run.RunRoot
        }

        $manifest |
            ConvertTo-Json -Depth 4 |
            Set-Content `
                -Path (Join-Path $run.RunRoot 'Run-Manifest.json') `
                -Encoding UTF8

        Write-Host ''
        Write-Host "Completed: $clusterName" -ForegroundColor Green
        Write-Host "Output   : $($run.RunRoot)"
        Write-Host "Summary  : $(Join-Path $run.RunRoot 'Index.html')" -ForegroundColor Green

        $clusterReadiness =
            if (@($hostRollups | Where-Object { $_.Overall -eq 'NOT READY' }).Count -gt 0) {
                'NOT READY'
            }
            elseif (@($hostRollups | Where-Object { $_.Overall -eq 'READY WITH WARNINGS' }).Count -gt 0) {
                'READY WITH WARNINGS'
            }
            else {
                'READY'
            }

        return [pscustomobject]@{
            Environment = $EnvironmentKey
            VCenter     = $vCenterName
            Cluster     = $clusterName
            Mode        = $Mode
            Result      = 'COMPLETED'
            Readiness   = $clusterReadiness
            HostCount   = @($targetHosts).Count
            Detail      = $null
            Output      = $run.RunRoot
            IndexPath   = (Join-Path $run.RunRoot 'Index.html')
        }
    }
    catch {
        $errorRecord   = $_
        $exceptionType = $errorRecord.Exception.GetType().FullName
        $message       = [string]$errorRecord.Exception.Message

        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = '(the exception carried no message text)'
        }

        $failingLine = if ($errorRecord.InvocationInfo) {
            ([string]$errorRecord.InvocationInfo.Line).Trim()
        }
        else {
            ''
        }

        $position  = if ($errorRecord.InvocationInfo) { $errorRecord.InvocationInfo.PositionMessage } else { '' }
        $stageText = if ($stage) { $stage } else { 'unknown stage' }

        Write-Host ''
        Write-Host ('!' * 72) -ForegroundColor Red
        Write-Host "VALIDATION FAILED: $clusterName on $vCenterName" -ForegroundColor Red
        Write-Host "  Failed during : $stageText" -ForegroundColor Red
        Write-Host "  Exception     : $exceptionType" -ForegroundColor Red
        Write-Host "  Message       : $message" -ForegroundColor Red

        if ($failingLine) {
            Write-Host "  Command       : $failingLine" -ForegroundColor Red
        }

        if ($position) {
            Write-Host "  Position      : $position" -ForegroundColor DarkYellow
        }

        if ($errorRecord.ScriptStackTrace) {
            Write-Host '  Stack trace   :' -ForegroundColor DarkYellow
            Write-Host $errorRecord.ScriptStackTrace -ForegroundColor DarkGray
        }

        Write-Host ('!' * 72) -ForegroundColor Red
        Write-Host ''

        return [pscustomobject]@{
            Environment = $EnvironmentKey
            VCenter     = $vCenterName
            Cluster     = $clusterName
            Mode        = $Mode
            Result      = 'FAILED'
            Readiness   = 'FAILED'
            HostCount   = 0
            Detail      = ("[$stageText] $message $position").Trim()
            Output      = $null
            IndexPath   = $null
        }
    }
    finally {
        if ($connection) {
            Disconnect-VIServer `
                -Server $connection `
                -Confirm:$false `
                -ErrorAction SilentlyContinue

            Write-Host "Disconnected from $vCenterName." -ForegroundColor DarkGray
        }
    }
}

function Write-MasterIndexHtml {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)]$Results
    )

    $rows = foreach ($result in $Results) {
        $readiness = if ($result.PSObject.Properties['Readiness'] -and $result.Readiness) {
            [string]$result.Readiness
        }
        else {
            [string]$result.Result
        }

        $class = switch ($readiness) {
            'READY'               { 'pass' }
            'READY WITH WARNINGS' { 'warn' }
            'NOT READY'           { 'fail' }
            'FAILED'              { 'fail' }
            default               { 'warn' }
        }

        $clusterCell   = [System.Net.WebUtility]::HtmlEncode([string]$result.Cluster)
        $vcenterCell   = [System.Net.WebUtility]::HtmlEncode([string]$result.VCenter)
        $readinessCell = [System.Net.WebUtility]::HtmlEncode($readiness)
        $hostsCell     = [System.Net.WebUtility]::HtmlEncode([string]$result.HostCount)

        $reportCell = if ($result.PSObject.Properties['IndexPath'] -and $result.IndexPath) {
            $url = 'file:///' + ($result.IndexPath -replace '\\', '/')
            "<a href=`"$url`">Open report</a>"
        }
        else {
            [System.Net.WebUtility]::HtmlEncode([string]$result.Detail)
        }

        "<tr class=`"$class`"><td>$clusterCell</td><td>$vcenterCell</td>" +
        "<td>$readinessCell</td><td>$hostsCell</td><td>$reportCell</td></tr>"
    }

    $generated   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $modeEncoded = [System.Net.WebUtility]::HtmlEncode($Mode)
    $clusterTotal = @($Results).Count

    $html = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Validation run - $modeEncoded</title>
<style>
body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; color: #1f2933; }
h1 { font-size: 1.5em; margin-bottom: 4px; }
.summary { color: #52606d; margin-bottom: 20px; }
table { border-collapse: collapse; width: 100%; }
th, td { border: 1px solid #cccccc; padding: 8px; text-align: left; }
th { background: #f0f4f8; }
.pass { background: #e8f5e9; }
.warn { background: #fff8e1; }
.fail { background: #ffebee; }
a { color: #1565c0; }
</style>
</head>
<body>
<h1>Validation run - $modeEncoded</h1>
<div class="summary">Generated: $generated &nbsp;|&nbsp; Clusters: $clusterTotal</div>
<table>
<tr><th>Cluster</th><th>vCenter</th><th>Result</th><th>Hosts</th><th>Report</th></tr>
$($rows -join "`n")
</table>
</body>
</html>
"@

    Set-Content -Path $Path -Value $html -Encoding UTF8
}

###############################################################################
# MAIN
###############################################################################

if (-not (Get-Module -ListAvailable -Name VMware.PowerCLI)) {
    throw 'VMware.PowerCLI was not found. Install it with: Install-Module VMware.PowerCLI -Scope CurrentUser'
}

if ($SkipCertificateCheck) {
    Set-PowerCLIConfiguration `
        -InvalidCertificateAction Ignore `
        -Confirm:$false | Out-Null
}

$mode = Select-Operation

if ($mode -eq 'Exit') {
    Write-Host 'No validation was run.'
    return
}

$selectedEnvironmentKeys = Select-Environments

if (-not $Credential) {
    $Credential = Get-Credential -Message 'Enter vCenter credentials'
}

Write-Section 'Validation summary'
Write-Host "Mode       : $mode"
Write-Host "Output root: $OutputRoot"
Write-Host 'Clusters   :'

foreach ($key in $selectedEnvironmentKeys) {
    $environment = $EnvironmentMap[$key]
    Write-Host "  - $($environment.Cluster) on $($environment.VCenter)"
}

$proceed = Read-MenuChoice -Prompt 'Proceed? Y/N' -AllowedValues @('Y','N')

if ($proceed -eq 'N') {
    Write-Host 'Validation cancelled.'
    return
}

$results = [System.Collections.Generic.List[object]]::new()

foreach ($key in $selectedEnvironmentKeys) {
    $result = Invoke-EnvironmentValidation `
        -Mode $mode `
        -EnvironmentKey $key `
        -Credential $Credential

    $results.Add($result)
}

Write-Section 'Overall results'
$results | Format-Table -AutoSize -Property Cluster, VCenter, Readiness, HostCount

$sessionStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$summaryFolder = Join-Path $OutputRoot (Join-Path 'Run-Summaries' "$mode-$sessionStamp")
New-Item -ItemType Directory -Path $summaryFolder -Force | Out-Null

$summaryFile = Join-Path $summaryFolder 'Validation-Summary.csv'

$results |
    Export-Csv `
        -Path $summaryFile `
        -NoTypeInformation `
        -Encoding UTF8

$masterIndex = Join-Path $summaryFolder 'index.html'
Write-MasterIndexHtml -Path $masterIndex -Mode $mode -Results $results

Write-Host ''
Write-Host 'Open this one file for every cluster in this run:' -ForegroundColor Green
Write-Host "  $masterIndex" -ForegroundColor Green
Write-Host "Summary CSV: $summaryFile" -ForegroundColor DarkGray
