#Requires -Version 5.1

<#
.SYNOPSIS
    Configure Exchange Online : boîtes partagées, liste de diffusion dynamique et durcissement.

.DESCRIPTION
    - Boîtes partagées (support@, factures@) : accès complet + « Envoyer en tant que »
      pour les membres du service concerné (sans licence nécessaire pour la boîte partagée)
    - Liste de diffusion dynamique « Tous » : contient toujours toutes les boîtes utilisateurs
    - Durcissement :
        * authentification SMTP basique désactivée au niveau de l'organisation
        * POP et IMAP désactivés (boîtes existantes + modèle des futures boîtes)
        * transfert automatique vers l'externe bloqué (stratégie anti-spam sortante)
        * balise « Externe » dans Outlook pour les messages venant de l'extérieur
        * audit des boîtes aux lettres et journal d'audit unifié activés

.EXAMPLE
    .\22-Configure-Exchange.ps1 -WhatIf
    .\22-Configure-Exchange.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath,
    [string]$UsersCsv
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../../modules/LabCommon/LabCommon.psm1') -Force
$config = if ($ConfigPath) { Import-LabConfig -Path $ConfigPath } else { Import-LabConfig }
if (-not $UsersCsv) { $UsersCsv = Join-Path -Path (Get-LabRoot) -ChildPath 'data/users.csv' }
$m365 = $config.M365
$tenant = $m365.TenantDomain

if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
    throw 'Module ExchangeOnlineManagement absent : lance 20-Install-M365Modules.ps1'
}
Import-Module ExchangeOnlineManagement
if (-not (Get-ConnectionInformation | Where-Object State -EQ 'Connected')) {
    Connect-ExchangeOnline -ShowBanner:$false
}
if ($tenant -notin @(Get-AcceptedDomain | ForEach-Object { $_.DomainName })) {
    throw "La session Exchange n'est pas sur le tenant $tenant. Lance Disconnect-ExchangeOnline puis reconnecte-toi avec un compte du bon tenant."
}
Write-LabLog "Connecté à Exchange Online ($tenant)" -Level OK

# Le tenant peut être « déshydraté » : certaines cmdlets d'organisation l'exigent
if ((Get-OrganizationConfig).IsDehydrated -and $PSCmdlet.ShouldProcess($tenant, 'Enable-OrganizationCustomization')) {
    Enable-OrganizationCustomization
    Write-LabLog 'Personnalisation de l''organisation activée' -Level OK
}

# Utilisateurs M365 par service (même règle de nommage que le script 21)
$byDept = @{}
Import-LabCsv -Path $UsersCsv -RequiredColumns 'GivenName', 'Surname', 'Department', 'M365' |
    Where-Object { $_.M365 -eq 'true' } | ForEach-Object {
        $upn = "$(ConvertTo-LabSamAccountName -GivenName $_.GivenName -Surname $_.Surname)@$tenant"
        if (-not $byDept.ContainsKey($_.Department)) { $byDept[$_.Department] = [Collections.Generic.List[string]]::new() }
        $byDept[$_.Department].Add($upn)
    }

# =====================================================================================
# 1. Boîtes partagées
# =====================================================================================
foreach ($sm in $m365.SharedMailboxes) {
    $address = "$($sm.Alias)@$tenant"
    $mbx = Get-EXOMailbox -Identity $address -ErrorAction SilentlyContinue
    if (-not $mbx) {
        if (-not $PSCmdlet.ShouldProcess($address, 'New-Mailbox -Shared')) { continue }
        $mbx = New-Mailbox -Shared -Name $sm.Name -DisplayName $sm.Name -Alias $sm.Alias -PrimarySmtpAddress $address
        Write-LabLog "Boîte partagée créée : $address" -Level OK
    }
    else { Write-LabLog "Boîte partagée $address déjà présente" -Level SKIP }

    $fullAccess = @(Get-EXOMailboxPermission -Identity $address -ErrorAction SilentlyContinue |
        Where-Object { $_.AccessRights -contains 'FullAccess' } | ForEach-Object { $_.User })
    $sendAs = @(Get-EXORecipientPermission -Identity $address -ErrorAction SilentlyContinue |
        Where-Object { $_.AccessRights -contains 'SendAs' } | ForEach-Object { $_.Trustee })

    foreach ($dept in $sm.Members) {
        foreach ($upn in @($byDept[$dept])) {
            if (-not $upn) { continue }
            if (-not (Get-EXOMailbox -Identity $upn -ErrorAction SilentlyContinue)) {
                Write-LabLog "$upn n'a pas encore de boîte (licence en cours de provisionnement) : relance le script plus tard" -Level WARN
                continue
            }
            if ($upn -notin $fullAccess -and $PSCmdlet.ShouldProcess($address, "FullAccess pour $upn")) {
                Add-MailboxPermission -Identity $address -User $upn -AccessRights FullAccess -InheritanceType All -AutoMapping $true | Out-Null
                Write-LabLog "$upn : accès complet à $address" -Level OK
            }
            if ($upn -notin $sendAs -and $PSCmdlet.ShouldProcess($address, "SendAs pour $upn")) {
                Add-RecipientPermission -Identity $address -Trustee $upn -AccessRights SendAs -Confirm:$false | Out-Null
                Write-LabLog "$upn : envoyer en tant que $address" -Level OK
            }
        }
    }
}

# =====================================================================================
# 2. Liste de diffusion dynamique
# =====================================================================================
foreach ($dl in $m365.DistributionLists) {
    if (Get-DynamicDistributionGroup -Identity $dl.Alias -ErrorAction SilentlyContinue) {
        Write-LabLog "Liste dynamique $($dl.Name) déjà présente" -Level SKIP
        continue
    }
    if ($PSCmdlet.ShouldProcess($dl.Name, 'New-DynamicDistributionGroup')) {
        New-DynamicDistributionGroup -Name $dl.Name -Alias $dl.Alias -PrimarySmtpAddress "$($dl.Alias)@$tenant" `
            -IncludedRecipients MailboxUsers | Out-Null
        # Seuls les utilisateurs internes peuvent écrire à la liste
        Set-DynamicDistributionGroup -Identity $dl.Alias -RequireSenderAuthenticationEnabled $true
        Write-LabLog "Liste dynamique créée : $($dl.Alias)@$tenant (toutes les boîtes utilisateurs)" -Level OK
    }
}

# =====================================================================================
# 3. Durcissement
# =====================================================================================
if ($PSCmdlet.ShouldProcess($tenant, 'Désactiver SMTP AUTH')) {
    Set-TransportConfig -SmtpClientAuthenticationDisabled $true
    Write-LabLog 'SMTP AUTH (authentification basique) désactivé pour l''organisation' -Level OK
}

if ($PSCmdlet.ShouldProcess($tenant, 'Désactiver POP/IMAP')) {
    Get-CASMailboxPlan | Set-CASMailboxPlan -PopEnabled $false -ImapEnabled $false
    Get-EXOCASMailbox -ResultSize Unlimited -PropertySets Minimum, Imap, Pop |
        Where-Object { $_.PopEnabled -or $_.ImapEnabled } |
        ForEach-Object { Set-CASMailbox -Identity $_.Identity -PopEnabled $false -ImapEnabled $false }
    Write-LabLog 'POP et IMAP désactivés (boîtes existantes et futures)' -Level OK
}

if ($PSCmdlet.ShouldProcess('Default', 'Bloquer le transfert automatique externe')) {
    Set-HostedOutboundSpamFilterPolicy -Identity Default -AutoForwardingMode Off
    Write-LabLog 'Transfert automatique vers l''externe bloqué' -Level OK
}

if ($PSCmdlet.ShouldProcess($tenant, 'Balise Externe dans Outlook')) {
    Set-ExternalInOutlook -Enabled $true | Out-Null
    Write-LabLog 'Balise « Externe » activée dans Outlook' -Level OK
}

if ($PSCmdlet.ShouldProcess($tenant, 'Audit')) {
    Set-OrganizationConfig -AuditDisabled $false
    try {
        Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $true -ErrorAction Stop
        Write-LabLog 'Audit des boîtes et journal d''audit unifié activés' -Level OK
    }
    catch {
        Write-LabLog "Journal d'audit unifié : $($_.Exception.Message) — active-le dans le portail Purview > Audit si besoin" -Level WARN
    }
}

Get-EXOMailbox -RecipientTypeDetails SharedMailbox | Format-Table DisplayName, PrimarySmtpAddress -AutoSize
Write-LabLog 'Exchange configuré. Étape suivante : 23-Configure-SharePoint.ps1 (Windows PowerShell 5.1)' -Level OK
