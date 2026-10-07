#Requires -Version 5.1

<#
.SYNOPSIS
    Outils GPO pour ce que le module GroupPolicy ne sait pas faire seul :
    modèles de sécurité (GptTmpl.inf) et préférences de lecteurs réseau (Drives.xml).

.DESCRIPTION
    Set-GPRegistryValue ne couvre que les modèles d'administration (Registry.pol).
    Les options de sécurité, l'audit et l'appartenance aux groupes locaux sont stockés
    dans GptTmpl.inf ; les mappages de lecteurs dans Drives.xml. Écrire ces fichiers dans
    SYSVOL ne suffit pas : il faut aussi déclarer l'extension côté client (gPC*ExtensionNames)
    et incrémenter la version de la GPO dans AD et dans GPT.INI, sinon les clients ignorent
    la modification. Ce module s'en charge.

    Les fonctions New-* et Merge-* sont pures (aucun accès AD) et couvertes par les tests Pester.
#>

Set-StrictMode -Version Latest

# GUID des extensions côté client (CSE) et des outils d'édition associés
$script:Cse = @{
    # Paramètres de sécurité : extension + composant logiciel d'édition
    Security = '[{827D319E-6EAC-11D2-A4EA-00C04F79F83A}{803E14A0-B4FB-11D0-A0D0-00A0C90F574B}]'
    # Préférences « Lecteurs mappés » : entrée du noyau GPP + extension Drive Maps
    Drives   = '[{00000000-0000-0000-0000-000000000000}{2EA1A81B-48E5-45E9-8BB7-A6E3AC170006}]' +
               '[{5794DAFD-BE60-433F-88A2-1A31939AC01A}{2EA1A81B-48E5-45E9-8BB7-A6E3AC170006}]'
}

function Merge-LabGpoExtension {
    <#
    .SYNOPSIS
        Fusionne des blocs « [{CSE}{outil}...] » dans la valeur gPC*ExtensionNames existante.
        Les CSE sont triées et dédoublonnées, comme le fait la console GPMC.
    .EXAMPLE
        Merge-LabGpoExtension -Existing '[{B}{1}]' -Add '[{A}{2}][{B}{3}]'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()][AllowNull()][string]$Existing,
        [Parameter(Mandatory)][string]$Add
    )
    $map = [ordered]@{}
    foreach ($source in @($Existing, $Add)) {
        if (-not $source) { continue }
        foreach ($block in [regex]::Matches($source, '\[[^\]]*\]')) {
            $guids = @([regex]::Matches($block.Value, '\{[^}]+\}') | ForEach-Object { $_.Value.ToUpperInvariant() })
            if ($guids.Count -eq 0) { continue }
            $cse = $guids[0]
            if (-not $map.Contains($cse)) { $map[$cse] = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal) }
            foreach ($tool in ($guids | Select-Object -Skip 1)) { [void]$map[$cse].Add($tool) }
        }
    }
    $sorted = $map.Keys | Sort-Object { $_ } -CaseSensitive
    -join ($sorted | ForEach-Object { '[' + $_ + (-join $map[$_]) + ']' })
}

function New-LabSecurityTemplate {
    <#
    .SYNOPSIS
        Construit le contenu d'un GptTmpl.inf à partir d'un dictionnaire de sections.
    .EXAMPLE
        New-LabSecurityTemplate -Sections @{ 'System Access' = [ordered]@{ EnableGuestAccount = 0 } }
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Fonction pure : ne modifie aucun état')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][Collections.IDictionary]$Sections)

    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('[Unicode]'); $lines.Add('Unicode=yes')
    $lines.Add('[Version]'); $lines.Add('signature="$CHICAGO$"'); $lines.Add('Revision=1')
    foreach ($section in $Sections.Keys) {
        $lines.Add("[$section]")
        foreach ($key in $Sections[$section].Keys) {
            $lines.Add("$key = $($Sections[$section][$key])")
        }
    }
    ($lines -join "`r`n") + "`r`n"
}

function New-LabDrivesXml {
    <#
    .SYNOPSIS
        Construit un Drives.xml (préférences GPO) : un lecteur par entrée,
        avec ciblage optionnel sur un ou plusieurs groupes (OU logique).
    .PARAMETER Drives
        Objets avec Letter, Path, Label et Groups (tableau de @{ Name; Sid }).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Fonction pure : ne modifie aucun état')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object[]]$Drives)

    $changed = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $sb = [Text.StringBuilder]::new()
    [void]$sb.AppendLine('<?xml version="1.0" encoding="utf-8"?>')
    [void]$sb.AppendLine('<Drives clsid="{8FDDCC1A-0C3C-43cd-A6B4-71A6DF20DA8C}">')
    foreach ($d in $Drives) {
        $letter = $d.Letter.ToUpperInvariant()
        $uid = '{' + [guid]::NewGuid().ToString().ToUpperInvariant() + '}'
        $label = [Security.SecurityElement]::Escape($d.Label)
        $path  = [Security.SecurityElement]::Escape($d.Path)
        [void]$sb.AppendLine(('  <Drive clsid="{{935D1B74-9CB8-4e3c-9914-7DD559B7A417}}" name="{0}:" status="{0}:" image="2" changed="{1}" uid="{2}" bypassErrors="1">' -f $letter, $changed, $uid))
        [void]$sb.AppendLine(('    <Properties action="U" thisDrive="NOCHANGE" allDrives="NOCHANGE" userName="" path="{0}" label="{1}" persistent="1" useLetter="1" letter="{2}"/>' -f $path, $label, $letter))
        $groups = @($d.Groups)
        if ($groups.Count -gt 0) {
            [void]$sb.AppendLine('    <Filters>')
            $first = $true
            foreach ($g in $groups) {
                # Premier filtre en AND, suivants en OR : « membre de A OU de B »
                $bool = if ($first) { 'AND' } else { 'OR' }
                $name = [Security.SecurityElement]::Escape($g.Name)
                [void]$sb.AppendLine(('      <FilterGroup bool="{0}" not="0" name="{1}" sid="{2}" userContext="1" primaryGroup="0" localGroup="0"/>' -f $bool, $name, $g.Sid))
                $first = $false
            }
            [void]$sb.AppendLine('    </Filters>')
        }
        [void]$sb.AppendLine('  </Drive>')
    }
    [void]$sb.Append('</Drives>')
    $sb.ToString()
}

function Get-LabGpoSysvolPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][Microsoft.GroupPolicy.Gpo]$Gpo
    )
    '\\{0}\SYSVOL\{0}\Policies\{{{1}}}' -f $Gpo.DomainName, $Gpo.Id.ToString().ToUpperInvariant()
}

function Update-LabGpoVersion {
    <#
    .SYNOPSIS
        Incrémente la version (ordinateur ou utilisateur) d'une GPO dans AD et dans GPT.INI,
        et déclare l'extension côté client correspondante.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][Microsoft.GroupPolicy.Gpo]$Gpo,
        [Parameter(Mandatory)][ValidateSet('Machine', 'User')][string]$Scope,
        [Parameter(Mandatory)][string]$Extension
    )
    $domainDN = (Get-ADDomain -Identity $Gpo.DomainName).DistinguishedName
    $dn = 'CN={{{0}}},CN=Policies,CN=System,{1}' -f $Gpo.Id.ToString().ToUpperInvariant(), $domainDN
    $attr = if ($Scope -eq 'Machine') { 'gPCMachineExtensionNames' } else { 'gPCUserExtensionNames' }
    $obj = Get-ADObject -Identity $dn -Properties versionNumber, $attr

    # versionNumber : 16 bits de poids fort = utilisateur, 16 bits de poids faible = ordinateur
    $increment = if ($Scope -eq 'Machine') { 1 } else { 65536 }
    $newVersion = [int]$obj.versionNumber + $increment
    $current = if ($obj.PropertyNames -contains $attr) { [string]$obj.$attr } else { '' }
    $merged = Merge-LabGpoExtension -Existing $current -Add $Extension

    if ($PSCmdlet.ShouldProcess($Gpo.DisplayName, "Version $($obj.versionNumber) -> $newVersion")) {
        Set-ADObject -Identity $dn -Replace @{ versionNumber = $newVersion; $attr = $merged }
        $gptIni = Join-Path -Path (Get-LabGpoSysvolPath -Gpo $Gpo) -ChildPath 'GPT.INI'
        $content = if (Test-Path -Path $gptIni) { Get-Content -Path $gptIni -Raw } else { "[General]`r`n" }
        if ($content -match '(?m)^Version=\d+') {
            $content = $content -replace '(?m)^Version=\d+', "Version=$newVersion"
        }
        else {
            $content = $content.TrimEnd() + "`r`nVersion=$newVersion`r`n"
        }
        Set-Content -Path $gptIni -Value $content -Encoding ASCII -NoNewline
    }
}

function Set-LabGpoSecurityTemplate {
    <# .SYNOPSIS Écrit GptTmpl.inf dans la GPO et publie la modification. #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][Microsoft.GroupPolicy.Gpo]$Gpo,
        [Parameter(Mandatory)][Collections.IDictionary]$Sections
    )
    $dir = Join-Path -Path (Get-LabGpoSysvolPath -Gpo $Gpo) -ChildPath 'Machine\Microsoft\Windows NT\SecEdit'
    $file = Join-Path -Path $dir -ChildPath 'GptTmpl.inf'
    $content = New-LabSecurityTemplate -Sections $Sections

    if ((Test-Path -Path $file) -and ((Get-Content -Path $file -Raw -Encoding Unicode) -eq $content)) {
        return $false   # rien à faire
    }
    if ($PSCmdlet.ShouldProcess($Gpo.DisplayName, 'Écrire GptTmpl.inf')) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
        Set-Content -Path $file -Value $content -Encoding Unicode -NoNewline
        Update-LabGpoVersion -Gpo $Gpo -Scope Machine -Extension $script:Cse.Security
    }
    $true
}

function Set-LabGpoDriveMap {
    <# .SYNOPSIS Écrit Drives.xml (configuration utilisateur) et publie la modification. #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][Microsoft.GroupPolicy.Gpo]$Gpo,
        [Parameter(Mandatory)][object[]]$Drives
    )
    $dir = Join-Path -Path (Get-LabGpoSysvolPath -Gpo $Gpo) -ChildPath 'User\Preferences\Drives'
    $file = Join-Path -Path $dir -ChildPath 'Drives.xml'
    if ($PSCmdlet.ShouldProcess($Gpo.DisplayName, 'Écrire Drives.xml')) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
        Set-Content -Path $file -Value (New-LabDrivesXml -Drives $Drives) -Encoding UTF8 -NoNewline
        Update-LabGpoVersion -Gpo $Gpo -Scope User -Extension $script:Cse.Drives
    }
}

function Get-LabGpo {
    <# .SYNOPSIS Renvoie la GPO si elle existe, sinon la crée. #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Comment = ''
    )
    $gpo = Get-GPO -Name $Name -ErrorAction SilentlyContinue
    if (-not $gpo -and $PSCmdlet.ShouldProcess($Name, 'New-GPO')) {
        $gpo = New-GPO -Name $Name -Comment $Comment
    }
    $gpo
}

function Set-LabGpoLink {
    <# .SYNOPSIS Lie la GPO à la cible si ce n'est pas déjà fait. Renvoie $true si un lien a été créé. #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Target
    )
    $links = (Get-GPInheritance -Target $Target).GpoLinks
    if ($links | Where-Object DisplayName -EQ $Name) { return $false }
    if ($PSCmdlet.ShouldProcess($Target, "Lier $Name")) {
        New-GPLink -Name $Name -Target $Target -LinkEnabled Yes | Out-Null
    }
    $true
}

Export-ModuleMember -Function Merge-LabGpoExtension, New-LabSecurityTemplate, New-LabDrivesXml,
    Get-LabGpoSysvolPath, Update-LabGpoVersion, Set-LabGpoSecurityTemplate, Set-LabGpoDriveMap,
    Get-LabGpo, Set-LabGpoLink
