# Licences et sources correspondantes

Paper Studio 0.1 est distribué sous **AGPL-3.0-or-later** ; voir [LICENSE](LICENSE).

MuPDF est adopté sous AGPL-3.0-or-later, sans licence commerciale. Version épinglée : **1.28.6**, commit `da5f5eb890d7b3fb76903160b5f7f48ba1301492`, dépôt https://github.com/ArtifexSoftware/mupdf. Copyright 2006–2026 Artifex Software, Inc.

`scripts/fetch-mupdf.sh` récupère les sources officielles et les sous-modules à leurs révisions Git exactes. Aucun patch des sources du moteur n’est appliqué. Un en-tête de compatibilité iOS pour `sys/random.h` est fourni dans `Native/AppleCompat`, avec une implémentation basée sur `arc4random_buf`. Les adaptations propres à l’application sont dans `Native/`, `PaperStudio/MuPDFEngine.swift` et les scripts de construction. `scripts/prepare-mupdf-notices.py` copie sans modification les fichiers LICENSE/COPYING/NOTICE/COPYRIGHT présents dans ces sources et leurs polices. Ces textes sont inclus dans le bundle et consultables dans l’application via **À propos et licences**.

Les dépendances MuPDF conservent leurs propres licences : le fichier COPYING de MuPDF ne les remplace pas. Les outils facultatifs de syntaxe JavaScript restent des dépendances de développement, avec leurs licences déclarées dans `scripts/swift-syntax/package-lock.json` ; ils ne sont pas embarqués dans l’application.

Pour une distribution binaire, fournir l’accès au code source correspondant de la version distribuée, aux sources/dépendances épinglées, aux notices et aux scripts de construction. Les scripts présents permettent la récupération de ces sources. Ne pas publier uniquement un binaire sans le source correspondant. La compatibilité d’un canal de distribution particulier, notamment l’App Store et ses conditions actuelles, n’est pas établie par cette version 0.1.
