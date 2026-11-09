#!/usr/bin/env bash
# Run against a dedicated local Tomcat installation; uses HTTP port ${TOMCAT_PORT:-8081}.
# Tomcat 10.1/11: target/memoharbor.war (default). Tomcat 9: WAR=target/tomcat9/memoharbor.war.
set -euo pipefail
: "${CATALINA_HOME:?Set CATALINA_HOME to a dedicated Tomcat installation}"
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
war="${WAR:-$project_dir/target/memoharbor.war}"
port="${TOMCAT_PORT:-8081}"
base_url="http://127.0.0.1:$port/memoharbor"
test_user="tc_$(date +%s)"
data_dir="$(mktemp -d)"
log="$project_dir/target/tomcat-console.log"

# Isolated ports so this never collides with another local WAS.
sed -i -e "s/port=\"8080\"/port=\"$port\"/" -e 's/port="8005"/port="-1"/' "$CATALINA_HOME/conf/server.xml"
rm -rf "$CATALINA_HOME/webapps/memoharbor" "$CATALINA_HOME/webapps/memoharbor.war"

export CATALINA_PID="$CATALINA_HOME/temp/memoharbor-verify.pid"
export CATALINA_OPTS="${CATALINA_OPTS:-} -Dmemoharbor.dataDir=$data_dir"
"$CATALINA_HOME/bin/catalina.sh" start > "$log" 2>&1
trap '"$CATALINA_HOME/bin/catalina.sh" stop 10 -force >/dev/null 2>&1 || true' EXIT

wait_for() { # wait_for <expected HTTP status>
  for attempt in {1..60}; do
    code="$(curl -s -o /dev/null -w '%{http_code}' "$base_url/live" || true)"
    if [[ "$code" == "$1" ]]; then return 0; fi
    sleep 2
  done
  echo "Timed out waiting for $base_url/live to return $1 (last: $code)"
  cat "$log" "$CATALINA_HOME"/logs/catalina.*.log 2>/dev/null || true
  exit 1
}

cp "$war" "$CATALINA_HOME/webapps/memoharbor.war"
wait_for 200
python3 "$project_dir/scripts/wildfly-smoke.py" --base-url "$base_url" --username "$test_user" --backend SQLite
rm -f "$CATALINA_HOME/webapps/memoharbor.war"
wait_for 404
cp "$war" "$CATALINA_HOME/webapps/memoharbor.war"
wait_for 200
python3 "$project_dir/scripts/wildfly-smoke.py" --base-url "$base_url" --username "$test_user" --existing
test -f "$data_dir/memoharbor.sqlite"
echo "Tomcat verification passed: $("$CATALINA_HOME/bin/version.sh" | grep 'Server number')"
