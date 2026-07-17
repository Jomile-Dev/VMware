# VCF on VxRail Validation Toolkit

## Purpose

This is a read-only, menu-driven PowerCLI validation framework for five VCF on VxRail domains:

- Management: `abc21-m01-cl01`
- Workload 01: `abc21-w01-cl01`
- Workload 02: `abc21-w02-cl01`
- Workload 03: `abc21-w03-cl01`
- Workload 04: `abc21-w04-cl01`

The real vCenter names should be entered in the **Environment Configuration** section near the top of the PowerShell script.

## Authentication

The script prompts once:

```powershell
$Credential = Get-Credential -Message 'Enter vCenter credentials'
```

The same credential is reused for each selected vCenter.

A credential can also be supplied when launching the script:

```powershell
$Credential = Get-Credential

.\Test-VcfVxRailValidation.ps1 `
  -Credential $Credential `
  -OutputRoot C:\VCF-Validation
```

## Run the script

```powershell
.\Test-VcfVxRailValidation.ps1
```

Optional:

```powershell
.\Test-VcfVxRailValidation.ps1 `
  -OutputRoot C:\VCF-Validation `
  -SkipCertificateCheck
```

## Operation menu

```text
1. Standard sanity check
2. Create baseline
3. Validate relocated host
4. Post-migration validation
5. Exit
```

## Cluster selection

The script shows all configured clusters:

```text
1. abc21-m01-cl01
2. abc21-w01-cl01
3. abc21-w02-cl01
4. abc21-w03-cl01
5. abc21-w04-cl01
A. All clusters
```

Examples:

- `1` checks Management only.
- `3` checks Workload 02 only.
- `1,3,5` checks three selected clusters.
- `A` checks all five clusters.

## Host scope

### Standard sanity check

Validates every ESXi host in every selected cluster.

### Create baseline

Captures every ESXi host in every selected cluster.

### Validate relocated host

Connects to the selected cluster, displays the hosts in that cluster, and asks the operator to choose one host. Only that host is validated against its baseline.

### Post-migration validation

Validates every ESXi host in every selected cluster and compares each host with its baseline.

## Evidence collected

Per cluster:

- distributed port groups
- recent warning and error events
- vSAN health
- vSAN resynchronisation state

Per host:

- host summary
- physical NIC state
- physical NIC speed and MAC
- LLDP/CDP neighbour data
- VMkernel interfaces
- vSAN, vMotion and management VMkernel roles
- distributed switch uplink mappings
- virtual machine network mappings
- vSAN VMkernel ping checks
- baseline differences
- readiness checks
- HTML summary report

## Output structure

```text
C:\VCF-Validation
├── Sanity-Checks
│   └── vcenter-name
│       └── cluster-name
│           └── YYYYMMDD-HHMMSS
│               ├── Cluster
│               └── Hosts
│                   ├── esx01
│                   ├── esx02
│                   └── esx03
├── Baselines
│   └── vcenter-name
│       └── cluster-name
│           └── YYYYMMDD-HHMMSS
├── Migration
│   └── vcenter-name
│       └── cluster-name
│           ├── Hosts
│           └── Post-Migration
└── Run-Summaries
```

## Baseline path

Relocated-host and post-migration validation require the complete baseline folder for the relevant vCenter and cluster.

Example:

```text
C:\VCF-Validation\Baselines\test-w02-vc.test.test\abc21-w02-cl01\20260717-140000
```

## Important limitations

- The script is read-only.
- It does not place hosts into maintenance mode.
- It does not remove hosts from maintenance mode.
- It does not change networking or vSAN configuration.
- A missing LLDP/CDP neighbour is reported as `WARN`, because LLDP/CDP may be disabled.
- PowerCLI vSAN cmdlet availability varies by installed version.
- Review the baseline before treating it as authoritative.
- Test the toolkit against the exact production versions before relying on it during a migration.
