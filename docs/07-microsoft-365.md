# 07 — Tenant Microsoft 365 : Entra ID, Exchange, SharePoint, MFA

Les scripts se lancent depuis **CLT02** (ou ton PC), avec un compte **Administrateur général** du tenant. La connexion Graph est interactive. À la première exécution, Entra ID demande de consentir aux autorisations listées dans chaque script, et seulement à celles-là.

```powershell
.\scripts\m365\20-Install-M365Modules.ps1
```

## 1. Identités — `21-Provision-EntraIdentities.ps1`

| Objet | Détail |
|---|---|
| Utilisateurs | Les 9 lignes `M365=true` de `users.csv`, UPN `<identifiant>@<tenant>`, `usageLocation = FR` (obligatoire pour licencier), mot de passe aléatoire à changer |
| Licence **par groupe** | `SG-M365-Licences` reçoit la licence ; tout membre est licencié, tout membre retiré perd sa licence |
| Groupes **dynamiques** | `SG-Dyn-IT`, `SG-Dyn-Comptabilite` (attribut `department`) et `SG-Dyn-Postes-Windows` (appareils Windows, cible Intune) |
| Groupes **Microsoft 365** | `Equipe-IT`, `Equipe-Comptabilite` : boîte de groupe et site SharePoint d'équipe créés automatiquement |

Le script commence par vérifier que le tenant connecté possède bien le domaine de `lab.psd1`, ce qui évite de provisionner dans le mauvais tenant.

> 📸 `07-entra-users.png` : Entra > Utilisateurs, filtrés sur la société « Hadrien Lab ».
> 📸 `07-group-licensing.png` : SG-M365-Licences > Licences (attribution active, aucun conflit).
> 📸 `07-dynamic-group.png` : SG-Dyn-IT > Requêtes d'appartenance dynamique.

## 2. Exchange Online — `22-Configure-Exchange.ps1`

Les boîtes aux lettres apparaissent 5 à 15 minutes après l'attribution des licences. Si un utilisateur n'a pas encore de boîte, le script le signale et peut être relancé.

| Élément | Configuration |
|---|---|
| `support@` | Boîte partagée, accès complet + « Envoyer en tant que » pour le service IT, montage automatique dans Outlook |
| `factures@` | Idem pour la Comptabilité |
| `tous@` | Liste de **diffusion dynamique** (toutes les boîtes utilisateurs), réservée aux expéditeurs internes |
| SMTP AUTH | Désactivé au niveau de l'organisation |
| POP / IMAP | Désactivés sur les boîtes existantes **et** dans les modèles (`CASMailboxPlan`) |
| Transfert automatique externe | Bloqué (stratégie anti-spam sortante) : principal vecteur d'exfiltration après compromission d'une boîte |
| Balise « Externe » | Activée dans Outlook |
| Audit | Audit des boîtes actif, journal d'audit unifié activé |

> 📸 `07-exo-shared.png` : centre d'administration Exchange > Boîtes partagées > support, onglet Délégation.

## 3. SharePoint Online — `23-Configure-SharePoint.ps1`

Ce script utilise Windows PowerShell 5.1 (`powershell.exe`), qui supporte pleinement le module SharePoint.

```powershell
powershell.exe -File .\scripts\m365\23-Configure-SharePoint.ps1 -OwnerUpn admin@<tenant>.onmicrosoft.com
```

| Niveau | Réglage |
|---|---|
| Tenant | Partage externe limité aux **invités existants**, lien par défaut **interne** et en **lecture**, pas de repartage par les invités |
| OneDrive | Même niveau |
| Intranet (communication) | Créé en français, fuseau Paris, partage externe désactivé |
| Equipe-Comptabilite | Partage externe désactivé (données financières) |
| Equipe-IT | Invités existants uniquement |

> 📸 `07-spo-sites.png` : centre d'administration SharePoint > Sites actifs.
> 📸 `07-spo-sharing.png` : Stratégies > Partage.

## 4. MFA et accès conditionnel — `24-Configure-MFA-ConditionalAccess.ps1`

```powershell
.\scripts\m365\24-Configure-MFA-ConditionalAccess.ps1            # rapport uniquement
# ... connexions de test, vérification des journaux ...
.\scripts\m365\24-Configure-MFA-ConditionalAccess.ps1 -Enforce   # activation
```

L'ordre des opérations est pensé pour ne jamais perdre l'accès au tenant :

1. **Compte d'urgence** `bg-admin` : cloud only, Administrateur général, mot de passe aléatoire de 64 caractères, **exclu de toutes les stratégies**. Imprime son mot de passe, range-le hors ligne et supprime `output/secrets/break-glass.csv`.
2. **Microsoft Authenticator** activé pour tous (notifications avec correspondance de nombre).
3. **Paramètres de sécurité par défaut** désactivés : ils sont incompatibles avec l'accès conditionnel, qui les remplace avec plus de finesse.
4. **Stratégies**, créées en mode *rapport uniquement* :

| Stratégie | Cible | Contrôle | Pourquoi |
|---|---|---|---|
| CA001-Tous-Utilisateurs-MFA | Tous les utilisateurs, toutes les applications | MFA | Rend inutile un mot de passe volé, réutilisé ou deviné |
| CA002-Tous-Bloquer-Authentification-Heritee | Clients EAS et « autres » (POP, IMAP, SMTP basique) | Blocage | Ces protocoles ne savent pas faire de MFA : ils contourneraient CA001 |
| CA003-Tous-MFA-Inscription-Appareil | Action « inscrire ou joindre un appareil » | MFA | Empêche un attaquant d'enregistrer son propre appareil avec un mot de passe volé |

Avant `-Enforce`, consulte Entra > Journaux de connexion > onglet **Rapport uniquement** : chaque connexion indique ce que les stratégies auraient fait. Un réglage manuel accompagne CA003 : Entra > Appareils > Paramètres > « Exiger l'authentification multifacteur pour inscrire ou joindre des appareils » = **Non**, car CA003 prend le relais.

> 📸 `07-ca-policies.png` : liste des stratégies CA avec leur état.
> 📸 `07-ca-report-only.png` : détail d'une connexion, onglet Rapport uniquement.
> 📸 `07-mfa-prompt.png` : invite Authenticator (correspondance de nombre) lors d'une connexion de test.
> 📸 `07-mfa-registration.png` : Entra > Méthodes d'authentification > Détails de l'inscription des utilisateurs.

## Rapport — `27-Export-M365Report.ps1`

```powershell
.\scripts\m365\27-Export-M365Report.ps1 -IncludeExchange
```

Le script produit `output/evidence/m365-<date>/index.html` : licences, utilisateurs et licences effectives, groupes, rôles Entra, inscription MFA, stratégies CA (avec la définition JSON complète), appareils Intune, conformité, profils, boîtes et durcissement Exchange. Il ne fait que lire : aucune modification du tenant.
