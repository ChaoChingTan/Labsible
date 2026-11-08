#!/bin/bash
# Runs ON A WEB NODE as root (sent there by scripts/db-run.sh through SSM).
# The web nodes are the only machines allowed to reach the database.
#
#   db-node.sh init              empty database -> Guacamole schema + guacadmin password
#   db-node.sh restore [KEY]     empty database -> restore dump (default: newest) + guacadmin password
#   db-node.sh dump              write a dump to s3://$DUMP_BUCKET/dumps/
#
# Environment: DUMP_BUCKET, GUAC_ADMIN_SECRET_ARN, AWS_REGION (set by db-run.sh).
# Database settings are read from /etc/guacamole.env (written at boot, mode 600).
set -euo pipefail

MODE="${1:?usage: db-node.sh init|restore [key]|dump}"
: "${AWS_REGION:?}"
PG_IMAGE="postgres:16-alpine"
GUAC_IMAGE=$(docker inspect guacamole --format '{{.Config.Image}}')

set -a; . /etc/guacamole.env; set +a
export PGPASSWORD="$POSTGRESQL_PASSWORD" PGSSLMODE=require

psql_() {  # psql_ [args]   reads stdin
  docker run --rm -i --network host -e PGPASSWORD -e PGSSLMODE "$PG_IMAGE" \
    psql -v ON_ERROR_STOP=1 -q -h "$POSTGRESQL_HOSTNAME" -p "$POSTGRESQL_PORT" \
    -U "$POSTGRESQL_USER" -d "$POSTGRESQL_DATABASE" "$@"
}

table_count() {
  psql_ -At -c "select count(*) from information_schema.tables where table_schema='public'" </dev/null
}

set_admin_password() {
  : "${GUAC_ADMIN_SECRET_ARN:?}"
  local secret pass salt hash
  secret=$(aws secretsmanager get-secret-value --region "$AWS_REGION" \
    --secret-id "$GUAC_ADMIN_SECRET_ARN" --query SecretString --output text)
  pass=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["password"])' "$secret")
  salt=$(openssl rand -hex 32 | tr a-f A-F)                       # uppercase hex string
  hash=$(printf '%s%s' "$pass" "$salt" | sha256sum | cut -d' ' -f1)  # SHA-256(password + salt)
  psql_ -v salt="$salt" -v hash="$hash" <<'SQL'
UPDATE guacamole_user
   SET password_salt = decode(:'salt','hex'),
       password_hash = decode(:'hash','hex'),
       password_date = now()
 WHERE entity_id = (SELECT entity_id FROM guacamole_entity
                     WHERE name = 'guacadmin' AND type = 'USER');
SQL
  echo "guacadmin password set from Secrets Manager"
}

case "$MODE" in
  init|restore)
    n=$(table_count)
    [ "$n" = "0" ] || { echo "database is not empty ($n tables); refusing to $MODE" >&2; exit 1; }
    if [ "$MODE" = init ]; then
      docker run --rm "$GUAC_IMAGE" /opt/guacamole/bin/initdb.sh --postgresql | psql_
      echo "schema loaded"
    else
      KEY="${2:-}"
      if [ -z "$KEY" ]; then
        KEY=$(aws s3 ls "s3://$DUMP_BUCKET/dumps/" --region "$AWS_REGION" | awk '{print $4}' | grep '\.sql\.gz$' | sort | tail -1)
      fi
      [ -n "$KEY" ] || { echo "no dump found in s3://$DUMP_BUCKET/dumps/" >&2; exit 1; }
      echo "restoring $KEY"
      aws s3 cp "s3://$DUMP_BUCKET/dumps/${KEY#dumps/}" - --region "$AWS_REGION" | gunzip | psql_
      echo "restore complete"
    fi
    set_admin_password
    ;;
  dump)
    KEY="guacamole-$(date -u +%Y%m%dT%H%M%SZ).sql.gz"
    docker run --rm --network host -e PGPASSWORD -e PGSSLMODE "$PG_IMAGE" \
      pg_dump --no-owner --no-acl -h "$POSTGRESQL_HOSTNAME" -p "$POSTGRESQL_PORT" \
      -U "$POSTGRESQL_USER" -d "$POSTGRESQL_DATABASE" \
      | gzip | aws s3 cp - "s3://$DUMP_BUCKET/dumps/$KEY" --region "$AWS_REGION"
    echo "dump written: dumps/$KEY"
    ;;
  *) echo "unknown mode: $MODE" >&2; exit 2 ;;
esac