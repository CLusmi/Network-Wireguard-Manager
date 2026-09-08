#!/bin/bash
# (Développement uniquement) Assemble les modules src/*.sh en un script unique
# à la racine du dépôt. Les utilisateurs n'ont PAS besoin de builder :
# network-wireguard-manager.sh est déjà prêt à l'emploi dans le dépôt.
set -euo pipefail
cd "$(dirname "$0")"

OUT="network-wireguard-manager.sh"

# Build déterministe : les mêmes sources produisent un fichier identique à
# l'octet près (pas de date dans l'en-tête, sinon chaque build ferait
# apparaître le dépôt git comme modifié alors que rien n'a changé).
{
    echo "#!/bin/bash"
    echo "# Network-WireGuard-Manager — script assemblé par build.sh, ne pas éditer (sources : src/)."
    echo "# Dépôt : https://github.com/CLusmi/Network-Wireguard-Manager"
    for f in src/*.sh; do
        echo ""
        echo "#=== ${f} ==="
        # Retire le shebang de chaque module (un seul en tête du fichier final)
        sed '1{/^#!/d}' "$f"
    done
} > "$OUT"

chmod +x "$OUT"
bash -n "$OUT"
echo "OK: $OUT ($(wc -l < "$OUT") lignes)"
