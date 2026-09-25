#!/bin/bash
# Runs db-init.yaml's SQL against a throwaway postgres:16 container:
# legacy state (fork's original DROP/CREATE seed) -> db-init twice ->
# app-style insert -> db-init again. Asserts seed counts, that app rows
# survive, and that identity sequences are never reset.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
MANIFEST="$HERE/../k8s/db-init.yaml"
FORK=${FORK_DIR:-/home/ubuntu/jerome/spring-petclinic-microservices}
NAME=db-init-test-$$
WORK=$(mktemp -d)
trap 'docker rm -f $NAME >/dev/null 2>&1; rm -rf "$WORK"' EXIT

python3 - "$MANIFEST" "$WORK" <<'EOF'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
cm = next(d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "db-init-sql")
for key, sql in cm["data"].items():
    open(f"{sys.argv[2]}/{key}", "w").write(sql)
EOF

docker run -d --name $NAME -e POSTGRES_PASSWORD=t -e POSTGRES_USER=petclinic postgres:16 >/dev/null
until docker exec $NAME pg_isready -U petclinic >/dev/null 2>&1; do sleep 1; done
sleep 2
q() { docker exec -i $NAME psql -v ON_ERROR_STOP=1 -qtA -U petclinic -d "$1"; }
for db in customers vets visits; do echo "CREATE DATABASE $db;" | q postgres; done

for svc in customers vets visits; do
  cat "$FORK/spring-petclinic-$svc-service/src/main/resources/db/postgresql/schema.sql" \
      "$FORK/spring-petclinic-$svc-service/src/main/resources/db/postgresql/data.sql" | q $svc >/dev/null
done

run_init() { for db in customers vets visits; do q $db < "$WORK/$db.sql" >/dev/null; done; }
run_init; run_init

expect() { local got; got=$(echo "$2" | q $1); [ "$got" = "$3" ] || { echo "FAIL $1: $2 -> $got (want $3)"; exit 1; }; }
expect customers "SELECT count(*) FROM types" 6
expect customers "SELECT count(*) FROM owners" 10
expect customers "SELECT count(*) FROM pets" 13
expect vets "SELECT count(*) FROM vets" 6
expect vets "SELECT count(*) FROM specialties" 3
expect vets "SELECT count(*) FROM vet_specialties" 5
expect visits "SELECT count(*) FROM visits" 4

expect customers "INSERT INTO owners (first_name,last_name,address,city,telephone) VALUES ('T','T','a','c','1') RETURNING id" 11
run_init
expect customers "SELECT count(*) FROM owners" 11
expect customers "INSERT INTO owners (first_name,last_name,address,city,telephone) VALUES ('U','U','a','c','2') RETURNING id" 12
expect visits "INSERT INTO visits (pet_id,visit_date,description) VALUES (1,'2026-01-01','x') RETURNING id" 5
run_init
expect visits "SELECT count(*) FROM visits" 5
echo "PASS"
