<#
    Host-state guard patch for Test-VcfVxRailValidation.ps1

    Purpose:
        Stop the run aborting when a host is Disconnected / NotResponding /
        powered off. Live host calls (Get-VMHostNetworkAdapter, QueryNetworkHint,
        Get-EsxCli) only work when ConnectionState is Connected or Maintenance;
        any other state returns the fault:
            "the host must be in one of the following states: Connected, Maintenance"

    How to apply:
        1. Paste Test-HostQueryable near your other small helpers
           (e.g. just after ConvertTo-SafeFileName).
        2. Replace these four existing functions with the versions below:
               Get-PhysicalNicDetail
               Get-PhysicalNicNeighbor
               Get-VmkDetail
               Test-VsanVmkConnectivity

    Unreachable hosts are skipped with a console warning and still appear in
    Host-Summary.csv (that data comes from cached Get-View, not a live call).
#>

# -----------------------------------------------------------------------------
# NEW HELPER - paste near ConvertTo-SafeFileName
# -----------------------------------------------------------------------------
function Test-HostQueryable {
    param([Parameter(Mandatory)]$HostObject)
    # Live host queries are only permitted when the host is Connected or in Maintenance.
    return ([string]$HostObject.ConnectionState -in @('Connected', 'Maintenance'))
}

# -----------------------------------------------------------------------------
# REPLACES: Get-PhysicalNicDetail
# -----------------------------------------------------------------------------
function Get-PhysicalNicDetail {
    param([Parameter(Mandatory)]$Hosts)

    foreach ($hostObject in $Hosts) {
        if (-not (Test-HostQueryable -HostObject $hostObject)) {
            Write-Warning ("Skipping physical NIC query for {0}: connection state is {1}." -f $hostObject.Name, $hostObject.ConnectionState)
            continue
        }

        try {
            $nics = @(Get-VMHostNetworkAdapter -VMHost $hostObject -Physical -ErrorAction Stop | Sort-Object Name)
        }
        catch {
            Write-Warning ("Could not read physical NICs for {0}: {1}" -f $hostObject.Name, $_.Exception.Message)
            continue
        }

        foreach ($nic in $nics) {
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

# -----------------------------------------------------------------------------
# REPLACES: Get-PhysicalNicNeighbor
# -----------------------------------------------------------------------------
function Get-PhysicalNicNeighbor {
    param([Parameter(Mandatory)]$Hosts)

    foreach ($hostObject in $Hosts) {
        if (-not (Test-HostQueryable -HostObject $hostObject)) {
            Write-Warning ("Skipping LLDP/CDP query for {0}: connection state is {1}." -f $hostObject.Name, $hostObject.ConnectionState)
            continue
        }

        try {
            $networkSystem = Get-View -Id $hostObject.ExtensionData.ConfigManager.NetworkSystem -ErrorAction Stop
            $hints        = @($networkSystem.QueryNetworkHint($null))
            $physicalNics = @(Get-VMHostNetworkAdapter -VMHost $hostObject -Physical -ErrorAction Stop | Sort-Object Name)
        }
        catch {
            Write-Warning ("Could not read switch neighbour data for {0}: {1}" -f $hostObject.Name, $_.Exception.Message)
            continue
        }

        foreach ($nic in $physicalNics) {
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

# -----------------------------------------------------------------------------
# REPLACES: Get-VmkDetail
# -----------------------------------------------------------------------------
function Get-VmkDetail {
    param([Parameter(Mandatory)]$Hosts)

    foreach ($hostObject in $Hosts) {
        if (-not (Test-HostQueryable -HostObject $hostObject)) {
            Write-Warning ("Skipping VMkernel query for {0}: connection state is {1}." -f $hostObject.Name, $hostObject.ConnectionState)
            continue
        }

        try {
            $vmks = @(Get-VMHostNetworkAdapter -VMHost $hostObject -VMKernel -ErrorAction Stop | Sort-Object Name)
        }
        catch {
            Write-Warning ("Could not read VMkernel adapters for {0}: {1}" -f $hostObject.Name, $_.Exception.Message)
            continue
        }

        foreach ($vmk in $vmks) {
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

# -----------------------------------------------------------------------------
# REPLACES: Test-VsanVmkConnectivity
# -----------------------------------------------------------------------------
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
        if (-not (Test-HostQueryable -HostObject $targetHost)) {
            [pscustomobject]@{
                SourceHost = $SourceHost.Name
                TargetHost = $targetHost.Name
                Result     = 'SKIP'
                Detail     = "Target host connection state is $($targetHost.ConnectionState); skipped."
            }
            continue
        }

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

        $netstackKey = $sourceVmk.ExtensionData.Spec.NetStackInstanceKey
        if ($netstackKey) {
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

            $summary = if ($result.PSObject.Properties['Summary'] -and $result.Summary) {
                $result.Summary
            }
            else {
                $result
            }

            $transmitted = if ($summary.PSObject.Properties['Transmitted']) {
                [int]$summary.Transmitted
            }
            else {
                0
            }

            $received = if ($summary.PSObject.Properties['Received']) {
                [int]$summary.Received
            }
            elseif ($summary.PSObject.Properties['Recieved']) {
                [int]$summary.Recieved
            }
            else {
                0
            }

            $lossPercent = if ($transmitted -gt 0) {
                [math]::Round((1 - ($received / $transmitted)) * 100, 2)
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
                Received    = $received
                Transmitted = $transmitted
                LossPercent = $lossPercent
                Result      = if ($lossPercent -eq 0) { 'PASS' } else { 'FAIL' }
                Detail      = $null
            }
        }
        catch {
            [pscustomobject]@{
                SourceHost  = $SourceHost.Name
                SourceVmk   = $sourceVmk.Name
                SourceIP    = $sourceVmk.IP
                TargetHost  = $targetHost.Name
                TargetIP    = $targetVmk.IP
                Result      = 'ERROR'
                Detail      = $_.Exception.Message
            }
        }
    }
}
