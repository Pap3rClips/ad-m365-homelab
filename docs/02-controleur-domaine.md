# 02 — Contrôleur de domaine, DNS et DHCP

Toutes les commandes de ce chapitre se lancent **sur DC01**, dans une console PowerShell administrateur, à la racine du dépôt.

## 1. Préparation — `01-Prepare-DC.ps1`

```powershell
.\scripts\ad\01-Prepare-DC.ps1 -WhatIf   # aperçu
.\scripts\ad\01-Prepare-DC.ps1
```

| Action | Pourquoi |
|---|---|
| IP fixe 192.168.50.10, passerelle .1 | Un DC ne doit jamais changer d'adresse : clients et DNS en dépendent |
| DNS = sa propre IP puis 127.0.0.1 | Le DC se résout lui-même ; les résolveurs publics passent par des redirecteurs |
| Fuseau Europe/Paris | Kerberos tolère 5 minutes d'écart : l'heure doit être juste dès le départ |
| Renommage en DC01 | Le nom doit être définitif **avant** la promotion |

Si la carte ne s'appelle pas `Ethernet`, le script liste les cartes disponibles. Corrige alors `Network.InterfaceAlias` dans `lab.psd1`.

## 2. Forêt — `02-Install-ADDS.ps1`

```powershell
.\scripts\ad\02-Install-ADDS.ps1
```

Le script installe AD DS, DNS, les outils RSAT et la GPMC, puis exécute `Test-ADDSForestInstallation` avant `Install-ADDSForest`. Le mot de passe **DSRM** est demandé de façon interactive : note-le hors ligne, il sert à restaurer l'annuaire. Le serveur redémarre ; reconnecte-toi ensuite en `CORP\Administrateur`.

Niveau fonctionnel : **Windows Server 2016** (`WinThreshold`). C'est le niveau requis pour chiffrer les mots de passe LAPS dans l'annuaire.

## 3. DNS — `03-Configure-DNS.ps1`

| Réglage | Valeur |
|---|---|
| Zone inverse | `50.168.192.in-addr.arpa`, intégrée à AD, mises à jour sécurisées uniquement |
| Redirecteurs | 1.1.1.1, 9.9.9.9 (indications de racine en secours) |
| Nettoyage | Actif, 7 j sans actualisation + 7 j d'actualisation |
| Enregistrements statiques | A + PTR de SRV01 ; PTR du DC |

Le script vérifie ensuite les enregistrements SRV dont dépendent les clients pour trouver le domaine :

```powershell
Resolve-DnsName _ldap._tcp.dc._msdcs.corp.hadrien.lab -Type SRV
Resolve-DnsName _kerberos._tcp.corp.hadrien.lab -Type SRV
nslookup www.microsoft.com 192.168.50.10
```

> 📸 `02-dns-zones.png` : console DNS montrant la zone directe, la zone inverse et le dossier `_msdcs`.

## 4. DHCP — `04-Configure-DHCP.ps1`

Étapes : installation du rôle, création des groupes de sécurité DHCP, **autorisation dans AD** (sans elle, le service refuse de distribuer des baux), création de l'étendue, des exclusions et de la réservation, réglage des options, puis DNS dynamique.

```powershell
Get-DhcpServerInDC
Get-DhcpServerv4Scope | Format-List *
Get-DhcpServerv4OptionValue -ScopeId 192.168.50.0
Get-DhcpServerv4Lease -ScopeId 192.168.50.0      # après démarrage des clients
```

> 📸 `02-dhcp-scope.png` : console DHCP avec l'étendue active, les options d'étendue et les baux.

La réservation `CLT02` utilise la MAC `00-15-5D-00-00-02`. Le script Hyper-V fixe cette adresse sur la VM. Sous Proxmox, reporte la MAC réelle de la VM dans `Dhcp.Reservations`.

## Validation

```powershell
dcdiag /q                 # aucune sortie = aucune erreur
repadmin /replsummary     # un seul DC : aucune erreur attendue
Get-Service NTDS, DNS, Netlogon, Kdc, DHCPServer
```

`Test-LabDomainHealth` (module `LabAdmin`) regroupe ces contrôles. Voir [06](06-administration-powershell.md).

## Dépannage

| Symptôme | Cause probable | Correction |
|---|---|---|
| `Test-ADDSForestInstallation` signale une IP dynamique | IP pas encore fixe | Relancer `01-Prepare-DC.ps1` |
| SRV `_ldap` introuvable | Netlogon n'a pas enregistré ses SRV | `ipconfig /registerdns ; Restart-Service Netlogon` |
| Pas de résolution externe | Pas de NAT ou mauvaise passerelle | `Test-NetConnection 1.1.1.1 -Port 53` depuis DC01, vérifier `Get-NetNat` sur l'hôte |
| Clients sans bail | Serveur DHCP non autorisé | `Get-DhcpServerInDC`, relancer le script 04 |
