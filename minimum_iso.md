# Création d'un ISO d'installation auto-suffisant

ISO bootable (BIOS + UEFI) contenant uniquement les packages nécessaires, permettant
une installation de CentOS Stream 9 **complètement offline**, sans réseau pendant
l'installation.

## Objectif

Installer un serveur CentOS Stream 9 minimal avec :

- `@^minimal-environment` — base serveur minimale
- `kernel-rt` — kernel temps-réel (remplace le kernel standard)
- `@container-management` — podman, buildah, skopeo
- `htop` — monitoring

## Vue d'ensemble

```
Étape 1 : synchronisation des repos (build.sh)
    rsync depuis un miroir public
    → image podman contenant les repos BaseOS, AppStream, RT, EPEL

Étape 2 : création de l'ISO (create-iso.sh)
    Miroir local (nginx) + lorax + dnf download + xorriso + mkksiso
    → ISO auto-suffisant avec packages embarqués
```

## Structure des fichiers

```
.
├── build.sh                  # Synchronisation des repos → image podman miroir
├── sync.sh                   # Script rsync (appelé par build.sh)
├── Containerfile.base        # Image de base avec nginx (Fedora)
├── Containerfile.iso         # Image de build ISO (CentOS Stream 9 + lorax + outils)
├── rsync-excludes.txt        # Filtres rsync (repos et arches exclus)
├── nginx.conf                # Configuration du serveur HTTP local
├── kickstart.cfg             # Kickstart de référence (installation via réseau local)
├── create-iso.sh             # Orchestration de la création de l'ISO
└── create-iso-inner.sh       # Script qui s'exécute à l'intérieur du conteneur
```

## Repos synchronisés

Définis dans `rsync-excludes.txt` :

| Repo       | Contenu                              | Statut    |
|------------|--------------------------------------|-----------|
| BaseOS     | Packages système de base             | Activé    |
| AppStream  | Podman, buildah, skopeo, anaconda    | Activé    |
| RT         | Kernel temps-réel (kernel-rt)        | Activé    |
| EPEL       | Packages communautaires (htop, ...)  | Activé    |
| CRB        | Sources et développement             | Exclu     |
| NFV        | Network Function Virtualization      | Exclu     |
| HighAvail  | Haute disponibilité                  | Exclu     |

Architectures conservées : `x86_64`, `noarch`. Les sources et debug sont exclus.

## Étape 1 — Synchronisation du miroir local

### Lancer la synchronisation

```bash
./build.sh
```

Le script effectue deux étapes :

1. **Construction de l'image de base** (`Containerfile.base`) si elle n'existe pas —
   image Fedora avec nginx configuré pour servir les repos.

2. **Synchronisation des repos** via rsync dans un conteneur buildah, puis commit
   de l'image podman finale taguée `latest` et `YYYY-MM-DD`.

Le miroir est ensuite accessible en lançant le conteneur :

```bash
podman run --rm -p 8080:8080 localhost/mirrors/centos-stream-9:latest
```

Les repos sont servis à l'adresse `http://localhost:8080/` :

```
http://localhost:8080/centos/9-stream/BaseOS/x86_64/os/
http://localhost:8080/centos/9-stream/AppStream/x86_64/os/
http://localhost:8080/centos/9-stream/RT/x86_64/os/
http://localhost:8080/epel/9/Everything/x86_64/
```

## Étape 2 — Création de l'ISO auto-suffisant

### Lancer la création de l'ISO

```bash
./create-iso.sh
```

L'ISO est produit dans le répertoire `output/` :

```
output/install-centos-stream-9-YYYY-MM-DD.iso
```

Variables d'environnement disponibles :

| Variable        | Défaut                                    | Description              |
|-----------------|-------------------------------------------|--------------------------|
| `CENTOS_VERSION`| `9`                                       | Version de CentOS Stream |
| `ARCH`          | `x86_64`                                  | Architecture cible       |
| `ISO_OUTPUT`    | `./output`                                | Répertoire de sortie     |
| `IMAGE_BASE`    | `localhost/mirrors/centos-stream-9`       | Image miroir podman      |

```bash
# Exemple avec répertoire de sortie personnalisé
ISO_OUTPUT=/srv/isos ./create-iso.sh

# Ou combiné avec build.sh en une seule commande
CREATE_ISO=1 ./build.sh
```

### Ce que fait create-iso.sh

Le script crée un **pod podman** contenant deux conteneurs partageant le même
réseau (`localhost`) :

- `{pod}-mirror` — le conteneur miroir qui sert les repos via nginx sur le port 8080
- conteneur éphémère — l'image ISO builder (`Containerfile.iso`) qui exécute
  `create-iso-inner.sh`

```
┌─────────────────────────────────────────────┐
│  Pod podman (réseau partagé)                │
│                                             │
│  ┌───────────────┐   localhost:8080         │
│  │  miroir nginx │ ◄──────────────────┐    │
│  └───────────────┘                    │    │
│                                       │    │
│  ┌──────────────────────────────────┐ │    │
│  │  ISO builder (create-iso-inner)  │─┘    │
│  │  dnf download / lorax / xorriso  │      │
│  └──────────────────────────────────┘      │
└─────────────────────────────────────────────┘
              │
              ▼
         output/install-centos-stream-9-YYYY-MM-DD.iso
```

### Ce que fait create-iso-inner.sh

#### Étape 1 — Téléchargement des packages cibles

`dnf download --resolve` télécharge uniquement les packages spécifiés et
**toutes leurs dépendances** depuis le miroir local.

Le kernel standard est exclu (`--setopt=excludepkgs=kernel,kernel-core,...`)
pour ne garder que `kernel-rt`.

Packages téléchargés :

```
@^minimal-environment   →  base système minimale (glibc, systemd, bash, ssh, ...)
kernel-rt               →  kernel temps-réel
kernel-rt-core          →  modules kernel-rt
kernel-rt-devel         →  headers kernel-rt
podman                  →  moteur de conteneurs
buildah                 →  construction d'images OCI
skopeo                  →  gestion des images de registre
epel-release            →  activation du repo EPEL sur le système installé
htop                    →  monitoring interactif des processus
```

Les RPMs atterrissent dans `{lorax-tree}/Packages/` ; `createrepo_c` génère
les métadonnées de repo.

#### Étape 2 — Construction de l'installeur Anaconda (lorax)

`lorax` construit l'environnement d'installation à partir des repos BaseOS et
AppStream du miroir local. Il produit :

```
lorax-tree/
├── images/
│   ├── install.img   ← Anaconda compressé (squashfs)
│   ├── efiboot.img   ← image EFI pour boot UEFI
│   └── boot.iso      ← petit ISO boot-only (non utilisé directement)
├── isolinux/         ← boot BIOS (syslinux)
│   ├── isolinux.bin
│   ├── isolinux.cfg
│   ├── vmlinuz
│   └── initrd.img
├── EFI/              ← boot UEFI (grub2)
│   └── BOOT/
│       ├── BOOTX64.EFI
│       └── grub.cfg
└── .treeinfo         ← métadonnées de l'arbre d'installation
```

> **Durée** : 30 à 60 minutes selon les performances du système. C'est normal —
> lorax installe anaconda et ses dépendances dans un chroot.

#### Étape 3 — Mise à jour de .treeinfo

Anaconda lit `.treeinfo` au démarrage pour localiser les packages sur le média
d'installation. La section `[variant-BaseOS]` est ajoutée pour pointer vers
le répertoire `Packages/` :

```ini
[variant-BaseOS]
id = BaseOS
name = BaseOS
packages = Packages
repository = .
type = variant
uid = BaseOS
```

#### Étape 4 — Génération du kickstart offline

Le `kickstart.cfg` de référence est adapté pour une installation depuis le
cdrom (pas de réseau requis) :

| Directive d'origine                    | Remplacée par |
|----------------------------------------|---------------|
| `url --url=http://192.168.122.1:8080/` | `cdrom`       |
| `repo --name=baseos --baseurl=...`     | *(supprimée)* |
| `repo --name=appstream --baseurl=...`  | *(supprimée)* |
| `repo --name=rt --baseurl=...`         | *(supprimée)* |
| `repo --name=epel --baseurl=...`       | *(supprimée)* |

La section `%post` est conservée intégralement : elle configure les repos du
système installé pour pointer vers le miroir local (`http://192.168.122.1:8080`)
afin de permettre les mises à jour ultérieures.

#### Étape 5 — Création de l'ISO hybride (xorriso)

`xorriso` assemble l'arbre complet en un ISO bootable depuis un disque physique,
une clé USB ou une VM :

```
xorriso -as mkisofs
  -b isolinux/isolinux.bin    ← entrée de boot BIOS
  --efi-boot images/efiboot.img ← entrée de boot UEFI
  -V "CS9-Install"
  ...
```

L'ISO résultant supporte le boot **BIOS (Legacy)** et **UEFI**.

#### Étape 6 — Injection du kickstart (mkksiso)

`mkksiso` embarque le kickstart offline dans l'ISO et ajoute automatiquement
`inst.ks=cdrom:/ks.cfg` aux paramètres kernel dans `isolinux.cfg` et `grub.cfg`.
L'installation est ainsi **entièrement automatisée sans interaction**.

### Structure de l'ISO final

```
ISO (~3-5 Go)
├── .treeinfo             ← Anaconda localise les packages via [variant-BaseOS]
├── ks.cfg                ← kickstart embarqué (inst.ks=cdrom:/ks.cfg)
├── isolinux/             ← boot BIOS
│   ├── isolinux.bin
│   ├── isolinux.cfg      ← contient inst.ks=cdrom:/ks.cfg
│   ├── vmlinuz
│   └── initrd.img
├── EFI/                  ← boot UEFI
│   └── BOOT/
│       ├── BOOTX64.EFI
│       └── grub.cfg      ← contient inst.ks=cdrom:/ks.cfg
├── images/
│   ├── install.img       ← Anaconda
│   └── efiboot.img
└── Packages/             ← RPMs sélectionnés + dépendances + repodata/
    ├── bash-*.rpm
    ├── kernel-rt-*.rpm
    ├── podman-*.rpm
    ├── htop-*.rpm
    ├── ...
    └── repodata/
```

## Déroulement de l'installation

1. La machine démarre sur l'ISO (VM ou physique)
2. Le bootloader charge `vmlinuz` + `initrd.img` avec le paramètre `inst.ks=cdrom:/ks.cfg`
3. Anaconda démarre, lit le kickstart depuis le cdrom
4. Anaconda détecte `cdrom` dans le kickstart → lit `.treeinfo` → trouve `Packages/`
5. Les packages sont installés depuis le cdrom, **aucun réseau requis**
6. Le script `%post` configure les repos pour pointer vers `http://192.168.122.1:8080`
   (pour les mises à jour futures, quand le miroir est disponible)
7. La machine s'éteint (`poweroff` dans le kickstart)

## Personnalisation des packages

Pour modifier la liste des packages embarqués, éditer la section `dnf download`
dans `create-iso-inner.sh` :

```bash
dnf download \
  --resolve \
  ...
  @^minimal-environment \      # ← environnement de base
  kernel-rt kernel-rt-core \   # ← kernel temps-réel
  podman buildah skopeo \      # ← conteneurs
  epel-release htop            # ← outils
```

Les dépendances sont résolues automatiquement par `--resolve`.

Pour exclure des packages supplémentaires (par exemple remplacer `firewalld`
par `nftables`) :

```bash
  --setopt=excludepkgs="kernel,kernel-core,...,firewalld" \
```

## Prérequis

| Outil     | Rôle                                          |
|-----------|-----------------------------------------------|
| `podman`  | Gestion des conteneurs et pods                |
| `buildah` | Construction de l'image miroir                |
| `rsync`   | Synchronisation des repos depuis un miroir public |

L'image ISO builder (`Containerfile.iso`) est construite automatiquement lors
du premier lancement de `create-iso.sh`. Elle contient :

- `lorax` — construction de l'environnement Anaconda
- `pykickstart` — injection du kickstart (`mkksiso`)
- `createrepo_c` — génération des métadonnées de repo
- `dnf-plugins-core` — `dnf download`
- `xorriso` — création de l'ISO
