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

        [pscustomobject]@{
            Host              = $hostObject.Name
            ConnectionState   = $hostObject.ConnectionState
            PowerState        = $hostObject.PowerState
            InMaintenanceMode = $hostObject.ExtensionData.Runtime.InMaintenanceMode
            Version           = $hostObject.Version
            Build             = $hostObject.Build
            Manufacturer      = $hostObject.Manufacturer
            Model             = $hostObject.Model
            CpuSockets        = $hostObject.NumCpu
            CpuCores          = $hostObject.NumCpu * $hostObject.NumCpuCores
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
            [pscustomobject]@{
                Host       = $hostObject.Name
                Device     = $nic.Name
                Mac        = $nic.Mac
                LinkUp     = $null -ne $nic.LinkSpeed
                SpeedMb    = if ($nic.LinkSpeed) { $nic.LinkSpeed.SpeedMb } else { $null }
                FullDuplex = if ($nic.LinkSpeed) { $nic.LinkSpeed.Duplex } else { $null }
                Driver     = $nic.ExtensionData.Driver
                Pci        = $nic.Pci
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
                LinkUp            = $null -ne $nic.LinkSpeed
                SpeedMb           = if ($nic.LinkSpeed) { $nic.LinkSpeed.SpeedMb } else { $null }
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
                Enabled        = $vmk.Enabled
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
            [pscustomobject]@{
                VDSwitch      = $switch.Name
                Portgroup     = $portgroup.Name
                Vlan          = ($portgroup.VlanConfiguration | Out-String).Trim()
                NumPorts      = $portgroup.NumPorts
                PortBinding   = $portgroup.PortBinding
                ActiveUplink  = (
                    $portgroup.ExtensionData.Config.DefaultPortConfig.
                        UplinkTeamingPolicy.UplinkPortOrder.ActiveUplinkPort -join ','
                )
                StandbyUplink = (
                    $portgroup.ExtensionData.Config.DefaultPortConfig.
                        UplinkTeamingPolicy.UplinkPortOrder.StandbyUplinkPort -join ','
                )
                LoadBalance   = (
                    $portgroup.ExtensionData.Config.DefaultPortConfig.
                        UplinkTeamingPolicy.Policy.Value
                )
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

    if (-not (Get-Command Get-VsanClusterHealth -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{
            Status = 'UNKNOWN'
            Note   = 'Get-VsanClusterHealth is unavailable in the installed PowerCLI version.'
        }
    }

    try {
        return Get-VsanClusterHealth -Cluster $Cluster
    }
    catch {
        return [pscustomobject]@{
            Status = 'ERROR'
            Note   = $_.Exception.Message
        }
    }
}

function Get-VsanResyncSafe {
    param([Parameter(Mandatory)]$Cluster)

    if (-not (Get-Command Get-VsanResyncingOverview -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{
            Status = 'UNKNOWN'
            Note   = 'Get-VsanResyncingOverview is unavailable in the installed PowerCLI version.'
        }
    }

    try {
        return Get-VsanResyncingOverview -Cluster $Cluster
    }
    catch {
        return [pscustomobject]@{
            Status = 'ERROR'
            Note   = $_.Exception.Message
        }
    }
}

function Test-VsanVmkConnectivity {
    param(
        [Parameter(Mandatory)]$SourceHost,
        [Parameter(Mandatory)]$AllHosts,
        [int]$PingCount = 5
    )

    $sourceVmk = Get-VMHostNetworkAdapter -VMHost $SourceHost -VMKernel |
        Where-Object VsanTrafficEnabled |
        Select-Object -First 1

    if (-not $sourceVmk) {
        return [pscustomobject]@{
            SourceHost = $SourceHost.Name
            Result     = 'FAIL'
            Detail     = 'No vSAN VMkernel adapter was found.'
        }
    }

    $esxcli = Get-EsxCli -VMHost $SourceHost -V2

    foreach ($targetHost in ($AllHosts | Where-Object Name -ne $SourceHost.Name)) {
        $targetVmk = Get-VMHostNetworkAdapter -VMHost $targetHost -VMKernel |
            Where-Object VsanTrafficEnabled |
            Select-Object -First 1

        if (-not $targetVmk) {
            [pscustomobject]@{
                SourceHost = $SourceHost.Name
                TargetHost = $targetHost.Name
                Result     = 'FAIL'
                Detail     = 'Target host has no vSAN VMkernel adapter.'
            }

            continue
        }

        $arguments = $esxcli.network.diag.ping.CreateArgs()
        $arguments.host = $targetVmk.IP
        $arguments.interface = $sourceVmk.Name
        $arguments.count = $PingCount
        $arguments.size = 1472

        try {
            $result = $esxcli.network.diag.ping.Invoke($arguments)

            $lossPercent = if ($result.Transmitted -gt 0) {
                [math]::Round(
                    (1 - ($result.Received / $result.Transmitted)) * 100,
                    2
                )
            }
            else {
                100
            }

            [pscustomobject]@{
                SourceHost  = $SourceHost.Name
                SourceVmk   = $sourceVmk.Name
                SourceIP    = $sourceVmk.IP
                TargetHost  = $targetHost.Name
                TargetIP    = $targetVmk.IP
                Received    = $result.Received
                Transmitted = $result.Transmitted
                LossPercent = $lossPercent
                Result      = if ($lossPercent -eq 0) { 'PASS' } else { 'FAIL' }
                Detail      = $null
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
            default { 'warn' }
        }

        "<tr class='$class'><td>$($check.Result)</td><td>$($check.Check)</td><td>$($check.Detail)</td></tr>"
    }

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
<title>$Title</title>
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
</style>
</head>
<body>
<h1>$Title</h1>
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

    $checks.Add([pscustomobject]@{
        Check  = 'Host overall status'
        Result = if ($view.OverallStatus -eq 'green') { 'PASS' } else { 'FAIL' }
        Detail = $view.OverallStatus
    })

    foreach ($nic in (Get-PhysicalNicDetail -Hosts @($TargetHost))) {
        $checks.Add([pscustomobject]@{
            Check  = "Physical NIC $($nic.Device)"
            Result = if ($nic.LinkUp) { 'PASS' } else { 'FAIL' }
            Detail = "Link=$($nic.LinkUp); SpeedMb=$($nic.SpeedMb); MAC=$($nic.Mac)"
        })
    }

    foreach ($neighbor in (Get-PhysicalNicNeighbor -Hosts @($TargetHost))) {
        $checks.Add([pscustomobject]@{
            Check  = "LLDP/CDP $($neighbor.Pnic)"
            Result = if ($neighbor.DiscoveryProtocol -eq 'NONE_DETECTED') { 'WARN' } else { 'PASS' }
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
                "Target=$($ping.TargetIP); Loss=$($ping.LossPercent)%"
            }
        })
    }

    $resync = Get-VsanResyncSafe -Cluster $Cluster
    $resyncText = ($resync | Out-String).Trim()

    $checks.Add([pscustomobject]@{
        Check  = 'vSAN resynchronisation'
        Result = if ($resyncText -match 'ERROR') {
            'FAIL'
        }
        elseif ($resyncText -match 'UNKNOWN') {
            'WARN'
        }
        else {
            'REVIEW'
        }
        Detail = $resyncText
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

        $targetHosts = if ($Mode -eq 'ValidateHostMove') {
            @($selectedHost)
        }
        else {
            $allHosts
        }

        $run = New-RunContext `
            -Mode $Mode `
            -VCenterName $vCenterName `
            -ClusterName $clusterName `
            -HostName $(if ($selectedHost) { $selectedHost.Name } else { $null })

        Get-DistributedPortgroupDetail -VCenterName $vCenterName |
            Export-CsvSafe -Path (Join-Path $run.ClusterFolder 'VDS-Portgroups.csv')

        Get-RecentCriticalEvents -Entity $cluster -Hours 24 |
            Export-CsvSafe -Path (Join-Path $run.ClusterFolder 'Recent-Warnings-Errors.csv')

        Get-VsanHealthSafe -Cluster $cluster |
            Export-Clixml -Path (Join-Path $run.ClusterFolder 'vSAN-Health.xml')

        Get-VsanResyncSafe -Cluster $cluster |
            Export-Clixml -Path (Join-Path $run.ClusterFolder 'vSAN-Resync.xml')

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

            Write-HtmlReport `
                -Title "$($hostObject.Name) - $Mode - $clusterName" `
                -Checks $checks `
                -Path (
                    Join-Path `
                        $hostFolder `
                        "$((ConvertTo-SafeFileName $hostObject.Name))-Report.html"
                )
        }

        $manifest = [pscustomobject]@{
            EnvironmentKey = $EnvironmentKey
            DisplayName    = $environment.DisplayName
            VCenter        = $vCenterName
            Cluster        = $clusterName
            Mode           = $Mode
            HostName       = if ($selectedHost) { $selectedHost.Name } else { $null }
            BaselinePath   = $baselinePath
            HostCount      = $targetHosts.Count
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

        return [pscustomobject]@{
            Environment = $EnvironmentKey
            VCenter     = $vCenterName
            Cluster     = $clusterName
            Mode        = $Mode
            Result      = 'COMPLETED'
            HostCount   = $targetHosts.Count
            Detail      = $null
            Output      = $run.RunRoot
        }
    }
    catch {
        Write-Warning "Validation failed for $clusterName on $vCenterName."
        Write-Warning $_.Exception.Message

        return [pscustomobject]@{
            Environment = $EnvironmentKey
            VCenter     = $vCenterName
            Cluster     = $clusterName
            Mode        = $Mode
            Result      = 'FAILED'
            HostCount   = 0
            Detail      = $_.Exception.Message
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
