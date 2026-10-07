# 00 — Prérequis

## Matériel de l'hôte

| Ressource | Minimum | Confortable |
|---|---|---|
| RAM | 16 Go (VM à 2–3 Go) | 32 Go |
| Stockage | 200 Go SSD | 300 Go NVMe |
| CPU | 4 cœurs avec virtualisation (VT-x/AMD-V) | 8 cœurs |
| OS hôte | Windows 10/11 Pro ou Entreprise avec Hyper-V, ou Proxmox VE | — |

Les cinq VM n'ont pas besoin de tourner en même temps. La partie AD utilise DC01, SRV01, CLT01 et CLT02, la partie Intune DC01 (DNS/DHCP) et CLT-CLOUD01.

## Logiciels

| Élément | Source | Remarque |
|---|---|---|
| Windows Server 2022 (évaluation) | Microsoft Evaluation Center | 180 jours, prolongeable avec `slmgr /rearm` |
| Windows 11 Entreprise (évaluation) | Microsoft Evaluation Center | 90 jours ; Pro convient aussi (jonction domaine et Entra) |
| PowerShell 7 (facultatif) | `winget install Microsoft.PowerShell` | Les scripts fonctionnent aussi sous Windows PowerShell 5.1 |
| Git | `winget install Git.Git` | Pour cloner le dépôt sur les VM |

## Tenant Microsoft 365

Il faut un tenant comprenant **Entra ID P1** (licences de groupe, groupes dynamiques, accès conditionnel), **Exchange Online**, **SharePoint Online** et **Intune** :

- tenant de développement Microsoft 365 E5 (SKU `DEVELOPERPACK_E5`) si tu y as accès ;
- sinon un essai **Microsoft 365 Business Premium** (SKU `SPB`), qui couvre tout le cahier des charges.

Renseigne ensuite dans `config/lab.psd1` :

```powershell
M365 = @{
    TenantDomain         = '<tenant>.onmicrosoft.com'
    SharePointPrefix     = '<tenant>'
    LicenseSkuPartNumber = 'DEVELOPERPACK_E5'   # ou 'SPB'
}
```

Le compte utilisé pour lancer les scripts M365 doit être **Administrateur général**. Les scripts demandent leurs autorisations Graph à la première connexion.

## Réseau

Le script `scripts/host/00-New-HyperVLab.ps1` crée un commutateur **interne** et un **NAT**. Les VM sortent sur Internet par l'hôte (192.168.50.1) tout en restant isolées du réseau domestique. Le DHCP du lab est servi par DC01 et ne déborde pas sur la box.

### Sous Proxmox VE

Reproduis les VM du tableau `HyperV.VMs` de `lab.psd1` avec le BIOS **OVMF (UEFI)**, une **TPM v2.0**, le Secure Boot (clés pré-inscrites) et des cartes **VirtIO** (pilotes `virtio-win` à charger pendant l'installation). Crée un bridge Linux dédié (par exemple `vmbr50`) sans DHCP, avec du NAT `iptables`/`nftables` vers ton interface de sortie, et donne l'adresse 192.168.50.1 au bridge.

## Récupérer le dépôt sur les VM

```powershell
git clone https://github.com/Pap3rClips/ad-m365-homelab.git C:\Lab
Set-Location C:\Lab
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
Get-ChildItem -Recurse -Include *.ps1, *.psm1 | Unblock-File
```

Tous les scripts acceptent `-WhatIf` pour afficher ce qu'ils feraient sans rien modifier.
