# Compiler Paper Studio 0.1 sur macOS

## 1. Préparer le Mac

- macOS compatible avec **Xcode 16+**, Xcode installé et ouvert une première fois.
- Git, Python 3, Make et compilateurs Apple disponibles dans le Terminal.
- Connexion HTTPS vers GitHub/les dépôts Artifex pour les sources MuPDF et leurs dépendances.
- Un runtime iOS installé dans les réglages Xcode **Components/Platforms**, contenant un simulateur iPad.
- Plusieurs Go d’espace libre pour les sources, les bibliothèques et DerivedData.

Vérifier :

```bash
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-path
xcrun --sdk iphonesimulator --show-sdk-path
python3 --version
git --version
make --version
```

Si les outils pointent seulement vers CommandLineTools, sélectionner le Xcode complet depuis **Xcode → Settings → Locations → Command Line Tools**. Avec une installation standard, cette commande fait le même choix :

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
```

Accepter les conditions et terminer les composants demandés au premier lancement de Xcode. Aucun token GitHub ni secret applicatif n’est nécessaire pour cloner un dépôt public ou compiler sur simulateur.

## 2. Récupérer le code et MuPDF

Utiliser un chemin **sans espaces** : les Makefiles de MuPDF n’acceptent pas tous les chemins avec espaces. Le script signale explicitement ce cas.

```bash
mkdir -p ~/Developer
cd ~/Developer
git clone --branch v0.1 https://github.com/joako1991/CodePDFExpertOpen.git
cd CodePDFExpertOpen
bash scripts/fetch-mupdf.sh
```

Le script clone MuPDF 1.28.6 dans `Vendor/mupdf`, vérifie le commit exact et récupère les sous-modules requis à leurs révisions épinglées. Il refuse de réinitialiser des modifications locales ou une autre version. Les notices de licence et de polices sont copiées dans `PaperStudio/Legal/MuPDFNotices/` avec leurs empreintes. Ces répertoires sont générés, exclus du dépôt Git et nécessaires à la compilation ; pas de package binaire propriétaire.

Un checkout de MuPDF modifié est conservé. Pour revenir à un état propre, sauvegarder d’abord les modifications puis choisir un nouveau checkout de l’application ou déplacer le cache concerné hors de `Vendor` ; le script ne le fait pas à votre place.

## 3. Compiler et exécuter sur simulateur

```bash
open PaperStudio.xcodeproj
```

1. Sélectionner le scheme partagé **PaperStudio**.
2. Sélectionner un simulateur **iPad** (iPadOS 17 minimum).
3. Exécuter avec **⌘R**.

La première phase du target exécute `scripts/build-mupdf-xcode.sh`. Elle utilise le SDK sélectionné, le triple de cible `arm64-apple-ios17.0` ou `…-simulator`, et les sources vendorizées. Elle construit les bibliothèques statiques MuPDF et ses dépendances, les assemble dans `libPaperMuPDF.a`, puis le target compile `Native/PSPDFEngine.c` et importe son API via le bridging header Swift.

Les compilations device et simulateur utilisent des répertoires distincts. Pour un simulateur Intel le script prend en charge `x86_64`, et pour Apple Silicon `arm64`. Le SDK, la version du compilateur et les flags entrent dans une signature de cache : si elle change, les objets générés de la slice concernée sont reconstruits. Aucun accès réseau n’est effectué pendant la phase Xcode. Trois tâches Make sont utilisées pour limiter les ressources.

La phase a son sandbox de scripts Xcode désactivé car les Makefiles compilent leurs sources et génèrent des objets hors du répertoire DerivedData. Les scripts restent dans le dépôt et sont inspectables. Le build ne nécessite ni les scripts iOS historiques de MuPDF de 2018, ni bitcode, ni Homebrew, ni SDK Office commercial.

Une compilation CLI sans signature pour le simulateur est aussi possible :

```bash
xcodebuild -project PaperStudio.xcodeproj -scheme PaperStudio \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```

## 4. Installer sur votre iPad

1. Brancher l’iPad au Mac, approuver la relation de confiance sur les deux appareils.
2. Activer **Réglages → Confidentialité et sécurité → Mode développeur** si demandé, puis suivre les indications de l’iPad.
3. Dans le target **PaperStudio → Signing & Capabilities**, choisir votre **Team** Apple et conserver la signature automatique.
4. Choisir un identifiant de bundle unique sous votre contrôle, à la place de `org.paperstudio.app` si nécessaire.
5. Sélectionner l’iPad comme destination et exécuter **⌘R**.

Les possibilités et durées d’installation dépendent du compte Apple utilisé. Un compte gratuit peut suffire au développement personnel avec ses restrictions ; la distribution est un sujet distinct. Aucun certificat ni mot de passe ne doit être ajouté aux sources.

Le scanner caméra s’active seulement sur les appareils VisionKit compatibles. iPadOS demande la permission de caméra au premier usage. Photos utilise le sélecteur système. Les documents sont traités localement, sans serveur.

## 5. Tester

```bash
bash scripts/test-ios.sh
```

Le script sélectionne automatiquement un simulateur iPad disponible et lance les **24 XCTest**. Pour imposer un appareil :

```bash
xcrun simctl list devices available
IOS_TEST_DESTINATION='platform=iOS Simulator,id=UDID-DU-SIMULATEUR' \
  bash scripts/test-ios.sh
```

Les résultats sont dans `build/TestResults-<date>.xcresult`, ouvrables avec Xcode. Un code zéro doit correspondre à des tests effectivement exécutés. Les résultats de CI sont accessibles dans l’onglet **Actions** du dépôt ; inspecter le run du commit utilisé, sans déduire sa réussite de la simple présence du workflow.

Tests manuels prioritaires sur iPad : remplacement d’une ligne et annulation, image partagée sur plusieurs pages, PDF chiffré, copie protégée dans un autre lecteur, DOCX ouvert dans Word/Pages, OCR, formulaire, scanner et signature Pencil. Tester des pages tournées et recadrées, ainsi que la consommation mémoire sur un gros PDF.

## 6. Dépannage et limites connues

| Symptôme | Vérification |
| --- | --- |
| MuPDF sources/notices missing | Exécuter `bash scripts/fetch-mupdf.sh` depuis le checkout. |
| SDK non trouvé | Sélectionner le Xcode complet et installer le runtime iOS. |
| Chemin avec espaces | Refaire le checkout dans un chemin tel que `~/Developer/CodePDFExpertOpen`. |
| Aucun iPad disponible | Installer un runtime et créer/activer un simulateur iPad. |
| Signature refusée | Vérifier Team, bundle identifier, compte Apple et destination device. |
| Texte trop long | Réduire la taille ou raccourcir le remplacement ; une seule ligne est prise en charge. |
| Aucune image à cet endroit | Toucher une image du contenu PDF, pas une annotation, un dessin vectoriel ou un widget. |
| Image inline | Cette forme d’image n’est pas remplaçable en 0.1. |
| Résultat Word imparfait | La conversion locale ne garantit pas la fidélité des tableaux, colonnes, images et polices. |

Le code est préparé pour les SDK Apple actuels, mais **aucune compilation Xcode n’a été exécutée dans l’environnement Linux de préparation**. Les tests natifs Linux valident le pont C, pas SwiftUI, PDFKit, la signature ou l’interface iPad. Ne pas interpréter les analyses syntaxiques comme une validation de ces API.

## 7. Licence et diffusion

L’adoption de MuPDF est faite sous **AGPL-3.0-or-later**. La licence complète, les attributions et notices de dépendances sont visibles dans l’app. Le dépôt contient le pont, les adaptations et les scripts pour récupérer les sources exactes du moteur. Voir [les notices](../THIRD_PARTY_NOTICES.md).

La version 0.1 publie le **code source**, pas un binaire signé ou une application App Store. Avant toute distribution binaire, préparer le source correspondant et vérifier les conditions du canal choisi. La publication du dépôt et du tag ne constitue pas une validation de conformité App Store.
