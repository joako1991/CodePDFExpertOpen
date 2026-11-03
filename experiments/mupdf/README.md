# Étude MuPDF sous AGPL

Cet essai **n’est pas lié à l’application iPadOS**. Il vérifie des opérations natives C sur Linux avant de choisir une intégration mobile. Les fichiers de cet essai portent `SPDX-License-Identifier: AGPL-3.0-or-later` ; le texte complet est dans [COPYING](COPYING). Cela ne déclare pas une licence pour tous les autres fichiers du dépôt.

Version : **MuPDF 1.28.6**, commit `da5f5eb890d7b3fb76903160b5f7f48ba1301492`, depuis le dépôt officiel Artifex. Les sous-modules sont ceux épinglés dans cette révision. Aucun binaire téléchargé d’un fournisseur tiers n’est utilisé.

## Reproduire sur Linux

Prérequis : Bash, Git, Python 3, GNU Make, compilateurs C/C++ et accès HTTPS aux dépôts GitHub Artifex. Utiliser les proxy et certificats fournis par l’environnement.

```bash
bash experiments/mupdf/fetch-build.sh
```

Le script télécharge les sources dans `/tmp/paperstudio-mupdf-study/mupdf`, initialise les dépendances nécessaires, compile `mutool` avec trois tâches, compile le prototype C puis lance les 11 tests. Il réutilise les sorties valides et refuse de réinitialiser un checkout existant à une autre révision. La compilation neuve a pris quelques minutes ici. La source et la compilation restent hors du checkout de l’application.

Pour un autre emplacement :

```bash
MUPDF_STUDY_SOURCE=/tmp/mon-etude-mupdf bash experiments/mupdf/fetch-build.sh
```

Si MuPDF est déjà compilé :

```bash
python3 experiments/mupdf/run-study.py \
  --source /tmp/paperstudio-mupdf-study/mupdf --output build/mupdf-study
```

La compilation du prototype C échoue avec son code de sortie d’origine si une commande échoue. Les tests utilisent `unittest` et échouent si le nombre attendu de tests ne s’exécute pas. Aucun fichier utilisateur n’est accepté par le runner : il crée sa propre fixture. Les sorties générées dans `build/mupdf-study` sont remplaçables et ne doivent pas servir à stocker des fichiers personnels.

## Résultat observé

**11 tests exécutés et réussis sur Linux.** Ils vérifient :

1. Fixture PDF lisible, texte extractible, deux pages.
2. Suppression de `ORIGINAL_SECRET` par les API de redaction.
3. Préservation des textes hors de la zone et de la seconde page.
4. Réécriture complète sans chaîne de sauvegarde incrémentale `/Prev`.
5. Remplacement par du vrai contenu PDF `REPLACEMENT_TEXT` sélectionnable.
6. Remplacement sans annotation FreeText.
7. Pixels de l’image de première page devenus bleus.
8. Image partagée sur la seconde page restée rouge malgré un dictionnaire de ressources initialement partagé.
9. Original conservé octet pour octet.
10. Fichier invalide rejeté, sans PDF de sortie.
11. Export DOCX valide contenant les textes attendus dans `word/document.xml`.

`build/mupdf-study/report.json` contient la révision, l’empreinte du prototype, l’heure d’exécution et les compteurs. Les PDF, images PPM et DOCX générés permettent l’inspection des résultats. Les résultats ne valident pas des documents arbitraires, les mises en page complexes, les polices incorporées ou la compilation iOS.

Le build de MuPDF a émis cinq avertissements GCC `-Wmaybe-uninitialized` dans `thirdparty/extract/src/join.c`. La compilation et les tests réussissent ; ces diagnostics sont conservés et restent à examiner avant une adoption en production.

## Portée technique

Le remplacement de texte démontré consiste à supprimer le contenu couvert puis à réinsérer une chaîne avec Helvetica. Il ne conserve pas automatiquement la police d’origine, le crénage, les styles ou la mise en page. Les chaînes et coordonnées de la fixture sont contrôlées ; ce code n’est pas une API générale prête à recevoir du texte utilisateur.

Le remplacement d’image réaffecte une ressource de la première page en copiant les dictionnaires partagés. Toutes les occurrences de cette ressource sur cette page seraient affectées. Une sélection d’occurrence unique, les images inline, les masques et les Form XObjects imbriqués demandent un filtrage supplémentaire.

La redaction testée retire le texte ciblé tout en conservant le reste vectoriel. Ce n’est pas une certification de caviardage : métadonnées, pièces jointes, champs, calques, historique et contenus invisibles nécessitent une stratégie et des tests dédiés.

Le DOCX obtenu prouve la présence d’un writer fonctionnel dans cette version ; il ne prouve pas la fidélité Word ni les conversions Excel/PowerPoint.

Voir [l’analyse d’intégration et de licence](../../docs/MUPDF_AGPL_STUDY.md).
