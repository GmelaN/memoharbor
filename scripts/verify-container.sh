#!/usr/bin/env bash
# A dedicated CI runner with Docker and the existing test MariaDB service.
set -euo pipefail
: "${1:?Usage: verify-container.sh IMAGE}"
: "${MARIADB_TEST_URL:?Test MariaDB URL required}"
: "${MARIADB_TEST_USER:?Test MariaDB user required}"
: "${MARIADB_TEST_PASSWORD:?Test MariaDB password required}"
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
config_file="$(mktemp)"
container_name="memoharbor-ci-${RANDOM}"
cleanup() {
  docker rm -f "$container_name" >/dev/null 2>&1 || true
  rm -f "$config_file"
}
trap cleanup EXIT
# Test-only credentials. Production configuration lives exclusively in OKD.
printf 'DB_URL=%s\nDB_USER=%s\nDB_PASSWORD=%s\n' "$MARIADB_TEST_URL" "$MARIADB_TEST_USER" "$MARIADB_TEST_PASSWORD" > "$config_file"
chmod 444 "$config_file"
docker run --detach --name "$container_name" --network host \
  --user 1001230000:0 --cap-drop ALL --security-opt no-new-privileges \
  --mount "type=bind,source=$config_file,target=/etc/memoharbor/.env,readonly" \
  --env 'JAVA_OPTS=-Xms128m -Xmx512m -Dmemoharbor.env=/etc/memoharbor/.env' "$1"
wait_ready() {
  for attempt in {1..90}; do
    if curl --fail --silent http://127.0.0.1:8080/memoharbor/health >/dev/null; then return; fi
    sleep 2
  done
  docker logs "$container_name"
  return 1
}
wait_ready
test_user="container_$(date +%s)"
python3 "$project_dir/scripts/wildfly-smoke.py" --username "$test_user" --backend MariaDB
docker restart "$container_name"
wait_ready
python3 "$project_dir/scripts/wildfly-smoke.py" --username "$test_user" --backend MariaDB --existing
