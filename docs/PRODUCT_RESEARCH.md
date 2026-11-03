# Référence fonctionnelle : PDF Expert

## Identification et sources à consulter

PDF Expert est l’éditeur PDF de **Readdle**, historiquement proposé sur iPhone, iPad et Mac. À notre connaissance, Readdle ne propose pas de version Android de ce produit ; les applications Android de nom similaire doivent être identifiées par leur éditeur. Les plateformes et offres actuelles restent à revérifier sur les sources officielles avant publication.

- https://pdfexpert.com/ — présentation et plateformes
- https://pdfexpert.com/ios — application iPhone/iPad
- https://pdfexpert.com/features — fonctions annoncées
- https://support.readdle.com/pdfexpert — documentation et différences entre plateformes
- https://developer.apple.com/documentation/pdfkit — moteur PDF natif
- https://developer.apple.com/documentation/vision/recognizing-text-in-images — OCR
- https://developer.apple.com/documentation/visionkit/vndocumentcameraviewcontroller — numérisation
- https://developer.apple.com/documentation/coretext — couche texte PDF

**Vérification du 3 novembre 2026 : accès officiel encore bloqué.** GitHub et npm sont joignables avec les permissions d’exécution réseau, mais les connexions HTTPS vers `pdfexpert.com` et `developer.apple.com` sont refusées par le proxy avec HTTP 403. Le diagnostic initial de proxy injoignable était observé dans le contexte restreint de l’exécuteur ; l’accès réseau autorisé révèle le refus par domaine. Les domaines nécessaires sont enregistrés dans le brouillon, pas appliqués à l’instance courante.

Ces liens sont des références à vérifier, pas des pages consultées avec succès. La synthèse produit repose sur la connaissance générale. Les prix, intitulés d’abonnements, fonctions IA actuelles et différences exactes entre plateformes ne sont pas affirmés.

## Recherche effectivement réalisée : moteur supplémentaire

Le 3 novembre 2026, les fichiers officiels suivants ont été téléchargés avec succès depuis GitHub :

- https://github.com/ArtifexSoftware/mupdf/blob/master/README
- https://github.com/ArtifexSoftware/mupdf/blob/master/COPYING

Le README présente MuPDF comme un framework de visualisation/conversion PDF, XPS et livres numériques. Le README et COPYING confirment la licence **GNU AGPL version 3 ou ultérieure**, avec une option de licence commerciale à demander à Artifex. Cela établit une contrainte de licence, pas une garantie de prise en charge de toutes les fonctions souhaitées.

L’utilisateur a ensuite choisi d’étudier un moteur libre sous AGPL. Une [étude MuPDF 1.28.6](MUPDF_AGPL_STUDY.md) et un [prototype C reproductible](../experiments/mupdf/README.md) ont été ajoutés : **11 tests natifs Linux réussissent**, y compris remplacement de texte/image, retrait de texte et export DOCX sur une fixture contrôlée. MuPDF a ensuite été adopté dans la version 0.1, avec licence AGPL-3.0-or-later, pont C relié au target et compilation des bibliothèques par plateforme. Les 16 tests du pont de production passent sous Linux ; la compilation et les tests du simulateur ont ensuite réussi dans la CI macOS ; la qualité sur un corpus réel et les essais matériels restent à vérifier. Voir [le guide macOS](BUILD_MACOS.md).

## Interface retenue

Bibliothèque en grille, navigation latérale, espace de lecture central, rail de vignettes, outils regroupés et export explicite. Paper Studio utilise son propre nom, ses propres textes, couleurs et composants système. Le dessin et le déplacement convertissent les coordonnées de la vue vers celles de la page PDF pour tenir compte du zoom et de la rotation.

## Matrice de portée

| Besoin d’un éditeur PDF avancé | Implémentation dans Paper Studio | Limite / validation restante |
| --- | --- | --- |
| Lire et rechercher | PDFKit, sélection, résultats, vignettes | Gros fichiers, rotations et scans à tester |
| Annoter | Surlignage, soulignement, barré, note, texte, dessin et formes | Geste tactile et persistance à valider |
| Modifier une annotation | Déplacement, contenu des notes/textes, suppression, taille des annotations non Ink | Pas de redimensionnement de dessin/signature |
| Signer | Signature vectorielle Ink | Pas de signature cryptographique certifiée |
| Remplir un formulaire | Éditeur champs texte/listes AcroForm, contrôles natifs pour cases/radio | XFA exclu ; PDF cibles à tester |
| Organiser | Rotation, déplacement, suppression, fusion et extraction | Interface page par page |
| Signets | Fichier local adjacent, suivi des pages déplacées/supprimées | Pas d’export en signets PDF |
| Protéger | Export avec mot de passe et enregistrement chiffré après déverrouillage | Test natif et lecteurs tiers requis |
| OCR | Vision français/anglais, extraction et export multipage recherchable via CoreText | Précision et alignement à valider ; pages aplaties |
| Numériser | Scanner VisionKit et images vers PDF | Scanner sur iPad physique uniquement |
| Exporter | PDF, page PNG, texte brut, impression | Pas de conversion Office |
| Aplatir / réduire | Reconstruction en images, 100/150/200 ppp, comparaison des tailles | Perte des interactions, réduction non garantie |
| Masquer des zones | Masques appliqués aux pixels avant reconstruction d’un nouveau PDF | Pas de certification ; tests PDF et revue nécessaires |
| Modifier texte/images existants | MuPDF : remplacement d’une ligne et d’une occurrence d’image | Police de repli, pas de reflow ; images inline refusées ; validation iPad restante |
| Convertir Word/Excel/PowerPoint | Export DOCX MuPDF, testé sur une fixture | Fidélité à valider ; Excel/PowerPoint non proposés |
| Synchroniser le cloud | Import/export via Fichiers | Pas de synchronisation propriétaire ni gestion de conflits |
| Assistant IA | Non implémenté | Aucun fournisseur/API choisi |

## Garanties de conception de l’export masqué

La sélection se fait en coordonnées normalisées sur la page affichée, avec sa rotation et sa crop box. Une nouvelle image opaque est créée ; les zones y sont peintes en noir avec une marge d’un pixel. Seule cette image modifiée est encodée et dessinée dans le nouveau PDF. Les objets d’origine, métadonnées, champs, liens et couche texte ne sont pas recopiés. L’historique et l’original restent dans l’app, hors du fichier exporté. L’export OCR est un chemin distinct et ne s’applique pas automatiquement à la copie masquée.

Cette conception doit encore être vérifiée sur le SDK Apple. Ne pas la présenter comme un caviardage certifié ou validé tant que les tests n’ont pas tourné.

## Validation sur Mac et iPad à effectuer

1. Compiler et exécuter les **24 tests XCTest** du scheme partagé. Examiner le `.xcresult`, les tests exécutés et les éventuels échecs.
2. Importer un PDF multipage, un scan, un AcroForm texte/liste/checkbox/radio, un PDF chiffré et des pages à crop box décalée et rotation 90/180/270°.
3. Tester dessin, formes, sélection, déplacement, annulation/rétablissement, enregistrement, fermeture et réouverture.
4. Vérifier la cohérence des signets après déplacement/suppression/annulation puis redémarrage de l’app.
5. Exporter les copies protégées et les rouvrir avec un bon et un mauvais mot de passe dans plusieurs lecteurs.
6. Scanner un document sur iPad physique et convertir plusieurs images de tailles/orientations différentes.
7. Tester OCR français/anglais sur scans : alignement des sélections, recherche, copie, annulation et absence d’export partiel après annulation.
8. Tester masques sur pages tournées/cadrées ; extraire les images du PDF final, examiner leurs pixels, chercher les chaînes masquées et vérifier l’absence de métadonnées, liens, pièces jointes et objets d’origine.
9. Vérifier Pencil, multitâche, fenêtres étroites, VoiceOver, grandes tailles de texte et pression mémoire sur gros documents.

Les contrôles Linux restent distincts des essais Apple. La compilation et les tests du scheme iPadOS ont réussi sur le simulateur du runner macOS ; les vérifications manuelles sur appareil et corpus réel ci-dessus restent à effectuer. L’analyse Tree-sitter locale ne résout pas les types Apple.
