#!/usr/bin/env bash
# sqlserver: sql server table helpers: column inspector with pk/fk constraints, data types, and nullability
set -euo pipefail

NVIM_DIR="$HOME/.config/nvim"
mkdir -p "$NVIM_DIR/lua/util/dadbod-tables"

echo "Writing SQL Server table helpers..."

cat > "$NVIM_DIR/lua/util/dadbod-tables/sqlserver.lua" << 'EOF'
-- SQL Server table helpers for dadbod-ui
-- Detailed column inspector showing PK/FK constraints, data types, and nullability
return {
  Columns = "select c.column_name + ' (' + "
    .. "isnull(( select TOP 1 'PK, ' from information_schema.table_constraints as k "
    .. "join information_schema.key_column_usage as kcu on k.constraint_name = kcu.constraint_name "
    .. "where constraint_type='PRIMARY KEY' and k.table_name = c.table_name and kcu.column_name = c.column_name), '') + "
    .. "isnull(( select TOP 1 'FK, ' from information_schema.table_constraints as k "
    .. "join information_schema.key_column_usage as kcu on k.constraint_name = kcu.constraint_name "
    .. "where constraint_type='FOREIGN KEY' and k.table_name = c.table_name and kcu.column_name = c.column_name), '') + "
    .. "data_type + coalesce('(' + rtrim(cast(character_maximum_length as varchar)) + ')',"
    .. "'(' + rtrim(cast(numeric_precision as varchar)) + ',' + rtrim(cast(numeric_scale as varchar)) + ')',"
    .. "'(' + rtrim(cast(datetime_precision as varchar)) + ')','') + ', ' + "
    .. "case when is_nullable = 'YES' then 'null' else 'not null' end + ')' as Columns "
    .. "from information_schema.columns c where c.table_name='{table}' and c.TABLE_SCHEMA = '{schema}'",
}
EOF

echo "  util/dadbod-tables/sqlserver.lua: OK"
