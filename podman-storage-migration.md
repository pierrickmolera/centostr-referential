# Migration du stockage Podman (rootful & rootless)

Ce guide explique comment déplacer le stockage Podman (images, couches overlay, conteneurs, volumes) vers un nouveau chemin, que ce soit en mode rootful (root) ou rootless (utilisateur).

---

## 1. Comprendre la configuration actuelle

### 1.1 Localiser les chemins de stockage

#### Mode rootful

```bash
sudo podman info | grep -E "graphRoot|runRoot|graphDriver"
```

Fichier de configuration : `/etc/containers/storage.conf`

#### Mode rootless

```bash
podman info | grep -E "graphRoot|runRoot|graphDriver"
```

Fichier de configuration : `~/.config/containers/storage.conf`

### 1.2 Structure des fichiers de configuration

Les deux fichiers ont la même syntaxe TOML :

```toml
[storage]
driver = "overlay"
graphroot = "/chemin/vers/le/stockage"
runroot  = "/chemin/vers/le/run"
```

| Champ       | Rôle                                                              |
|-------------|-------------------------------------------------------------------|
| `driver`    | Pilote de stockage (overlay est le standard)                      |
| `graphroot` | Répertoire principal : images, couches overlay, métadonnées       |
| `runroot`   | Répertoire temporaire : sockets, locks (en RAM sur `/run`)        |

**Valeurs par défaut :**

| Mode      | `graphroot`                                    | `runroot`                     |
|-----------|------------------------------------------------|-------------------------------|
| Rootful   | `/var/lib/containers/storage`                  | `/run/containers/storage`     |
| Rootless  | `~/.local/share/containers/storage`            | `/run/user/<UID>/containers`  |

### 1.3 Contenu du répertoire de stockage

```
<graphroot>/
├── overlay/              # Couches des images (données réelles)
├── overlay-images/       # Métadonnées des images (manifests, config)
├── overlay-layers/       # Index des couches
├── overlay-containers/   # Métadonnées containers côté storage
├── libpod/               # État libpod (pods, réseaux)
├── db.sql                # Base SQLite : conteneurs, volumes, état
├── networks/             # Configuration des réseaux CNI/Netavark
├── volumes/              # Données des volumes nommés
├── secrets/              # Secrets podman
└── storage.lock          # Verrou
```

> **Important :** `db.sql` contient l'état de tous les conteneurs et volumes. C'est le fichier le plus critique lors d'une migration.

---

## 2. Modifier la configuration

### 2.1 Mode rootful

Éditer `/etc/containers/storage.conf` :

```toml
[storage]
driver    = "overlay"
graphroot = "/nouveau/chemin/storage"
runroot   = "/nouveau/chemin/run"
```

### 2.2 Mode rootless

Éditer `~/.config/containers/storage.conf` :

```toml
[storage]
driver    = "overlay"
graphroot = "/nouveau/chemin/storage-rootless"
runroot   = "/run/user/1000/containers"
```

> `runroot` est un répertoire temporaire en RAM, il n'y a généralement pas besoin de le changer.

---

## 3. Migrer les données

La migration se fait en trois étapes :
1. Copier les fichiers (overlay, images, volumes)
2. Corriger les chemins dans la base de données `db.sql`
3. Reconstruire les métadonnées avec `podman system migrate`

### 3.1 Créer le nouveau répertoire

#### Rootful

```bash
sudo mkdir -p /nouveau/chemin/storage
```

#### Rootless

```bash
mkdir -p /nouveau/chemin/storage-rootless
```

### 3.2 Copier les fichiers avec rsync

La copie doit préserver les permissions et les propriétaires (y compris les UIDs mappés par les user namespaces en mode rootless).

#### Rootful

```bash
sudo rsync -a --delete --info=progress2 \
  /ancien/chemin/storage/ \
  /nouveau/chemin/storage/
```

#### Rootless

En mode rootless, certaines couches overlay appartiennent à des UIDs issus des user namespaces (plage subuid). Il faut utiliser `sudo` pour les lire correctement :

```bash
sudo rsync -a --delete --info=progress2 \
  /ancien/chemin/storage-rootless/ \
  /nouveau/chemin/storage-rootless/
```

> **Note :** `podman unshare rsync` peut aussi fonctionner mais échoue si la config de stockage a déjà changé. `sudo rsync` est plus fiable dans ce cas.

L'option `--delete` supprime du répertoire destination les fichiers qui n'existent plus dans la source (utile si des images ont été supprimées entre deux passes).

### 3.3 Mettre à jour la base de données db.sql

Le fichier `db.sql` est une base SQLite qui contient les chemins absolus de l'ancien stockage dans plusieurs tables. Il faut les remplacer par les nouveaux chemins.

```bash
OLD="/ancien/chemin/storage"
NEW="/nouveau/chemin/storage"
DB="$NEW/db.sql"

# Mettre à jour la table de configuration principale
sqlite3 "$DB" "UPDATE DBConfig SET
  StaticDir = replace(StaticDir, '$OLD', '$NEW'),
  GraphRoot  = replace(GraphRoot,  '$OLD', '$NEW'),
  VolumeDir  = replace(VolumeDir,  '$OLD', '$NEW');"

# Mettre à jour les chemins embarqués dans les JSON des conteneurs
sqlite3 "$DB" "UPDATE ContainerConfig SET JSON = replace(JSON, '$OLD', '$NEW');"
sqlite3 "$DB" "UPDATE ContainerState  SET JSON = replace(JSON, '$OLD', '$NEW');"
sqlite3 "$DB" "UPDATE VolumeConfig    SET JSON = replace(JSON, '$OLD', '$NEW');"
```

**Description des tables :**

| Table             | Contenu                                                          |
|-------------------|------------------------------------------------------------------|
| `DBConfig`        | Chemins racines (graphRoot, staticDir, volumeDir)                |
| `ContainerConfig` | Configuration complète de chaque conteneur (image, ports, env…) |
| `ContainerState`  | État runtime de chaque conteneur (pid, chemins montage…)        |
| `VolumeConfig`    | Configuration des volumes nommés (point de montage…)            |

> Si `db.sql` n'existe pas encore dans le nouveau stockage (ex: il a été supprimé ou jamais copié), copiez-le d'abord depuis l'ancien emplacement avant de lancer les commandes ci-dessus :
> ```bash
> cp /ancien/chemin/storage/db.sql $NEW/db.sql
> ```

### 3.4 Supprimer le répertoire libpod copié

Le répertoire `libpod/` contient une copie de l'état libpod qui peut entrer en conflit avec `db.sql` après la mise à jour des chemins. Il doit être supprimé pour être recréé proprement par `podman system migrate` :

```bash
rm -rf /nouveau/chemin/storage/libpod
```

### 3.5 Reconstruire les métadonnées avec podman system migrate

```bash
# Rootful
sudo podman system migrate

# Rootless
podman system migrate
```

Cette commande reconstruit le répertoire `libpod/`, recrée `db.sql` si absent, et valide la cohérence entre la config et le stockage.

### 3.6 Vérifier la migration

```bash
# Vérifier les chemins
podman info | grep -E "graphRoot|runRoot"

# Lister les images
podman images

# Lister les conteneurs
podman ps -a
```

---

## 4. Cas particuliers

### 4.1 Image volumineuse à exclure

Si une image très volumineuse doit être supprimée avant migration, supprimez-la **avant** de lancer rsync :

```bash
podman rmi <image>:<tag>
```

Si l'image a déjà été partiellement copiée, relancez rsync avec `--delete` pour nettoyer la destination.

### 4.2 Conteneur bloqué en état "Stopping"

Si un conteneur reste bloqué et ne peut pas être supprimé avec `podman rm -f`, il faut le retirer directement de la base de données :

```bash
DB="/nouveau/chemin/storage/db.sql"
ID="<container-id-complet>"

sqlite3 "$DB" "
DELETE FROM ContainerState      WHERE ID='$ID';
DELETE FROM ContainerConfig     WHERE ID='$ID';
DELETE FROM ContainerDependency WHERE ID='$ID' OR DependencyID='$ID';
DELETE FROM ContainerExitCode   WHERE ID='$ID';
DELETE FROM IDNamespace         WHERE ID='$ID';
"
```

### 4.3 Inspecter la base de données pour retrouver les conteneurs

Si les conteneurs disparaissent après migration (ex: suite à une suppression accidentelle de `db.sql`), les informations peuvent être récupérées depuis l'ancien `db.sql` :

```bash
sqlite3 /ancien/chemin/storage/db.sql "SELECT Name, JSON FROM ContainerConfig;" \
| python3 -c "
import sys, json
for line in sys.stdin:
    parts = line.split('|', 1)
    if len(parts) == 2:
        name, j = parts
        try:
            cfg = json.loads(j)
            image = cfg.get('rootfsImageName', 'N/A')
            ports = cfg.get('newPortMappings', [])
            port_str = ', '.join(f\"{p.get('host_port')}->{p.get('container_port')}/{p.get('protocol','tcp')}\" for p in (ports or []))
            vols = cfg.get('namedVolumes', [])
            vol_str = ', '.join(f\"{v.get('volumeName')}:{v.get('dest')}\" for v in (vols or []))
            print(f'Name: {name}')
            print(f'  Image:   {image}')
            print(f'  Ports:   {port_str}')
            print(f'  Volumes: {vol_str}')
            print()
        except: pass
"
```

---

## 5. Résumé des commandes

```bash
# 1. Modifier la config
vim ~/.config/containers/storage.conf   # rootless
sudo vim /etc/containers/storage.conf   # rootful

# 2. Créer le répertoire destination
mkdir -p /nouveau/chemin

# 3. Copier les données
sudo rsync -a --delete --info=progress2 /ancien/ /nouveau/

# 4. Mettre à jour db.sql
OLD="/ancien" NEW="/nouveau" DB="$NEW/db.sql"
sqlite3 "$DB" "UPDATE DBConfig SET StaticDir=replace(StaticDir,'$OLD','$NEW'), GraphRoot=replace(GraphRoot,'$OLD','$NEW'), VolumeDir=replace(VolumeDir,'$OLD','$NEW');"
sqlite3 "$DB" "UPDATE ContainerConfig SET JSON=replace(JSON,'$OLD','$NEW');"
sqlite3 "$DB" "UPDATE ContainerState  SET JSON=replace(JSON,'$OLD','$NEW');"
sqlite3 "$DB" "UPDATE VolumeConfig    SET JSON=replace(JSON,'$OLD','$NEW');"

# 5. Supprimer l'ancien répertoire libpod
rm -rf /nouveau/libpod

# 6. Migrer
podman system migrate   # ou sudo podman system migrate

# 7. Vérifier
podman info | grep graphRoot
podman images
podman ps -a
```
