#Requires -Version 5.1

<#
.SYNOPSIS
    Fonctions partagées par tous les scripts du lab : configuration, journalisation,
    nommage, génération de mots de passe et chemins LDAP.
#>

Set-StrictMode -Version Latest

$script:LabRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent

function Get-LabRoot {
    <# .SYNOPSIS Renvoie la racine du dépôt. #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $script:LabRoot
}

function Import-LabConfig {
    <# .SYNOPSIS Charge config/lab.psd1 (ou le chemin fourni) et vérifie les clés obligatoires. #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$Path = (Join-Path -Path $script:LabRoot -ChildPath 'config/lab.psd1')
    )
    if (-not (Test-Path -Path $Path)) {
        throw "Fichier de configuration introuvable : $Path"
    }
    $config = Import-PowerShellDataFile -Path $Path
    foreach ($key in 'Domain', 'Network', 'DomainController', 'Dhcp', 'Members', 'OrganizationalUnits', 'Groups', 'M365') {
        if (-not $config.ContainsKey($key)) {
            throw "Clé '$key' absente de $Path"
        }
    }
    $config
}

function Write-LabLog {
    <# .SYNOPSIS Écrit un message horodaté à l'écran et dans logs/<script>.log. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'SKIP')][string]$Level = 'INFO'
    )
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$stamp] [$Level] $Message"
    $color = switch ($Level) {
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'SKIP'  { 'DarkGray' }
        default { 'Cyan' }
    }
    Write-Host $line -ForegroundColor $color

    $caller = (Get-PSCallStack | Select-Object -Skip 1 -First 1).ScriptName
    $name = if ($caller) { [IO.Path]::GetFileNameWithoutExtension($caller) } else { 'console' }
    $logDir = Join-Path -Path $script:LabRoot -ChildPath 'logs'
    if (-not (Test-Path -Path $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }
    Add-Content -Path (Join-Path -Path $logDir -ChildPath "$name.log") -Value $line -Encoding UTF8
}

function Assert-LabAdministrator {
    <# .SYNOPSIS Stoppe le script s'il n'est pas lancé en administrateur (Windows uniquement). #>
    [CmdletBinding()]
    param()
    $isWindowsHost = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows
    if (-not $isWindowsHost) {
        throw 'Ce script doit être exécuté sur Windows.'
    }
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Lance PowerShell en tant qu''administrateur.'
    }
}

function Get-LabDomainDN {
    <# .SYNOPSIS Convertit le FQDN du domaine en DN LDAP (corp.lab -> DC=corp,DC=lab). #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Fqdn)
    ($Fqdn.Split('.') | ForEach-Object { "DC=$_" }) -join ','
}

function ConvertTo-LabOUPath {
    <#
    .SYNOPSIS
        Convertit un chemin relatif 'Utilisateurs/IT' en DN complet sous l'OU racine.
    .EXAMPLE
        ConvertTo-LabOUPath -RelativePath 'Utilisateurs/IT' -RootOU 'LAB' -Fqdn 'corp.lab'
        # OU=IT,OU=Utilisateurs,OU=LAB,DC=corp,DC=lab
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$RelativePath,
        [Parameter(Mandatory)][string]$RootOU,
        [Parameter(Mandatory)][string]$Fqdn
    )
    $parts = @($RelativePath.Split('/', [StringSplitOptions]::RemoveEmptyEntries))
    [array]::Reverse($parts)
    $ous = @($parts | ForEach-Object { "OU=$_" }) + "OU=$RootOU"
    ($ous + (Get-LabDomainDN -Fqdn $Fqdn)) -join ','
}

function Remove-LabDiacritic {
    <# .SYNOPSIS Supprime les accents (é -> e) pour produire des identifiants ASCII. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Fonction pure : ne modifie aucun état')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, ValueFromPipeline)][AllowEmptyString()][string]$Text)
    process {
        $normalized = $Text.Normalize([Text.NormalizationForm]::FormD)
        $sb = [Text.StringBuilder]::new()
        foreach ($char in $normalized.ToCharArray()) {
            if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($char) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
                [void]$sb.Append($char)
            }
        }
        $sb.ToString().Normalize([Text.NormalizationForm]::FormC)
    }
}

function ConvertTo-LabSamAccountName {
    <#
    .SYNOPSIS
        Construit l'identifiant : initiale du prénom + nom, en minuscules, sans accents
        ni caractères spéciaux, tronqué à 20 caractères (limite sAMAccountName).
    .EXAMPLE
        ConvertTo-LabSamAccountName -GivenName 'Inès' -Surname 'Le Garnier'  # ilegarnier
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$GivenName,
        [Parameter(Mandatory)][string]$Surname
    )
    $raw = (Remove-LabDiacritic -Text $GivenName).Substring(0, 1) + (Remove-LabDiacritic -Text $Surname)
    $clean = ($raw.ToLowerInvariant() -replace '[^a-z0-9]', '')
    if ($clean.Length -gt 20) { $clean = $clean.Substring(0, 20) }
    $clean
}

function New-LabPassword {
    <#
    .SYNOPSIS
        Génère un mot de passe aléatoire cryptographiquement sûr contenant au moins
        une minuscule, une majuscule, un chiffre et un caractère spécial.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Fonction pure : ne modifie aucun état')]
    [CmdletBinding()]
    [OutputType([string])]
    param([ValidateRange(12, 128)][int]$Length = 16)

    $sets = @(
        'abcdefghijkmnopqrstuvwxyz',
        'ABCDEFGHJKLMNPQRSTUVWXYZ',
        '23456789',
        '!@#$%*-_=+?'
    )
    $all = -join $sets
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $pick = {
            param([string]$Pool)
            $bytes = [byte[]]::new(4)
            $rng.GetBytes($bytes)
            $Pool[[BitConverter]::ToUInt32($bytes, 0) % $Pool.Length]
        }
        $chars = [Collections.Generic.List[char]]::new()
        foreach ($set in $sets) { $chars.Add((& $pick $set)) }
        while ($chars.Count -lt $Length) { $chars.Add((& $pick $all)) }

        # Mélange Fisher-Yates pour ne pas laisser les classes de caractères en tête
        for ($i = $chars.Count - 1; $i -gt 0; $i--) {
            $bytes = [byte[]]::new(4)
            $rng.GetBytes($bytes)
            $j = [BitConverter]::ToUInt32($bytes, 0) % ($i + 1)
            $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
        }
        -join $chars
    }
    finally {
        $rng.Dispose()
    }
}

function Import-LabCsv {
    <# .SYNOPSIS Importe un CSV du dossier data/ et vérifie la présence des colonnes attendues. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$RequiredColumns
    )
    if (-not (Test-Path -Path $Path)) { throw "CSV introuvable : $Path" }
    $rows = @(Import-Csv -Path $Path -Encoding UTF8)
    if ($rows.Count -eq 0) { throw "CSV vide : $Path" }
    $columns = $rows[0].PSObject.Properties.Name
    $missing = @($RequiredColumns | Where-Object { $_ -notin $columns })
    if ($missing.Count -gt 0) { throw "Colonnes manquantes dans ${Path} : $($missing -join ', ')" }
    $rows
}

function Export-LabSecret {
    <#
    .SYNOPSIS
        Ajoute un identifiant initial dans output/secrets/ (dossier exclu de Git).
        À détruire une fois les mots de passe transmis.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][pscustomobject]$Entry
    )
    $dir = Join-Path -Path $script:LabRoot -ChildPath 'output/secrets'
    if (-not (Test-Path -Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    $Entry | Export-Csv -Path (Join-Path -Path $dir -ChildPath $FileName) -Append -NoTypeInformation -Encoding UTF8
}

function Export-LabHtmlReport {
    <#
    .SYNOPSIS
        Assemble un rapport HTML autonome (une section par jeu de données) et écrit
        chaque jeu de données en CSV à côté. Utilisé par les scripts d'export de preuves.
    .PARAMETER Sections
        Liste d'objets/hashtables : Title, Data, et optionnellement CsvName, Note.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][object[]]$Sections
    )
    New-Item -Path $Directory -ItemType Directory -Force | Out-Null
    $html = [Collections.Generic.List[string]]::new()
    foreach ($s in $Sections) {
        $data = @($s.Data | Where-Object { $null -ne $_ })
        $csvName = if ($s -is [Collections.IDictionary]) { $s['CsvName'] } else { $s.CsvName }
        $note    = if ($s -is [Collections.IDictionary]) { $s['Note'] } else { $s.Note }
        if ($csvName -and $data.Count -gt 0) {
            $data | Export-Csv -Path (Join-Path -Path $Directory -ChildPath "$csvName.csv") -NoTypeInformation -Encoding UTF8
        }
        $table = if ($data.Count -gt 0) { ($data | ConvertTo-Html -Fragment) -join "`n" } else { '<p class="empty">Aucun élément.</p>' }
        $noteHtml = if ($note) { "<p class=`"note`">$([Security.SecurityElement]::Escape($note))</p>" } else { '' }
        $html.Add("<section><h2>$([Security.SecurityElement]::Escape($s.Title))</h2>$noteHtml$table</section>")
    }
    $style = @'
<style>
:root { --bg:#f7f7f5; --fg:#1d232a; --muted:#5d6670; --line:#d9dcdf; --accent:#0b5cad; --head:#e9eef4; }
body { font-family: "Segoe UI", system-ui, sans-serif; background: var(--bg); color: var(--fg); margin: 0; padding: 32px; }
h1 { margin: 0 0 4px; font-size: 26px; } .meta { color: var(--muted); margin-bottom: 28px; }
section { background: #fff; border: 1px solid var(--line); border-radius: 8px; padding: 18px 20px; margin-bottom: 18px; overflow-x: auto; }
h2 { font-size: 17px; margin: 0 0 12px; color: var(--accent); }
table { border-collapse: collapse; width: 100%; font-size: 13px; }
th { background: var(--head); text-align: left; } th, td { border: 1px solid var(--line); padding: 6px 8px; vertical-align: top; }
.note, .empty { color: var(--muted); font-size: 13px; } .note { margin: -4px 0 10px; }
</style>
'@
    $safeTitle = [Security.SecurityElement]::Escape($Title)
    $page = @"
<!DOCTYPE html><html lang="fr"><head><meta charset="utf-8"><title>$safeTitle</title>$style</head><body>
<h1>$safeTitle</h1>
<div class="meta">Généré le $(Get-Date -Format 'dd/MM/yyyy HH:mm') par $([Environment]::UserName) sur $([Environment]::MachineName)</div>
$($html -join "`n")
</body></html>
"@
    $index = Join-Path -Path $Directory -ChildPath 'index.html'
    Set-Content -Path $index -Value $page -Encoding UTF8
    $index
}

Export-ModuleMember -Function Get-LabRoot, Import-LabConfig, Write-LabLog, Assert-LabAdministrator,
    Get-LabDomainDN, ConvertTo-LabOUPath, Remove-LabDiacritic, ConvertTo-LabSamAccountName,
    New-LabPassword, Import-LabCsv, Export-LabSecret, Export-LabHtmlReport
