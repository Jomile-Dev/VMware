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

    $esxcli = Get-EsxCli -VMHost $SourceHost -V2

    foreach ($targetHost in ($AllHosts | Where-Object Name -ne $SourceHost.Name)) {
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

function Get-HostChecks {
    param(
        [Parameter(Mandatory)]$TargetHost,
        [Parameter(Mandatory)]$Cluster,
        [Parameter(Mandatory)]$AllHosts
    )

    $checks = [System.Collections.Generic.List[object]]::new()
    $view = Get-View -Id $TargetHost.Id

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

    $resync = Get-VsanResyncSafe -Cluster $Cluster

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

    Write-Section "$($environment.DisplayName): $clusterName"
    Write-Host "vCenter : $vCenterName"
    Write-Host "Cluster : $clusterName"
    Write-Host "Mode    : $Mode"

    try {
        Write-Host ''
        Write-Host "Connecting to $vCenterName..." -ForegroundColor Cyan

        $connection = Connect-VIServer `
            -Server $vCenterName `
            -Credential $Credential `
            -ErrorAction Stop

        Write-Host 'Connected.' -ForegroundColor Green

        $cluster = Get-Cluster `
            -Server $connection `
            -Name $clusterName `
            -ErrorAction Stop

        $allHosts = @(Get-VMHost -Location $cluster -Server $connection | Sort-Object Name)

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

        $run = New-RunContext `
            -Mode $Mode `
            -VCenterName $vCenterName `
            -ClusterName $clusterName `
            -HostName $(if ($selectedHost) { $selectedHost.Name } else { $null })

        $portgroups = @(Get-DistributedPortgroupDetail -VCenterName $vCenterName)
        $portgroups | Export-CsvSafe -Path (Join-Path $run.ClusterFolder 'VDS-Portgroups.csv')

        $recentEvents = @(Get-RecentCriticalEvents -Entity $cluster -Hours 24)
        $recentEvents | Export-CsvSafe -Path (Join-Path $run.ClusterFolder 'Recent-Warnings-Errors.csv')

        $vsanHealth = Get-VsanHealthSafe -Cluster $cluster
        $vsanHealth | Export-Clixml -Path (Join-Path $run.ClusterFolder 'vSAN-Health.xml')

        $vsanResync = Get-VsanResyncSafe -Cluster $cluster
        $vsanResync | Export-Clixml -Path (Join-Path $run.ClusterFolder 'vSAN-Resync.xml')

        $hostRollups = [System.Collections.Generic.List[object]]::new()

        foreach ($hostObject in $targetHosts) {
            Write-Host "Validating host: $($hostObject.Name)" -ForegroundColor Cyan

            $hostFolder = Export-HostEvidence `
                -HostObject $hostObject `
                -RunContext $run

            $checks = @(
                Get-HostChecks `
                    -TargetHost $hostObject `
                    -Cluster $cluster `
                    -AllHosts $allHosts
            )

            if ($baselinePath) {
                $baselineHostFolder = Join-Path `
                    $baselinePath `
                    "Hosts\$(ConvertTo-SafeFileName $hostObject.Name)"

                $comparisons = @()

                $comparisons += Compare-CsvFile `
                    -BaselineFile (Join-Path $baselineHostFolder 'Physical-NICs.csv') `
                    -CurrentFile (Join-Path $hostFolder 'Physical-NICs.csv') `
                    -KeyProperties @('Host','Device') `
                    -CompareProperties @('Mac','LinkUp','SpeedMb','Driver','Pci')

                $comparisons += Compare-CsvFile `
                    -BaselineFile (Join-Path $baselineHostFolder 'LLDP-CDP.csv') `
                    -CurrentFile (Join-Path $hostFolder 'LLDP-CDP.csv') `
                    -KeyProperties @('Host','Pnic') `
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
                    -KeyProperties @('Host','Device') `
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

            $hostSafe = ConvertTo-SafeFileName $hostObject.Name

            Write-HtmlReport `
                -Title "$($hostObject.Name) - $Mode - $clusterName" `
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

            $hostRollups.Add([pscustomobject]@{
                Host           = $hostObject.Name
                Overall        = $hostOverall
                Pass           = $passCount
                Warn           = $warnCount
                Fail           = $failCount
                ReportRelative = "Hosts/$hostSafe/$hostSafe-Report.html"
            })
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

        return [pscustomobject]@{
            Environment = $EnvironmentKey
            VCenter     = $vCenterName
            Cluster     = $clusterName
            Mode        = $Mode
            Result      = 'COMPLETED'
            HostCount   = @($targetHosts).Count
            Detail      = $null
            Output      = $run.RunRoot
        }
    }
    catch {
        $position = if ($_.InvocationInfo) { $_.InvocationInfo.PositionMessage } else { '' }

        Write-Warning "Validation failed for $clusterName on $vCenterName."
        Write-Warning $_.Exception.Message

        if ($position) {
            Write-Warning $position
        }

        if ($_.ScriptStackTrace) {
            Write-Warning "Stack trace:`n$($_.ScriptStackTrace)"
        }

        return [pscustomobject]@{
            Environment = $EnvironmentKey
            VCenter     = $vCenterName
            Cluster     = $clusterName
            Mode        = $Mode
            Result      = 'FAILED'
            HostCount   = 0
            Detail      = ("$($_.Exception.Message) $position").Trim()
            Output      = $null
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
$results | Format-Table -AutoSize

$summaryFolder = Join-Path $OutputRoot 'Run-Summaries'
New-Item -ItemType Directory -Path $summaryFolder -Force | Out-Null

$summaryFile = Join-Path `
    $summaryFolder `
    ("Validation-Summary-{0}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

$results |
    Export-Csv `
        -Path $summaryFile `
        -NoTypeInformation `
        -Encoding UTF8

Write-Host ''
Write-Host "Summary saved to: $summaryFile" -ForegroundColor Green
