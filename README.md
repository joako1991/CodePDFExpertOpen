# Paper Studio 0.1 — éditeur PDF pour iPad

Application native en anglais, espagnol et français pour **iPadOS 17+**, sous **AGPL-3.0-or-later**. Interface SwiftUI, lecture/annotations PDFKit, OCR Vision, scanner VisionKit et **édition du contenu avec MuPDF 1.28.6**. Application indépendante de PDF Expert/Readdle, avec son propre nom et sa propre interface.

## Changements en développement sur `main`

- Choix de langue English / Español / Français dans la barre latérale, conservé au redémarrage. Le changement de l’interface ne ferme pas le document et ne traduit pas les PDF de l’utilisateur. Les sélecteurs système iOS peuvent suivre la langue de l’appareil.
- Outils persistants : activer, configurer, puis utiliser sur la page. Toucher à nouveau le bouton ouvre ses réglages ; choisir Lire ou Terminer désactive l’outil. Les commandes de document (export, rotation, etc.) restent des actions directes.
- Soulignement bleu par défaut, surlignage jaune et barré rouge : activer d’abord, puis sélectionner/glisser sur le texte pour appliquer automatiquement. Chaque outil conserve sa couleur configurée durant la session.
- Texte : activer, toucher le point de départ ou tracer le cadre, puis écrire directement sur la page sans fenêtre de saisie séparée. Terminer valide le texte ; Annuler ferme la saisie sans ajouter d’annotation. Choisir famille (sans empattement, avec empattement, monospace), taille, graisse et couleur. Pour modifier un texte existant, sélectionner son annotation puis Modifier le texte. Pour redimensionner, activer Déplacer, sélectionner la zone et tirer sa poignée inférieure droite.
- Notes et signatures placées à l’endroit touché. Le remplacement de contenu MuPDF s’active également avant de sélectionner la ligne ou l’image.

Ces changements sont sur `main` ; le tag `v0.1` conserve la version publiée. Sur un Mac ayant cloné ce tag, conserver vos modifications locales puis utiliser `git fetch origin`, `git switch main` et `git pull --ff-only origin main` pour récupérer le développement courant.

### Réactivité de l’éditeur

- Le soulignement, le surlignage et le barré apparaissent pendant le glissement, sans étape de sélection bleue préalable. Le trait, le marquage et les cadres suivent le geste à chaque rafraîchissement de l’écran. Le déplacement et le redimensionnement des annotations s’affichent pendant le glissement ; une seule étape d’annulation est enregistrée au relâchement.
- L’annulation des annotations, formulaires, rotations et changements de pages conserve les objets modifiés au lieu de sérialiser le PDF entier à chaque action.
- Les miniatures sont mises en cache et rendues en arrière-plan. Seule la miniature d’une page modifiée est invalidée ; changer d’outil ne relance pas leur rendu.
- Un doigt utilise l’outil actif ; deux doigts font défiler la page. Le pincement conserve le zoom. Les exports et le traitement MuPDF restent des opérations de document distinctes.

Pour vérifier sur iPad : annoter un PDF long avec le volet des pages ouvert, dessiner rapidement, déplacer/redimensionner une zone de texte, annuler/rétablir, puis enregistrer et rouvrir. La validation sur simulateur ne mesure pas la latence d’un iPad physique.

### Comportements de la vidéo de référence

L’éditeur reprend les modes **Annoter / Modifier le PDF / Remplir et signer / Exporter**. Les palettes de couleurs restent visibles ; toucher à nouveau l’outil ouvre ses réglages. Les formes partagent couleur/épaisseur/opacité, et une forme sélectionnée se met à jour pendant le réglage. Les panneaux de bibliothèque et de pages sont repliés pendant la lecture.

Le stylo accepte la pression et les points coalescés du Pencil ; le marqueur libre permet les traits diagonaux, indépendamment du surlignage de texte. La gomme a des modes trait entier et partiel, avec annulation du geste complet. Le texte propose Helvetica 12 pt par défaut, une barre de police/taille/graisse/couleur et l’écriture native Scribble. Le mode Remplir et signer ajoute coches, croix, dates et tampons par touches répétées.

Les fonctions locales de remplacement du texte/des images, insertion d’image, liens, biffure réelle, signature manuscrite, DOCX et OCR ne comportent aucun abonnement. **Le remplacement de texte reste limité à une ligne avec une police de substitution ; Excel/PowerPoint et l’IA ne sont pas implémentés.**

Le détail des observations, des écrans Premium et des limites se trouve dans [la comparaison de la vidéo](docs/REFERENCE_BEHAVIOR.md).

## Compiler sur macOS

Il faut **Xcode 16 ou ultérieur**, ses outils en ligne de commande, Git, Python 3 et un accès Internet pour récupérer les sources du moteur. Installer un runtime iOS dans Xcode pour les tests sur simulateur. Utiliser un chemin de checkout **sans espaces** (limitation des Makefiles MuPDF).

```bash
git clone https://github.com/joako1991/CodePDFExpertOpen.git
cd CodePDFExpertOpen
bash scripts/fetch-mupdf.sh
open PaperStudio.xcodeproj
```

Dans Xcode, sélectionner **PaperStudio** puis un simulateur iPad et exécuter avec **⌘R**. La phase **Build MuPDF 1.28.6** compile automatiquement les bibliothèques C/C++ pour la plateforme et les architectures choisies. Le premier build prend plusieurs minutes ; les suivants réutilisent les objets valides. Aucun binaire MuPDF tiers n’est téléchargé.

Pour votre iPad : connecter l’appareil au Mac, activer le mode développeur, choisir une équipe dans **Signing & Capabilities** et un bundle identifier unique, sélectionner l’iPad puis ⌘R. Xcode gère la signature ; ne placer aucun certificat ou secret dans le dépôt.

**Guide détaillé : [compiler, tester et installer sur macOS](docs/BUILD_MACOS.md).** L’iPad seul/Swift Playgrounds ne compile pas directement ce projet Xcode avec son moteur C/C++.

## Fonctionnalités de la version 0.1

- Bibliothèque locale avec import PDF, vignettes, recherche, renommage, duplication, partage et suppression avec confirmation.
- Lecture, recherche dans le texte, navigation par pages, signets locaux.
- Surlignage, soulignement, barré, notes, texte ajouté, dessin, formes, signatures graphiques et déplacement d’annotations.
- Rotation, déplacement, suppression, fusion et extraction de pages ; annulation/rétablissement.
- Formulaires AcroForm texte/listes et contrôles PDFKit natifs pour cases/radio.
- **MuPDF : remplacement d’une ligne de texte existante**, en supprimant l’ancien contenu puis en insérant du vrai texte PDF ; police Helvetica ou repli, taille réglable et refus du débordement.
- **MuPDF : remplacement d’une occurrence d’image**, choisie en touchant la page, sans modifier les autres occurrences partageant la même ressource.
- **MuPDF : export Word DOCX**, via un traitement local sans serveur.
- Scanner caméra multipage sur appareil compatible et images de la photothèque vers PDF.
- OCR français/anglais local, extraction texte et export PDF multipage recherchable.
- Exports PNG, texte, PDF protégé, impression, aplatissement/réduction avec comparaison de taille et copie avec zones masquées intégrées aux pixels.
- Notices et licence accessibles dans **À propos et licences**.

Sur `main`, pour remplacer une ligne : ouvrir **Modifier le PDF**, activer l’outil de remplacement de texte, puis toucher la ligne. Pour une image : activer le remplacement d’image, toucher l’image et choisir la nouvelle photo. L’original importé n’est pas modifié : l’application travaille sur une copie locale et les changements du moteur s’intègrent à l’historique d’annulation.

## Validation et limites

La version 0.1 est une **première version de développement**, pas une reproduction complète de PDF Expert Premium.

Le pont C de production sur `main` a été compilé et testé sur Linux : **21 tests natifs passent**, dont texte Unicode, page tournée/cadrée, occurrence d’image partagée ou imbriquée, insertion d’image, biffure de contenu, permissions, conservation du chiffrement, erreurs et DOCX. La syntaxe des **27 fichiers Swift**, le format/raccordement du projet Xcode et les ressources des trois langues sont également vérifiés.

Le scheme sur `main` contient **65 XCTest**, notamment des vérifications de rendu avant validation du geste et après enregistrement/réouverture. La préparation locale reste Linux, sans SDK Apple ; [GitHub Actions](https://github.com/joako1991/CodePDFExpertOpen/actions/workflows/ipados.yml) fournit la compilation et les tests sur simulateur iPad avec Xcode/macOS et teste aussi le pont sur Ubuntu. Consulter le résultat correspondant au commit utilisé. Le tag `v0.1` conserve sa suite initiale de 24 XCTest. Les gestes physiques, la pression du Pencil, Scribble, le scanner et les documents complexes restent à essayer sur un iPad.

L’édition du texte est limitée à une ligne et ne préserve pas automatiquement la police, les styles, la composition ou le reflow d’origine. Le remplacement d’image conserve le cadre actuel et peut déformer le ratio ; les images inline sont refusées. Le DOCX ne garantit pas la fidélité des tableaux, colonnes ou polices ; aucune conversion Excel/PowerPoint n’est proposée. Pas de synchronisation cloud propre à l’application, ni d’assistant IA.

La signature est graphique, sans certification cryptographique. Les thèmes jour/sépia/nuit changent l’affichage sans modifier les couleurs enregistrées du PDF. Les signets sont locaux, non embarqués dans les exports. L’aplatissement et l’OCR réécrivent les pages en images et font perdre les interactions ; un export peut être plus volumineux que l’original. L’export avec masques est distinct de la biffure de contenu MuPDF. Les recherches et certains rendus restent synchrones ; les gros PDF consomment de la mémoire. La pile d’annulation conserve jusqu’à 100 opérations, avec un budget estimé de 64 Mo ; une opération unique plus grosse peut dépasser ce budget. Les opérations natives retiennent les documents avant/après pour l’annulation.

## Tests

Sur Mac après préparation des dépendances :

```bash
bash scripts/test-ios.sh
```

Le script choisit un iPad disponible, respecte `IOS_TEST_DESTINATION` si fourni et conserve un `.xcresult` dans `build/`. Il préserve le code de sortie de `xcodebuild` et quitte avec le code 2 si Xcode manque.

Pour vérifier le pont C sous Linux avec Make et les compilateurs C/C++ :

```bash
bash scripts/fetch-mupdf.sh
make -C Vendor/mupdf -j3 build=release HAVE_X11=no HAVE_GLUT=no HAVE_CURL=no \
  USE_SYSTEM_CURL=no USE_TESSERACT=no USE_ZXINGCPP=no mujs=no tools
python3 scripts/test-native-engine.py --source Vendor/mupdf
```

Contrôles structurels et syntaxiques facultatifs (non équivalents à une compilation Swift) :

```bash
python3 scripts/check-project.py
npm ci --prefix scripts/swift-syntax --no-audit --no-fund
npm run --prefix scripts/swift-syntax check
```

Ces outils JavaScript sont des dépendances de développement uniquement, non embarquées dans l’app.

## Licence et sources

[AGPL-3.0-or-later](LICENSE) pour l’application et le pont. MuPDF est utilisé sous sa licence AGPL, sans licence commerciale. Voir [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Ses sources et sous-modules sont épinglés au commit `da5f5eb890d7b3fb76903160b5f7f48ba1301492` ; les scripts les récupèrent sans patch. Leurs notices et celles des polices sont collectées dans le bundle sans modification. Le JavaScript PDF du moteur est désactivé dans le build de l’application.

Avant une distribution binaire, fournir le code source correspondant, ses notices et les moyens de reconstruction. Aucune compatibilité automatique avec les conditions de distribution de l’App Store n’est affirmée. Les frameworks Apple sont fournis par le système et ne sont pas redistribués dans ce dépôt.

Voir [les changements 0.1](CHANGELOG.md), [le guide macOS](docs/BUILD_MACOS.md), [l’étude MuPDF initiale](docs/MUPDF_AGPL_STUDY.md) et [la comparaison fonctionnelle](docs/PRODUCT_RESEARCH.md). La recherche initiale avait un accès réseau limité ; [la comparaison de la vidéo](docs/REFERENCE_BEHAVIOR.md) distingue les observations et les offres Premium publiées, vérifiées le 9 novembre 2026.

Chaque tâche cloud est déjà isolée : utiliser le checkout existant, sans créer de worktree sauf demande explicite.
