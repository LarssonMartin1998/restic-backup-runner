#!/usr/bin/env bash

CONFIG_PATH="${RESTIC_BACKUP_CONFIG:-/etc/restic-backup-runner/config.json}"
if [[ ! -r "$CONFIG_PATH" ]]; then
    echo "Error: config file not found or not readable at $CONFIG_PATH" >&2
    exit 1
fi

config_jq_required() {
    local filter=$1
    local value
    if ! value=$(jq -e -r "$filter" "$CONFIG_PATH"); then
        echo "Error: failed to read required config value with filter '$filter' from $CONFIG_PATH" >&2
        exit 1
    fi
    echo "$value"
}

config_jq_optional() {
    local filter=$1
    local value
    if ! value=$(jq -r "$filter" "$CONFIG_PATH" 2>/dev/null); then
        value=""
    fi
    if [[ "$value" == "null" ]]; then
        value=""
    fi
    echo "$value"
}

RESTIC_PASSWORD_FILE="$(config_jq_required '.resticPasswordFile')"
BACKUP_REPO="$(config_jq_required '.backupRepo')"
DB_STAGING_DUMP="$(config_jq_required '.dbStagingDump')"
NUM_BACKUPS_TO_KEEP="$(config_jq_required '.numBackupsToKeep // 3')"
PING_ENDPOINT="$(config_jq_optional '.pingEndpoint')"
PING_SERVICE_NAME="$(config_jq_optional '.pingServiceName')"

# shellcheck disable=SC2034
mapfile -t SQLITE_TO_BACKUP < <(jq -c '.sqliteDatabases[]?' "$CONFIG_PATH")
# shellcheck disable=SC2034
mapfile -t POSTGRES_TO_BACKUP < <(jq -c '.postgresDatabases[]?' "$CONFIG_PATH")
mapfile -t FILES_TO_BACKUP < <(jq -r '.files[]?' "$CONFIG_PATH")

declare -A POSTGRES_PASSWORDS
if [[ -n "${POSTGRES_PASSWORDS_FILE:-}" ]]; then
    if [[ ! -r "$POSTGRES_PASSWORDS_FILE" ]]; then
        echo "Warning: POSTGRES_PASSWORDS_FILE is set but not readable at $POSTGRES_PASSWORDS_FILE" >&2
    else
        while IFS=$'\t' read -r name password; do
            POSTGRES_PASSWORDS["$name"]="$password"
        done < <(jq -r 'to_entries[] | [.key, .value] | @tsv' "$POSTGRES_PASSWORDS_FILE")
    fi
fi

fail() {
    echo "$1" >&2
    exit 1
}

validate_restic_repository() {
    if [[ ! -r "$RESTIC_PASSWORD_FILE" ]]; then
        echo "Error: restic password file not found or not readable at $RESTIC_PASSWORD_FILE" >&2
        return 1
    fi
    
    if ! restic -r "$BACKUP_REPO" --password-file "$RESTIC_PASSWORD_FILE" check >/dev/null 2>&1; then
        echo "Error: restic repository check failed for $BACKUP_REPO" >&2
        return 1
    fi
    
    if ! restic -r "$BACKUP_REPO" --password-file "$RESTIC_PASSWORD_FILE" snapshots --last 1 >/dev/null 2>&1; then
        echo "Error: unable to access snapshots in restic repository" >&2
        return 1
    fi
    
    return 0
}

extract_json_properties() {
    local json_object=$1
    local filter=$2

    local result
    if ! result=$(echo "$json_object" | jq -r "$filter" 2>/dev/null) || [[ -z "$result" || "$result" == "null" ]]; then
        echo "Error: failed to extract properties with filter '$filter' from object '$json_object', output: $result" >&2
        return 1
    fi

    echo "$result"
    return 0
}

dump_sqlite_backups() {
    local -n databases_to_dump=$1
    local output_directory=$2

    # No need to validate since we've already confirm that we have permission
    # for creating the parent staging directory
    mkdir -p "$output_directory"

    local failed=0
    for db in "${databases_to_dump[@]}"; do
        local result
        if ! result=$(extract_json_properties "$db" '[.path, .name] | @tsv'); then
            failed=1
        else
            IFS=$'\t' read -r path name <<< "$result"
            local output_path="$output_directory/$name.sqlite"
            if ! sqlite3 "$path" ".backup '$output_path'"; then
                echo "Warning: failed to backup database '$path'" >&2
                continue
            fi

            local validation_output
            if ! validation_output=$(sqlite3 "$output_path" "PRAGMA quick_check") || [[ "$validation_output" != "ok" ]]; then
                echo "Warning: there was a problem with the backup at $output_path, output: $validation_output" >&2
                continue
            fi
        fi
    done

    return "$failed"
}

dump_postgres_backups() {
    local -n databases_to_dump=$1
    local output_directory=$2

    # Create output directory
    mkdir -p "$output_directory"

    local failed=0
    for db in "${databases_to_dump[@]}"; do
        local result
        if ! result=$(extract_json_properties "$db" '[.host, .port, .database, .username, .name] | @tsv'); then
            failed=1
        else
            IFS=$'\t' read -r host port database username name <<< "$result"
            
            # Set defaults if not provided
            host=${host:-localhost}
            port=${port:-5432}
            
            local output_path="$output_directory/$name.dump"
            
            # Use pg_dump with custom format for better compression and reliability
            if ! PGPASSWORD="${POSTGRES_PASSWORDS[$name]:-}" pg_dump \
                -h "$host" \
                -p "$port" \
                -U "$username" \
                -d "$database" \
                -Fc \
                -f "$output_path"; then
                echo "Warning: failed to backup database '$database' for service '$name'" >&2
                failed=1
                continue
            fi

            # Validate the backup by listing tables
            local validation_output
            if ! validation_output=$(PGPASSWORD="${POSTGRES_PASSWORDS[$name]:-}" pg_restore --list "$output_path" 2>/dev/null | wc -l); then
                echo "Warning: there was a problem validating the backup at $output_path" >&2
                failed=1
                continue
            fi
            
            if [[ "$validation_output" -eq 0 ]]; then
                echo "Warning: backup validation failed - no objects found in $output_path" >&2
                failed=1
                continue
            fi
            
            echo "Successfully backed up '$name' database ($validation_output objects)"
        fi
    done

    return "$failed"
}

finalize_staging_environment() {
    local tmp_dump=$1
    local bkp_path="${DB_STAGING_DUMP}_bkp"

    local cmd_output
    if ! cmd_output=$(rm -rf "$bkp_path" 2>&1); then
        echo "Error: failed to clear previous backup path ($bkp_path): $cmd_output" >&2
        return 1
    fi

    if [[ -d "$DB_STAGING_DUMP" ]]; then
        if ! cmd_output=$(mv "$DB_STAGING_DUMP" "$bkp_path" 2>&1); then
            echo "Error: failed to move previous dump to the backup location: $cmd_output" >&2
            return 1
        fi
    fi

    if ! cmd_output=$(mv "$tmp_dump/" "$DB_STAGING_DUMP/" 2>&1); then
        echo "Error: failed to move tmp dump to the staging dump (a backup can be found at '$bkp_path'): $cmd_output" >&2
        return 1
    fi

    if ! cmd_output=$(rm -rf "$bkp_path" 2>&1); then
        echo "Error: failed to delete the backup path ($bkp_path) after everything else successfully finished: $cmd_output" >&2
        return 1
    fi

    return 0
}

backup_data_with_restic() {
    if ! restic -r "$BACKUP_REPO" --password-file "$RESTIC_PASSWORD_FILE" backup "$DB_STAGING_DUMP" --tag "databases" >/dev/null 2>&1; then
        echo "Error: failed to backup database dumps to restic" >&2
        return 1
    fi

    if [[ ${#FILES_TO_BACKUP[@]} -gt 0 ]]; then
        if ! restic -r "$BACKUP_REPO" --password-file "$RESTIC_PASSWORD_FILE" backup "${FILES_TO_BACKUP[@]}" --tag "files" >/dev/null 2>&1; then
            echo "Error: failed to backup files to restic" >&2
            return 1
        fi
    fi

    if ! restic -r "$BACKUP_REPO" --password-file "$RESTIC_PASSWORD_FILE" forget --keep-daily "$NUM_BACKUPS_TO_KEEP" --prune >/dev/null 2>&1; then
        echo "Error: failed to clean up old snapshots" >&2
        return 1
    fi
    
    return 0
}

perform_graceful_exit_and_ping() {
    if [[ -z "$PING_ENDPOINT" ]]; then
        return 0
    fi

    local cmd_output
    if [[ -z "$PING_SERVICE_NAME" ]]; then
        echo "Error: pingServiceName is required when pingEndpoint is set" >&2
        return 1
    fi

    if ! cmd_output=$(jq -n --arg service_name "$PING_SERVICE_NAME" '{service_name: $service_name}' | xh POST "$PING_ENDPOINT" Content-Type:application/json 2>&1); then
        echo "Error: failed to ping endpoint with JSON payload: $cmd_output" >&2
        return 1
    fi

    return 0
}

cleanup() {
    rm -rf "$STAGING_TMP" 2>/dev/null || true

    local bkp_path="${DB_STAGING_DUMP}_bkp"
    if [[ -d "$bkp_path" ]]; then
        # If backup exists, it means finalize_staging_environment didn't complete successfully
        # Restore the original if the main staging directory is missing/corrupted
        if [[ ! -d "$DB_STAGING_DUMP" ]]; then
            mv "$bkp_path" "$DB_STAGING_DUMP" 2>/dev/null || true
        else
            # Both exist, just remove the backup
            rm -rf "$bkp_path" 2>/dev/null || true
        fi
    fi
}

trap cleanup EXIT

if ! validate_restic_repository; then
    fail "restic repository is invalid, aborting!" 
fi

STAGING_TMP="${DB_STAGING_DUMP}_tmp"
if ! (rm -rf "$STAGING_TMP" && mkdir -p "$STAGING_TMP") >/dev/null 2>&1; then
    fail "permission denied for creating staging directory at: '${DB_STAGING_DUMP}', aborting!" 
fi
echo "Created temporary db staging directory '$STAGING_TMP'."

if ! dump_sqlite_backups SQLITE_TO_BACKUP "$STAGING_TMP/sqlite"; then
    fail "failed to create backups for SQLite databases, aborting!" 
fi
echo "Dumped all SQLite databases in the temporary staging directory '$STAGING_TMP'."

if ! dump_postgres_backups POSTGRES_TO_BACKUP "$STAGING_TMP/postgres"; then
    fail "failed to create backups for Postgres databases, aborting!"
fi
echo "Dumped all Postgres databases in the temporary staging directory '$STAGING_TMP'."

if ! finalize_staging_environment "$STAGING_TMP"; then
    fail "failed to finalize the staging environment, aborting!"
fi
echo "Finalized the staging environment, the temporary dump has now replaced the previous backup dump at: $DB_STAGING_DUMP"

if ! backup_data_with_restic; then
    fail "failed to backup the data with restic, aborting!"
fi
echo "Finished backing up all data in restic vault at path: $BACKUP_REPO"

if ! perform_graceful_exit_and_ping; then
    fail "failed to graceully exit, backup is added but we didn't ping for an OK heartbeat"
fi
echo "Script finished successfully, your data is secure. Happy life :)"
