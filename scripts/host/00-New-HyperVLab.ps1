#Requires -Version 5.1
#Requires -Modules Hyper-V

<#
.SYNOPSIS
    Crée l'infrastructure du lab sur l'hôte Hyper-V : commutateur interne, NAT vers Internet
    et les cinq machines virtuelles (DC01, SRV01, CLT01, CLT02, CLT-CLOUD01).

.DESCRIPTION
    - Commutateur interne + adresse de passerelle sur l'hôte + NAT (accès Internet des VM,
      indispensable pour le tenant Microsoft 365 et Windows Update)
    - VM génération 2 : démarrage sécurisé, vTPM (exigé par Windows 11 et par la stratégie
      de conformité Intune), disque dynamique, ISO montée, démarrage sur le DVD
    - SRV01 reçoit un second disque pour les partages (D:)
    - CLT02 reçoit une adresse MAC fixe, cohérente avec la réservation DHCP de lab.psd1
    Les VM ne sont pas démarrées : installe ensuite Windows sur chacune.

.EXAMPLE
    .\00-New-HyperVLab.ps1 -WhatIf
    .\00-New-HyperVLab.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../modules/LabCommon/LabCommon.psm1') -Force
Assert-LabAdministrator
$config = if ($ConfigPath) { Import-LabConfig -Path $ConfigPath } else { Import-LabConfig }
$hv  = $config.HyperV
$net = $config.Network

foreach ($kind in $hv.Iso.Keys) {
    if (-not (Test-Path -Path $hv.Iso[$kind])) {
        throw "ISO $kind introuvable : $($hv.Iso[$kind]). Télécharge-la depuis le Microsoft Evaluation Center et corrige HyperV.Iso dans lab.psd1."
    }
}

# --- Commutateur et NAT ---------------------------------------------------------------------
if (Get-VMSwitch -Name $hv.SwitchName -ErrorAction SilentlyContinue) {
    Write-LabLog "Commutateur $($hv.SwitchName) déjà présent" -Level SKIP
}
elseif ($PSCmdlet.ShouldProcess($hv.SwitchName, 'New-VMSwitch -SwitchType Internal')) {
    New-VMSwitch -Name $hv.SwitchName -SwitchType Internal | Out-Null
    Write-LabLog "Commutateur interne $($hv.SwitchName) créé" -Level OK
}

$hostAlias = "vEthernet ($($hv.SwitchName))"
if (-not (Get-NetIPAddress -InterfaceAlias $hostAlias -IPAddress $net.Gateway -ErrorAction SilentlyContinue)) {
    if ($PSCmdlet.ShouldProcess($hostAlias, "IP $($net.Gateway)/$($net.PrefixLength)")) {
        New-NetIPAddress -InterfaceAlias $hostAlias -IPAddress $net.Gateway -PrefixLength $net.PrefixLength | Out-Null
        Write-LabLog "Passerelle du lab sur l'hôte : $($net.Gateway)" -Level OK
    }
}

$prefix = "$($net.NetworkId)/$($net.PrefixLength)"
if (Get-NetNat -Name $hv.NatName -ErrorAction SilentlyContinue) {
    Write-LabLog "NAT $($hv.NatName) déjà présent" -Level SKIP
}
elseif ($PSCmdlet.ShouldProcess($prefix, 'New-NetNat')) {
    New-NetNat -Name $hv.NatName -InternalIPInterfaceAddressPrefix $prefix | Out-Null
    Write-LabLog "NAT $($hv.NatName) : $prefix -> Internet" -Level OK
}

# --- Machines virtuelles -------------------------------------------------------------------------
foreach ($vm in $hv.VMs) {
    if (Get-VM -Name $vm.Name -ErrorAction SilentlyContinue) {
        Write-LabLog "VM $($vm.Name) déjà présente" -Level SKIP
        continue
    }
    if (-not $PSCmdlet.ShouldProcess($vm.Name, "Créer la VM ($($vm.MemoryGB) Go, $($vm.Cpu) vCPU, $($vm.DiskGB) Go)")) { continue }

    $vmDir = Join-Path -Path $hv.VMPath -ChildPath $vm.Name
    $vhd = Join-Path -Path $vmDir -ChildPath "$($vm.Name)-OS.vhdx"
    New-Item -Path $vmDir -ItemType Directory -Force | Out-Null
    New-VM -Name $vm.Name -Generation 2 -Path $hv.VMPath -MemoryStartupBytes ([int64]$vm.MemoryGB * 1GB) `
        -NewVHDPath $vhd -NewVHDSizeBytes ([int64]$vm.DiskGB * 1GB) -SwitchName $hv.SwitchName | Out-Null
    Set-VM -Name $vm.Name -ProcessorCount $vm.Cpu -DynamicMemory -MemoryMinimumBytes 2GB `
        -MemoryMaximumBytes ([int64]$vm.MemoryGB * 1GB) -AutomaticCheckpointsEnabled $false `
        -CheckpointType Production

    # Démarrage sécurisé + vTPM (Windows 11, BitLocker, conformité Intune)
    Set-VMFirmware -VMName $vm.Name -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows
    Set-VMKeyProtector -VMName $vm.Name -NewLocalKeyProtector
    Enable-VMTPM -VMName $vm.Name

    $dvd = Add-VMDvdDrive -VMName $vm.Name -Path $hv.Iso[$vm.Iso] -Passthru
    Set-VMFirmware -VMName $vm.Name -FirstBootDevice $dvd

    if ($vm.ContainsKey('MacAddress')) {
        Set-VMNetworkAdapter -VMName $vm.Name -StaticMacAddress $vm.MacAddress
    }
    if ($vm.ContainsKey('DataDiskGB')) {
        $data = Join-Path -Path $vmDir -ChildPath "$($vm.Name)-DATA.vhdx"
        New-VHD -Path $data -SizeBytes ([int64]$vm.DataDiskGB * 1GB) -Dynamic | Out-Null
        Add-VMHardDiskDrive -VMName $vm.Name -Path $data
    }
    Write-LabLog "VM $($vm.Name) créée (Gen2, Secure Boot, vTPM)" -Level OK
}

Get-VM | Where-Object Name -In $hv.VMs.Name | Format-Table Name, State, ProcessorCount,
    @{ n = 'RAM max (Go)'; e = { $_.MemoryMaximum / 1GB } } -AutoSize
Write-LabLog 'Installe Windows sur chaque VM, puis lance scripts/ad/01-Prepare-DC.ps1 sur DC01.' -Level OK
