# 06 — Scripts PowerShell d'administration

Le module `modules/LabAdmin` couvre les tâches courantes d'un administrateur AD. Toutes les fonctions qui modifient l'annuaire acceptent `-WhatIf` et `-Confirm` et journalisent leurs actions dans `logs/`.

```powershell
Import-Module .\modules\LabAdmin\LabAdmin.psm1
Get-Command -Module LabAdmin
Get-Help Disable-LabUser -Full
```

## Cycle de vie des comptes

| Fonction | Usage |
|---|---|
| `New-LabUser` | Arrivée : compte dans l'OU du service, groupe du service, mot de passe initial aléatoire renvoyé une seule fois |
| `Disable-LabUser` | Départ : désactivation, mot de passe aléatoire de 32 caractères, retrait de tous les groupes (liste conservée dans l'attribut `info`), déplacement dans `Desactives`, motif horodaté dans la description |
| `Reset-LabUserPassword` | Réinitialisation + déverrouillage + changement imposé à la connexion |
| `Get-LabLockedAccount` | Comptes verrouillés, nombre d'échecs, dernière tentative |

```powershell
New-LabUser -GivenName 'Emma' -Surname 'Petit' -Department Commercial -Title 'Commerciale'
Reset-LabUserPassword -Identity ndupont
Disable-LabUser -Identity slambert -Reason 'Fin de contrat 31/10' -WhatIf
Get-ADUser -Filter "Department -eq 'Commercial'" | Disable-LabUser -Reason 'Fermeture agence' -Confirm
```

Le compte d'un collaborateur parti est désactivé, pas supprimé : on garde ainsi l'accès à ses données et la traçabilité. La suppression intervient après 90 jours, manuellement.

## Revue et audit

| Fonction | Ce qu'elle remonte |
|---|---|
| `Get-LabStaleAccount -Days 90 [-Type Computer]` | Comptes actifs sans connexion depuis N jours (créés depuis plus de N jours) |
| `Get-LabPrivilegedMember` | Membres récursifs des groupes à privilèges : Admins du domaine / de l'entreprise / du schéma, Administrateurs, opérateurs de compte, de sauvegarde et de serveur |
| `Get-LabAccountRisk` | Comptes **Kerberoastables** (SPN sur un utilisateur), **AS-REP roastables** (pré-authentification désactivée), mot de passe non requis ou sans expiration, chiffrement réversible, délégation non contrainte, compte privilégié délégable |
| `Get-LabGroupMembership` | Membres directs de chaque groupe `GG-*` / `DL-*`, pour la revue des accès |
| `Test-LabDomainHealth` | Services du DC, enregistrements SRV, SYSVOL, `dcdiag /q`, source de temps, occupation DHCP |

```powershell
Get-LabAccountRisk | Format-Table -AutoSize
Get-LabPrivilegedMember | Where-Object Enabled | Sort-Object Group
Test-LabDomainHealth | Where-Object Status -EQ 'KO'
```

### Vérifier la détection

Crée volontairement une faiblesse, constate qu'elle est détectée, puis corrige-la :

```powershell
New-ADUser svc-sql -Path "OU=Comptes-Service,OU=HADRIEN-LAB,DC=corp,DC=hadrien,DC=lab" `
    -AccountPassword (Read-Host -AsSecureString) -Enabled $true
Set-ADUser svc-sql -ServicePrincipalNames @{ Add = 'MSSQLSvc/srv01.corp.hadrien.lab:1433' }
Set-ADAccountControl svc-sql -DoesNotRequirePreAuth $true
Get-LabAccountRisk      # svc-sql : Kerberoastable (SPN) | AS-REP roastable
Remove-ADUser svc-sql -Confirm:$false
```

Pour un vrai compte de service, la bonne réponse est un **gMSA** (`New-ADServiceAccount`) : son mot de passe de 240 caractères tourne automatiquement, ce qui rend le Kerberoasting inutile.

## Rapport de domaine — `10-Export-ADReport.ps1`

```powershell
.\scripts\ad\10-Export-ADReport.ps1
```

Le script produit `output/evidence/ad-<date>/index.html`, une page autonome lisible dans n'importe quel navigateur. Elle contient le domaine et la forêt (dont `MachineAccountQuota`), les OU, les ordinateurs avec leur OS et leur OU, les utilisateurs, les groupes, les GPO avec leurs liens et versions, les politiques de mots de passe et FGPP, les membres à privilèges, les comptes à risque, les zones et enregistrements DNS, les étendues et baux DHCP et les contrôles de santé. Chaque section est aussi exportée en CSV, et chaque GPO en rapport HTML détaillé dans `gpo/`.

> 📸 `06-ad-report.png` : haut du rapport HTML (domaine, OU, ordinateurs).
> 📸 `06-account-risk.png` : sortie de `Get-LabAccountRisk` avant/après correction.
