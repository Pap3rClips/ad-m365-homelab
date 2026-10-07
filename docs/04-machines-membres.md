# 04 — Les trois machines jointes et le serveur de fichiers

## Jonction — `07-Join-Domain.ps1`

À lancer **sur chaque machine**, en administrateur local, après avoir copié ou cloné le dépôt :

```powershell
# Sur SRV01
.\scripts\ad\07-Join-Domain.ps1 -ComputerName SRV01
# Sur CLT01
.\scripts\ad\07-Join-Domain.ps1 -ComputerName CLT01
# Sur CLT02
.\scripts\ad\07-Join-Domain.ps1 -ComputerName CLT02
```

Le script :

1. applique l'IP fixe si la machine en a une dans `lab.psd1` (SRV01), sinon garde le DHCP ;
2. pointe le DNS vers DC01, condition pour que la machine trouve le domaine ;
3. vérifie que les enregistrements SRV se résolvent et que le port LDAP 389 du DC répond, puis s'arrête avec un message clair sinon ;
4. renomme et joint la machine **en une seule opération**, directement dans son OU (`-OUPath`), puis redémarre.

Identifiants demandés : `CORP\adm-lfontaine`. Ce compte détient la délégation posée par le script 05 et n'est pas admin du domaine. Les comptes de Protected Users ne peuvent pas s'authentifier en NTLM et sont à éviter pour cette opération.

```powershell
# Vérification depuis DC01
Get-ADComputer -Filter * | Format-Table Name, DistinguishedName
# Vérification sur la machine
Test-ComputerSecureChannel -Verbose
nltest /dsgetdc:corp.hadrien.lab
```

> 📸 `04-computers.png` : OU `Ordinateurs/Postes` et `Ordinateurs/Serveurs` avec les trois machines.

## Serveur de fichiers — `09-Configure-FileServer.ps1`

**Sur SRV01**, connecté avec un compte admin du domaine :

```powershell
.\scripts\ad\09-Configure-FileServer.ps1
```

Prérequis : le second disque créé par le script Hyper-V doit être initialisé en `D:`.

```powershell
Get-Disk | Where-Object PartitionStyle -EQ 'RAW' |
    Initialize-Disk -PartitionStyle GPT -PassThru |
    New-Partition -DriveLetter D -UseMaximumSize |
    Format-Volume -FileSystem NTFS -NewFileSystemLabel 'Donnees' -Confirm:$false
```

| Partage | NTFS | SMB | Lecteur |
|---|---|---|---|
| `\\SRV01\Commun` | DL-Partage-Commun-RW : Modification | Utilisateurs authentifiés : Modifier, ABE, chiffrement | P: pour tous |
| `\\SRV01\Comptabilite` | DL-Partage-Compta-RW : Modification ; DL-Partage-Compta-RO : Lecture | idem | K: pour Comptabilité et Direction |

Principes appliqués :

- **héritage coupé** sur la racine des partages : les droits `Utilisateurs` hérités de `D:\` disparaissent ;
- **droits uniquement via des groupes DL** : jamais d'utilisateur nominatif dans une ACL ;
- **ABE** (énumération basée sur l'accès) : on ne voit pas un dossier sur lequel on n'a aucun droit ;
- **chiffrement SMB 3** activé sur les partages.

Test depuis CLT01, connecté en tant que `CORP\hchevalier` (Comptabilité) puis `CORP\ndupont` (Commercial) :

```powershell
Get-PSDrive -PSProvider FileSystem     # P: et K: pour hchevalier, P: seul pour ndupont
New-Item K:\test.txt                   # autorisé pour hchevalier
```

> 📸 `04-share-ntfs.png` : propriétés de sécurité de `D:\Partages\Comptabilite` (héritage désactivé, groupes DL).
> 📸 `04-drives-user.png` : explorateur de CLT01 montrant P: et K: pour un utilisateur de la Comptabilité.
