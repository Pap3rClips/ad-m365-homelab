# 08 — Enrôlement d'un poste dans Intune

Le poste **CLT-CLOUD01** représente le poste de travail moderne : il n'est **pas** joint au domaine AD. Il est joint à **Entra ID** et s'inscrit automatiquement dans **Intune** à la jonction.

## 1. Préparer Intune — `25-Configure-Intune.ps1`

```powershell
.\scripts\m365\25-Configure-Intune.ps1
```

| Élément | Configuration |
|---|---|
| Inscription automatique MDM | Portée utilisateur **Tous** (API bêta ; consigne manuelle affichée si refus) |
| `WIN-Conformite-Base` | BitLocker, démarrage sécurisé, intégrité du code, TPM, chiffrement, pare-feu, Defender temps réel, antivirus/antispyware, Windows 11 23H2 minimum, mot de passe ; non conforme après 24 h de grâce |
| `WIN-Restrictions-Base` | Mot de passe alphanumérique de 8 caractères, verrouillage après 10 min, Defender temps réel, stockage amovible bloqué |
| `WIN-BitLocker` | Chiffrement du disque système, sans invite pour l'utilisateur standard |
| Affectation | Groupe dynamique `SG-Dyn-Postes-Windows` (`device.deviceOSType -eq "Windows"`) |

**Réglage manuel recommandé** : Intune > Appareils > Conformité > Paramètres de la stratégie de conformité > « Marquer les appareils sans stratégie de conformité comme » = **Non conforme**.

## 2. Joindre CLT-CLOUD01 à Entra ID

La VM doit avoir le **démarrage sécurisé** et une **vTPM** : le script Hyper-V les active. Sans eux, la conformité échoue sur BitLocker et TPM.

**Option A — pendant l'installation (OOBE)**

1. À l'écran « Comment voulez-vous configurer cet appareil ? », choisis **Configurer pour un usage professionnel ou scolaire**.
2. Connecte-toi avec un utilisateur licencié, par exemple `trousseau@<tenant>.onmicrosoft.com`.
3. Valide la MFA, puis crée le code PIN Windows Hello.

**Option B — Windows déjà installé avec un compte local**

1. Paramètres > Comptes > Accès Professionnel ou Scolaire > **Se connecter**.
2. Lien **Joindre cet appareil à Microsoft Entra ID**, puis connexion avec le même utilisateur.
3. Redémarre et ouvre la session avec le compte Entra.

La jonction déclenche l'inscription MDM, puisque la portée automatique est « Tous ». L'appareil apparaît dans Intune en 5 à 15 minutes, puis rejoint `SG-Dyn-Postes-Windows` et reçoit les stratégies.

> Avec CA001 en mode activé, la jonction demande la MFA, ce qui est le comportement attendu. Un utilisateur qui n'a pas encore inscrit de méthode est invité à le faire.

> 📸 `08-oobe-work.png` : OOBE, choix « usage professionnel ».
> 📸 `08-access-work.png` : Paramètres > Accès Professionnel : « Connecté à l'Azure AD de Hadrien Lab », géré par Microsoft.

## 3. Vérifier sur le poste — `26-Test-IntuneEnrollment.ps1`

```powershell
.\scripts\m365\26-Test-IntuneEnrollment.ps1
```

| Contrôle | Source |
|---|---|
| Joint à Entra ID, tenant, URL MDM, PRT | `dsregcmd /status` |
| Inscription « MS DM Server » | `HKLM:\SOFTWARE\Microsoft\Enrollments` |
| Synchronisation déclenchée | Tâche planifiée `EnterpriseMgmt\<GUID>` |
| BitLocker, démarrage sécurisé, TPM | `Get-BitLockerVolume`, `Confirm-SecureBootUEFI`, `Get-Tpm` |
| Rapport complet | `MdmDiagnosticsTool.exe` → `MDMDiagReport.html` |

Option `-CollectAutopilotHash` : exporte le hash matériel pour un futur déploiement Autopilot.

> 📸 `08-dsregcmd.png` : `dsregcmd /status` (AzureAdJoined : YES, MdmUrl renseignée).
> 📸 `08-mdm-diag.png` : MDMDiagReport.html, section des stratégies gérées.

## 4. Vérifier dans Intune

> 📸 `08-intune-device.png` : Intune > Appareils > Windows > CLT-CLOUD01 (propriétaire, conformité, dernière synchronisation).
> 📸 `08-intune-compliance.png` : CLT-CLOUD01 > Conformité de l'appareil > WIN-Conformite-Base : Conforme.
> 📸 `08-intune-profiles.png` : CLT-CLOUD01 > Configuration de l'appareil : profils réussis.

## Dépannage

| Symptôme | Cause probable | Correction |
|---|---|---|
| Joint à Entra mais pas dans Intune | Portée MDM « Aucun », ou utilisateur sans licence Intune | Vérifier la portée MDM et la licence de l'utilisateur, puis Accès Professionnel > Info > Synchroniser |
| Non conforme : BitLocker | Chiffrement en cours ou vTPM absente | `manage-bde -status`, activer la vTPM de la VM, attendre la fin du chiffrement |
| Non conforme : démarrage sécurisé / intégrité du code | Attestation d'intégrité pas encore remontée | Redémarrer, synchroniser, patienter (jusqu'à 24 h la première fois) |
| Profil « En attente » | L'appareil n'est pas encore dans le groupe dynamique | Entra > Groupes > SG-Dyn-Postes-Windows > Membres ; l'évaluation dynamique peut prendre quelques minutes |
| Erreur 80180014 à l'inscription | Restriction d'inscription Windows | Intune > Appareils > Inscription > Restrictions de plateforme : autoriser Windows (MDM) |
