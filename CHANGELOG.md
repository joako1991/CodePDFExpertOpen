# Historique

## 0.1 — 3 novembre 2026

Première version de développement iPadOS 17+, sous AGPL-3.0-or-later.

- Bibliothèque et éditeur SwiftUI/PDFKit : annotations, signature, formulaires, recherche, signets et gestion des pages.
- MuPDF 1.28.6 adopté : pont C avec exceptions contenues, intégration Swift asynchrone, remplacement d’une ligne et d’une occurrence d’image, export DOCX.
- Compilation MuPDF par plateforme/architecture depuis des sources épinglées, sans patch ni binaire propriétaire.
- OCR local, scanner, imports images, exports protégés/aplatis et masques intégrés aux pixels.
- Licence, notices et sources accessibles dans l’application ; guide macOS et installation sur iPad.
- 16 tests du pont C vérifiés sur Linux ; 24 XCTest et workflow macOS fournis. La compilation complète Apple n’est pas validée dans l’environnement Linux de préparation.

Limites : police et mise en page d’origine non conservées lors du remplacement de texte, une seule ligne, images inline refusées, fidélité DOCX non garantie, pas de conversion Excel/PowerPoint, synchronisation cloud propre ou IA. Pas de binaire iPad signé fourni.
