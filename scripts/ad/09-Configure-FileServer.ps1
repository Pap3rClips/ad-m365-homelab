#Requires -Version 5.1

<#
.SYNOPSIS
    Configure SRV01 en serveur de fichiers : dossiers, droits NTFS (AGDLP) et partages SMB.

.DESCRIPTION
    À lancer SUR SRV01 une fois la machine jointe au domaine (script 07), avec un compte
    administrateur du domaine.
    - Rôle FS-FileServer
    - Héritage NTFS coupé : SYSTEM et Administrateurs en contrôle total, groupes DL-* en
      modification ou lecture. Les utilisateurs n'ont jamais de droits directs.
    - Partage SMB : « Modifier » pour les utilisateurs authentifiés, le filtrage réel est fait
      par NTFS ; énumération basée sur l'accès (ABE) ; chiffrement SMB activé.
    Les noms de comptes intégrés sont résolus par SID : le script fonctionne sur un Windows
    en français comme en anglais.

.EXAMPLE
    .\09-Configure-FileServer.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../modules/LabCommon/LabCommon.psm1') -Force
Assert-LabAdministrator
$config = if ($ConfigPath) { Import-LabConfig -Path $ConfigPath } else { Import-LabConfig }
$nb = $config.Domain.NetBIOS

if ($env:COMPUTERNAME -ne $config.FileServer) {
    throw "Ce script doit être lancé sur $($config.FileServer) (machine actuelle : $env:COMPUTERNAME)."
}

function Resolve-Sid([string]$Sid) {
    ([Security.Principal.SecurityIdentifier]$Sid).Translate([Security.Principal.NTAccount]).Value
}
$system        = Resolve-Sid 'S-1-5-18'
$administrators = Resolve-Sid 'S-1-5-32-544'
$authenticated = Resolve-Sid 'S-1-5-11'

if (-not (Get-WindowsFeature -Name FS-FileServer).Installed -and $PSCmdlet.ShouldProcess('FS-FileServer', 'Install-WindowsFeature')) {
    Install-WindowsFeature -Name FS-FileServer -IncludeManagementTools | Out-Null
    Write-LabLog 'Rôle Serveur de fichiers installé' -Level OK
}

foreach ($share in $config.FileShares) {
    $drive = Split-Path -Path $share.Path -Qualifier
    if (-not (Test-Path -Path "$drive\")) {
        throw "Le volume $drive n'existe pas sur $env:COMPUTERNAME. Ajoute un second disque à la VM (Initialize-Disk / New-Partition) ou modifie Path dans lab.psd1."
    }

    # --- Dossier ---------------------------------------------------------------------
    if (-not (Test-Path -Path $share.Path) -and $PSCmdlet.ShouldProcess($share.Path, 'Créer le dossier')) {
        New-Item -Path $share.Path -ItemType Directory -Force | Out-Null
        Write-LabLog "Dossier créé : $($share.Path)" -Level OK
    }

    # --- NTFS ------------------------------------------------------------------------
    if ($PSCmdlet.ShouldProcess($share.Path, 'Appliquer les ACL NTFS')) {
        $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        $prop    = [Security.AccessControl.PropagationFlags]::None
        $allow   = [Security.AccessControl.AccessControlType]::Allow
        $acl = New-Object -TypeName Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)   # coupe l'héritage, sans recopier les ACE héritées
        $acl.SetOwner([Security.Principal.NTAccount]$administrators)

        $rules = @(
            @($system, 'FullControl'),
            @($administrators, 'FullControl'),
            @("$nb\$($share.Modify)", 'Modify')
        )
        if ($share.Read) { $rules += , @("$nb\$($share.Read)", 'ReadAndExecute') }

        foreach ($r in $rules) {
            $acl.AddAccessRule((New-Object -TypeName Security.AccessControl.FileSystemAccessRule -ArgumentList $r[0], $r[1], $inherit, $prop, $allow))
        }
        Set-Acl -Path $share.Path -AclObject $acl
        Write-LabLog "NTFS $($share.Path) : $(($rules | ForEach-Object { "$($_[0])=$($_[1])" }) -join ' ; ')" -Level OK
    }

    # --- Partage SMB --------------------------------------------------------------------
    if (Get-SmbShare -Name $share.Name -ErrorAction SilentlyContinue) {
        Write-LabLog "Partage \\$env:COMPUTERNAME\$($share.Name) déjà présent" -Level SKIP
    }
    elseif ($PSCmdlet.ShouldProcess($share.Name, 'New-SmbShare')) {
        New-SmbShare -Name $share.Name -Path $share.Path `
            -FullAccess $administrators -ChangeAccess $authenticated `
            -FolderEnumerationMode AccessBased -EncryptData $true `
            -Description "Partage $($share.Name) - lab" | Out-Null
        Write-LabLog "Partage créé : \\$env:COMPUTERNAME\$($share.Name) (ABE + chiffrement SMB)" -Level OK
    }
}

# SMBv1 coupé localement en plus de la GPO (effet immédiat)
if ((Get-SmbServerConfiguration).EnableSMB1Protocol -and $PSCmdlet.ShouldProcess('SMB', 'Désactiver SMBv1')) {
    Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force
    Write-LabLog 'SMBv1 désactivé' -Level OK
}

Get-SmbShare | Where-Object { $_.Name -in $config.FileShares.Name } |
    Format-Table Name, Path, FolderEnumerationMode, EncryptData -AutoSize
