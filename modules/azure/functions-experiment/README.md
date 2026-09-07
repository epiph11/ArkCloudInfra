# Expérimentation Azure Functions (Sprint 6) — retenu de facto en attendant Kudu

**Mise à jour du 07/09/2026** : ce module n'a jamais été démonté, contrairement à ce que ce
README affirmait — vérifié dans `environments/dev/main.tf` et dans le state Terraform réel. Il
tourne toujours en production, et `arkcloud_app` fonctionne réellement dessus (c'est ce qui a
servi à la bascule côté Azure). **Ne pas suivre la section "Démonter" ci-dessous** tant que Kudu
n'a pas été implémenté et vérifié en remplacement (voir ADR-0010, addendum) — la section reste
documentée pour quand ce jour viendra, pas comme une action en attente.

Ce module n'est **pas** la solution retenue à terme pour STRIDE flux 3 côté Azure — l'ADR-0010 a
tranché pour une procédure manuelle via Kudu SSH, jugée plus simple à maintenir sur le long terme.
Mais l'implémentation de Kudu est repoussée en backlog (elle demande d'ajouter un serveur SSH au
Dockerfile de `ArkCloud.API`, jamais fait à ce jour), donc ce Function App reste le mécanisme réel
utilisé pour toute rotation de `arkcloud_app` côté Azure d'ici là.

Contexte complet : `main.tf` (en-tête) et `README.md` racine d'ArkCloudInfra, §10.

## Déployer

1. Construire le paquet :
   ```bash
   bash modules/azure/functions-experiment/build.sh
   ```
   Beaucoup plus simple que l'équivalent AWS (`modules/aws/secret-rotation/lambda/build.sh`) :
   pas d'installation pip locale, le zip ne contient que les 3 fichiers source.

2. `terraform plan` / `terraform apply` depuis `environments/dev` comme d'habitude — crée toute
   l'infra (Function App, Storage, réseau) mais **ne déploie pas le code**. `zip_deploy_file`
   n'est volontairement pas utilisé : bug réel, actuellement ouvert côté provider `azurerm`
   ([issue #29630](https://github.com/hashicorp/terraform-provider-azurerm/issues/29630)) — il
   pousse le code via l'ancien point d'entrée Kudu `api/zipdeploy`, que Flex Consumption n'a
   jamais supporté. Constaté ici en premier lieu par une vraie erreur 404/502 à l'`apply`, pas
   supposé à l'avance.

3. Déployer le code séparément, via le CLI (qui utilise le bon mécanisme — OneDeploy) :
   ```powershell
   az functionapp deployment source config-zip `
     --resource-group rg-arkcloud-dev `
     --name func-arkcloud-dev-app-role-experiment `
     --src modules/azure/functions-experiment/build/function.zip `
     --build-remote true
   ```
   `--build-remote true` est indispensable : c'est lui qui déclenche l'installation des
   dépendances (`psycopg2-binary` notamment) côté serveur, contre la bonne cible Linux/Python
   3.11. Sans ce flag, le paquet déployé ne contient que le code source, sans ses dépendances.

## Invoquer

Récupérer la clé de fonction (auth level `FUNCTION` — pas anonyme, pas besoin d'Azure AD pour cet
essai) :

```powershell
az functionapp keys list --resource-group rg-arkcloud-dev --name func-arkcloud-dev-app-role-experiment
```

Puis :

```powershell
curl -X POST "https://func-arkcloud-dev-app-role-experiment.azurewebsites.net/api/bootstrap-app-role?code=<clé>"
```

Réponse attendue (premier appel) : `{"status": "ok", "role": "arkcloud_app", "role_created": true}`.
Un second appel donnera `"role_created": false` (la fonction est idempotente — `ALTER ROLE` au
lieu de `CREATE ROLE` si le rôle existe déjà, même logique que `rotate.py` côté AWS).

## Vérifier

```powershell
az functionapp log deployment show --resource-group rg-arkcloud-dev --name func-arkcloud-dev-app-role-experiment
```

Ou le flux de logs live (équivalent Kudu du `aws logs tail --follow` utilisé côté AWS) :

```powershell
az webapp log tail --resource-group rg-arkcloud-dev --name func-arkcloud-dev-app-role-experiment
```

Confirmer ensuite que `arkcloud_app` existe réellement et porte le mot de passe attendu — pas
seulement que la fonction a répondu `200` :

```powershell
az keyvault secret show --vault-name kv-arkcloud-dev --name ArkCloudAppRole--Password
```

## Démonter (une fois l'essai concluant)

```
terraform destroy -target=module.functions_experiment
```

Puis retirer le bloc `module "functions_experiment"` et la ligne `functions_subnet_prefix` dans
`environments/dev/main.tf`. Le sous-réseau et son NSG dans `modules/azure/network` sont
`count`-gated sur cette même variable — ils disparaissent automatiquement, aucune modification à
faire dans ce module partagé.
