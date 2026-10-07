# 03 — Annuaire : OU, groupes, comptes et politiques de mots de passe

## 1. Structure — `05-Create-OUStructure.ps1`

```powershell
.\scripts\ad\05-Create-OUStructure.ps1
```

Le script enchaîne :

1. **OU** créées dans l'ordre de `OrganizationalUnits`, toutes protégées contre la suppression accidentelle.
2. **Redirection des conteneurs par défaut** avec `redircmp` et `redirusr`. Une machine jointe sans OU précisée atterrit dans `Ordinateurs/Postes`, donc sous les GPO, et non dans `CN=Computers`, où aucune GPO ne peut être liée.
3. **Groupes** `GG-*` (globaux) et `DL-*` (domaine local), puis l'imbrication AGDLP.
4. **Politique de mots de passe du domaine** : 12 caractères minimum, complexité, historique de 24, 180 jours maximum, verrouillage après 5 échecs pendant 15 minutes.
5. **Stratégie affinée (FGPP)** `PSO-Comptes-Admin` : 16 caractères, 90 jours, verrouillage après 3 échecs, appliquée à `GG-Admins-Postes` et aux Admins du domaine.
6. **Délégation** : `GG-Admins-Postes` peut créer et gérer les comptes ordinateur sous `Ordinateurs` (droits posés avec `dsacls`).
7. **`ms-DS-MachineAccountQuota` = 0** : un utilisateur standard ne peut plus créer de compte ordinateur.

### Pourquoi ces deux derniers points

Par défaut, tout utilisateur authentifié peut joindre jusqu'à 10 machines au domaine. Un attaquant qui contrôle un simple compte en profite pour créer un compte ordinateur dont il connaît le mot de passe. Ce compte sert de base à plusieurs escalades : délégation contrainte basée sur les ressources (RBCD), noPac (CVE-2021-42278/42287), certaines attaques ADCS. Fixer le quota à 0 ferme cette porte. La délégation sur l'OU conserve la possibilité de joindre des machines, mais seulement aux personnes habilitées.

```powershell
Get-ADObject (Get-ADDomain).DistinguishedName -Properties ms-DS-MachineAccountQuota
dsacls "OU=Ordinateurs,OU=HADRIEN-LAB,DC=corp,DC=hadrien,DC=lab" | Select-String GG-Admins-Postes
Get-ADFineGrainedPasswordPolicy -Filter * | Format-List Name, MinPasswordLength, AppliesTo
```

> 📸 `03-ou-tree.png` : « Utilisateurs et ordinateurs Active Directory » avec l'arborescence dépliée.
> 📸 `03-fgpp.png` : Centre d'administration AD > System > Password Settings Container > PSO-Comptes-Admin.

## 2. Comptes — `06-Import-Users.ps1`

```powershell
.\scripts\ad\06-Import-Users.ps1
```

**Utilisateurs métier** (`data/users.csv`) :

- identifiant : initiale du prénom + nom, sans accents ni espaces (`ConvertTo-LabSamAccountName`) ;
- placés dans `Utilisateurs/<Service>`, attributs Department, Title, Office, Company renseignés ;
- mot de passe aléatoire de 16 caractères, à changer à la première connexion ;
- ajoutés à leur groupe `GG-<Service>`.

**Comptes d'administration** (`data/admins.csv`) :

- un compte `adm-<identifiant>` par administrateur, distinct du compte de bureautique : on ne lit pas ses mails avec un compte qui a des droits sur le domaine ;
- placés dans `Comptes-Admin` et marqués « sensible, ne peut pas être délégué » ;
- `adm-igarnier` est admin du domaine et donc ajouté à **Protected Users** (pas de NTLM, pas de délégation Kerberos, pas de mise en cache des identifiants, TGT de 4 h) ;
- `adm-lfontaine` est seulement membre de `GG-Admins-Postes` : administrateur local des postes et autorisé à les joindre au domaine.

Les mots de passe initiaux sont écrits dans `output/secrets/ad-initial-passwords-<date>.csv`, exclu de Git. Distribue-les, puis supprime le fichier.

Le jeton `@DomainAdmins` du CSV est résolu par SID (`<SID du domaine>-512`). Le script fonctionne ainsi sur un serveur en français, où le groupe s'appelle « Admins du domaine ».

> 📸 `03-users-groups.png` : propriétés de `GG-Comptabilite`, onglets Membres et Membre de (montre AGDLP).

## Ajouter un collaborateur par la suite

```powershell
Import-Module .\modules\LabAdmin\LabAdmin.psm1
New-LabUser -GivenName 'Emma' -Surname 'Petit' -Department Commercial -Title 'Commerciale'
```

Voir [06-administration-powershell.md](06-administration-powershell.md) pour les départs, les réinitialisations et l'audit.
