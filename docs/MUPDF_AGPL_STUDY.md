# MuPDF sous AGPL : décision technique pour Paper Studio

> Document historique de l’étude préalable. MuPDF a depuis été adopté dans la version 0.1 sous AGPL-3.0-or-later. Le target Xcode inclut maintenant le pont C et la compilation du moteur ; voir [le guide actuel](BUILD_MACOS.md). Les réserves ci-dessous décrivent l’état au moment de l’étude, pas le raccordement actuel. La validation Xcode reste à faire.

Étude du 3 novembre 2026, à la suite du choix utilisateur d’étudier un moteur libre sous AGPL pour une application libre compatible.

**Conclusion : MuPDF est un candidat viable pour l’édition du contenu PDF et l’export DOCX, avec un prototype C validé sur Linux. Son intégration iPadOS, la qualité sur des documents réels et la distribution de l’application ne sont pas encore validées.**

## Sources effectivement consultées

Version stable étudiée : **1.28.6**, commit `da5f5eb890d7b3fb76903160b5f7f48ba1301492`, obtenu par Git HTTPS depuis Artifex. Version épinglée pour l’essai, sans promesse sur les futures versions ou leur sécurité.

- [README](https://github.com/ArtifexSoftware/mupdf/blob/1.28.6/README), [COPYING](https://github.com/ArtifexSoftware/mupdf/blob/1.28.6/COPYING), [documentation de licence](https://github.com/ArtifexSoftware/mupdf/blob/1.28.6/docs/license.md).
- [Construction du moteur](https://github.com/ArtifexSoftware/mupdf/blob/1.28.6/docs/guide/install.md), `Makefile`, `Makerules`, `Makethird` et sous-modules de cette révision.
- [API de redaction](https://github.com/ArtifexSoftware/mupdf/blob/1.28.6/include/mupdf/pdf/page.h), [filtres de contenu](https://github.com/ArtifexSoftware/mupdf/blob/1.28.6/include/mupdf/pdf/interpret.h), [ajout de ressources image](https://github.com/ArtifexSoftware/mupdf/blob/1.28.6/include/mupdf/pdf/resource.h).
- [Writers DOCX et ODT](https://github.com/ArtifexSoftware/mupdf/blob/1.28.6/source/fitz/writer.c) et dépendance `thirdparty/extract` épinglée à `8750ac39c30a0d65119b426b5a491c5b8e8bf674`.
- [Lecteur iOS officiel](https://github.com/ArtifexSoftware/mupdf-ios-viewer/tree/a5e7da5fcc2c3e196f05dda50b90829392ab97c0), notamment README, `build_libs.sh`, `setup_build.sh` et projet Xcode. Le commit consulté date du **8 mars 2018**, cible iOS 8 et utilise des options bitcode anciennes. Il établit un précédent d’intégration, pas la compatibilité actuelle avec iPadOS 17/Xcode 16.

Les sources officielles de PDF Expert et les pages Apple restent refusées par le proxy HTTP dans l’instance courante. L’étude repose sur les dépôts officiels accessibles, sans utiliser de miroir pour contourner ce refus.

## Résultats exécutés

Le moteur et ses dépendances utiles ont été compilés ici en C/C++ avec GNU Make, sans viewer graphique, moteur OCR Tesseract, barcode ni réseau intégré. Le prototype appelle directement la bibliothèque C, pas uniquement un wrapper Python.

**11 tests natifs Linux exécutés, 11 réussis, aucun ignoré.** Les sorties sont dans `build/mupdf-study/`, avec le rapport horodaté `report.json`. [Code et reproduction](../experiments/mupdf/README.md).

| Fonction | Résultat prouvé sur la fixture | Travail restant |
| --- | --- | --- |
| Retirer du texte existant | Texte ciblé absent de l’extraction après réécriture | Unicode, ligatures, textes invisibles, documents complexes |
| Remplacer du texte | Retrait puis insertion de vrai texte PDF, hors annotation | Police, styles, composition et reflow ; ce n’est pas un éditeur WYSIWYG complet |
| Remplacer une image | Image de la première page modifiée, occurrence sur seconde page préservée | Sélection d’occurrence sur une même page, XObjects imbriqués, images inline et masques |
| Redaction vectorielle | Texte retiré, autres textes restés sélectionnables, sauvegarde non incrémentale | Audit métadonnées/pièces jointes/calques/formulaires ; pas de certification |
| PDF vers Word | DOCX produit et XML contenant les textes attendus | Fidélité des tableaux/images/styles, corpus de documents réels |
| PDF vers Excel/PowerPoint | Non prouvé par cette étude | Aucun engagement de prise en charge |
| iPadOS | Précédent officiel Objective-C/C | Build moderne arm64 et simulateur, pont Swift et tests Xcode |

La compilation a produit cinq avertissements GCC dans le sous-module Extract (`ctm0` et `wmode0` potentiellement non initialisés). Ils n’ont pas été masqués. Ils n’empêchent pas l’essai, mais doivent être examinés avant production.

## Modèle de licence compatible à préparer

Les textes officiels déclarent MuPDF sous **AGPL-3.0-or-later**, avec une alternative commerciale. Le choix libre demandé est cohérent avec une application dont l’ensemble du code combiné peut être distribué sous une licence compatible.

La publication du code n’est qu’une partie du travail. Pour une application intégrant MuPDF, préparer :

- Le texte de licence et les notices appropriées dans le dépôt et dans une vue accessible de l’application (section 5 du texte AGPL pour les interfaces concernées).
- Le code source correspondant de la version distribuée, les modifications du moteur, les révisions exactes, dépendances et scripts de construction nécessaires (définitions et section 6).
- La préservation des notices/licences des sous-modules et polices. Le fichier COPYING de MuPDF ne remplace pas leurs propres notices.
- Si un service réseau modifié sous AGPL est ultérieurement ajouté, les obligations de mise à disposition du source aux utilisateurs interagissant avec lui (section 13).
- La vérification du canal de distribution iOS : ses restrictions contractuelles/techniques ne doivent pas ajouter des restrictions incompatibles avec la section 10. Une licence AGPL n’établit pas automatiquement une compatibilité avec les conditions actuelles de l’App Store. La documentation Apple n’a pas été consultée avec succès ici ; aucune conclusion de conformité App Store n’est affirmée.

Cette étude ne change pas silencieusement la licence de toute l’application. Les seuls nouveaux fichiers d’essai portent la licence AGPL et son texte complet. **Le dépôt d’application n’a pas encore de licence racine déclarée** : il faudra régler ce point avant de le présenter comme une application libre distribuable. Aucun abonnement ni licence commerciale n’a été acheté ou supposé disponible.

## Intégration recommandée

Conserver SwiftUI/PDFKit pour l’interface, la navigation et les annotations. Ajouter le moteur C derrière un adaptateur dédié aux opérations sur le contenu. Ne pas remplacer la bibliothèque locale ou les workflows déjà écrits.

1. Construire une bibliothèque MuPDF et ses dépendances avec les SDK Apple actuels, pour iPad arm64 et simulateur arm64/x86_64, puis assembler un XCFramework. Le Makefile courant étudié ne fournit pas le chemin iOS historique du lecteur de 2018 ; un build moderne doit être établi et testé, sans recopier aveuglément son script.
2. Écrire un pont C/Objective-C avec des types simples (octets, rectangles, indices et erreurs). Encapsuler tous les appels susceptibles de lever une exception dans `fz_try`/`fz_always`/`fz_catch` **du côté C** : le mécanisme longjmp ne doit pas traverser des frames Swift. Définir explicitement la propriété et la libération des buffers.
3. Sérialiser les opérations sur un contexte de moteur dédié. Travailler sur un instantané du document, vérifier permissions et authentification, produire une copie complète, puis la charger dans PDFKit. N’écraser le document de travail qu’après succès et validation ; préserver annulation/rétablissement et mot de passe.
4. Définir une conversion de coordonnées par page incluant MediaBox/CropBox, rotation, transformation PDFKit et espace MuPDF. La fixture simple ne vérifie pas les rotations ou crop boxes décalées.
5. Définir le comportement des polices, encodages, débordements et ressources partagées. Proposer un remplacement explicite avec aperçu lorsque la police d’origine n’est pas réutilisable ; ne pas présenter l’algorithme de la fixture comme une édition fidèle générale.
6. Porter les 11 tests du prototype dans la validation native, puis ajouter un corpus réel : Unicode, RTL, polices sous-ensembles, pages tournées, images partagées/inline, XObjects imbriqués, chiffrement et formulaires. Vérifier les outputs dans plusieurs lecteurs PDF et Word.

**Décision proposée : retenir MuPDF pour un prototype d’intégration iPadOS sous AGPL, sans le déclarer prêt pour la production ni promettre une parité complète avec PDF Expert.** Le moteur n’est pas ajouté au target Xcode à ce stade ; la construction Apple et la politique de distribution restent à établir. Les 21 tests XCTest de l’application restent non exécutés sur Linux.
