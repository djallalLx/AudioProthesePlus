#!/usr/bin/env bash
set -euo pipefail

# ----------------------------------------
# setup_soc.sh
# Automatisation du SOC single-node Docker
# ----------------------------------------

# Chargement des variables d'environnement
if [[ ! -f .env ]]; then
  echo "❗ Fichier .env introuvable. Crée-le d'abord selon les instructions." >&2
  exit 1
fi
export $(grep -v '^#' .env | xargs)

# Fonction utilitaire : attendre qu'un endpoint HTTP réponde
wait_for_http() {
  local name=$1 url=$2
  echo -n "⏳ Attente de ${name}… "
  until curl -sSf "$url" > /dev/null; do
    printf "."
    sleep 3
  done
  echo " OK"
}

# Démarrage des services
echo "🚀 Lancement des conteneurs Docker"
docker-compose down --remove-orphans
docker-compose up -d

# 1. Attendre Wazuh Indexer (OpenSearch) et Dashboard (Kibana)
wait_for_http "OpenSearch" "http://localhost:9201"
wait_for_http "Kibana"     "http://localhost:8443"

# 2. Configurer Wazuh → OpenSearch
echo "🔧 Chargement du template Wazuh dans OpenSearch"
docker cp wazuh-template.json single-node_wazuh.indexer_1:/tmp/wazuh-template.json
docker exec -i single-node_wazuh.indexer_1 \
  curl -u "${OPENSEARCH_USER}:${OPENSEARCH_PASSWORD}" -XPUT \
    "http://localhost:9200/_template/wazuh" \
    -H 'Content-Type: application/json' \
    -d @/tmp/wazuh-template.json

echo "🔧 Import des dashboards Wazuh dans Kibana"
docker exec -i single-node_wazuh.dashboard_1 \
  /usr/share/kibana/scripts/import_dashboards.sh

# 3. Initialiser Cassandra pour Cortex
echo "🔧 Création du keyspace 'cortex' dans Cassandra"
cat <<EOF | docker exec -i single-node_cassandra_1 cqlsh
CREATE KEYSPACE IF NOT EXISTS cortex
  WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 1};
USE cortex;
SOURCE '/opt/cortex/schema.cql';
EOF

# 4. Créer le bucket MinIO pour MISP
echo "🔧 Création du bucket 'misp-exports' sur MinIO"
docker exec -i single-node_minio_1 \
  mc alias set local http://localhost:9000 \
    "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}"
docker exec -i single-node_minio_1 \
  mc mb local/misp-exports || echo "Bucket existant, skip"

# 5. Vérifications finales
echo "✅ Vérifications finales :"
echo -n "  • Redis… "
docker exec -i single-node_redis_1 \
  redis-cli -a "${REDIS_PASSWORD}" ping
echo -n "  • Cassandra (état)… "
docker exec -i single-node_cassandra_1 nodetool status | grep -E 'UN'
echo -n "  • Wazuh → OpenSearch… "
docker exec -i single-node_wazuh.manager_1 \
  curl -su "${OPENSEARCH_USER}:${OPENSEARCH_PASSWORD}" \
    http://wazuh.indexer:9200

echo -e "\n🎉 Ton SOC est configuré et prêt à l’emploi !  
— UIs accessibles :  
  • Wazuh Dashboard : https://<IP>:8443  
  • OpenSearch : http://<IP>:9201  
  • TheHive : http://<IP>:9000  
  • Cortex : http://<IP>:9001  
  • MISP : http://<IP>/  
  • OpenVAS : http://<IP>:8080  

Tu peux maintenant lancer tes démonstrations vidéo en toute tranquillité ! 🔒"
