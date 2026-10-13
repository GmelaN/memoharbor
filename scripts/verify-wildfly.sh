#!/usr/bin/env bash
# Run against a dedicated local WildFly installation; uses its default ports.
set -euo pipefail
: "${JBOSS_HOME:?Set JBOSS_HOME to a dedicated WildFly 27+ installation}"
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
war="$project_dir/target/memoharbor.war"
test_user="wf_$(date +%s)"
"$JBOSS_HOME/bin/standalone.sh" -b 127.0.0.1 > "$project_dir/target/wildfly-console.log" 2>&1 &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true' EXIT
ready=false
for attempt in {1..90}; do
  if "$JBOSS_HOME/bin/jboss-cli.sh" --connect --command=':read-attribute(name=server-state)' 2>/dev/null | grep -q '"result" => "running"'; then ready=true; break; fi
  sleep 2
done
if [[ "$ready" != true ]]; then cat "$project_dir/target/wildfly-console.log"; exit 1; fi
"$JBOSS_HOME/bin/jboss-cli.sh" --connect --command="deploy \"$war\" --force"
python3 "$project_dir/scripts/wildfly-smoke.py" --username "$test_user"
"$JBOSS_HOME/bin/jboss-cli.sh" --connect --command='undeploy memoharbor.war'
"$JBOSS_HOME/bin/jboss-cli.sh" --connect --command="deploy \"$war\""
python3 "$project_dir/scripts/wildfly-smoke.py" --username "$test_user" --existing
