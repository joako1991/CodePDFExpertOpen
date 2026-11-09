# Historique

## En développement — main

- Comportements issus de la vidéo : modes Annoter/Modifier/Remplir et signer/Exporter, palettes permanentes et réglages par second toucher sur l’outil.
- Marqueur libre, pression du Pencil, Scribble natif, gommes entière/partielle, lignes et flèches, bordures et remplissages, coches/croix/dates/tampons.
- Navigation par annotations et sommaire, thèmes jour/sépia/nuit, dispositions de lecture, lecture vocale et maintien de l’écran éveillé.
- Insertion d’images en annotations PDF, liens et biffure de contenu avec MuPDF ; tests natifs de suppression du contenu et de conservation des autres occurrences d’image.
- Comparaison horodatée de la référence et inventaire des fonctions Premium, avec limites explicites des conversions et de l’IA.
- Régénération de l’apparence des annotations enregistrées lors du changement de style et de la gomme partielle ; vérifications de pixels et annulation de l’apparence précédente. Mise en forme directe d’un texte sélectionné et réglages adaptés au type d’annotation.

- Saisie et modification de texte/notes directement sur la page ; mise en forme visible pendant la saisie, sans fenêtre de confirmation séparée.
- Réactivité : prévisualisation par rafraîchissement, fin du délai fixe de sélection et des animations implicites de tracé, déplacement/redimensionnement visibles pendant le geste.
- Historique d’annulation par opérations ; les annotations et gestes ne copient plus le PDF entier. Historique compatible avec les remplacements de document MuPDF.
- Miniatures en arrière-plan, cache limité en mémoire et invalidation de la seule page modifiée ; défilement à deux doigts pendant l’édition.

- Interface en anglais, espagnol et français avec choix persistant et changement immédiat.
- Outils activables/désactivables, réglages avant usage, application automatique du marquage lors de la sélection.
- Zones de texte placées par toucher/glissement, poignée de redimensionnement, police/taille/graisse/couleur configurables.
- Notes et signatures placées sur la page ; remplacement MuPDF activé avant sélection.
- OCR espagnol et tests de régression des outils, du placement et des ressources de traduction.

## 0.1 — 3 novembre 2026

Première version de développement iPadOS 17+, sous AGPL-3.0-or-later.

- Bibliothèque et éditeur SwiftUI/PDFKit : annotations, signature, formulaires, recherche, signets et gestion des pages.
- MuPDF 1.28.6 adopté : pont C avec exceptions contenues, intégration Swift asynchrone, remplacement d’une ligne et d’une occurrence d’image, export DOCX.
- Compilation MuPDF par plateforme/architecture depuis des sources épinglées, sans patch ni binaire propriétaire.
- OCR local, scanner, imports images, exports protégés/aplatis et masques intégrés aux pixels.
- Licence, notices et sources accessibles dans l’application ; guide macOS et installation sur iPad.
- 16 tests du pont C vérifiés sur Linux ; compilation iPadOS et exécution du scheme de 24 XCTest réussies sur simulateur dans la CI macOS. Les essais matériels et la signature personnelle restent à effectuer.

Limites : police et mise en page d’origine non conservées lors du remplacement de texte, une seule ligne, images inline refusées, fidélité DOCX non garantie, pas de conversion Excel/PowerPoint, synchronisation cloud propre ou IA. Pas de binaire iPad signé fourni.
