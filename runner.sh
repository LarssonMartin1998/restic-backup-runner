#!/usr/bin/env bash

RESTIC_PASSWORD_FILE="/secrets/restic/password.txt"
DEPENDENCIES=(
    "restic"
    "sqlite3"
    "pg_dump"
    "jq"
    "sendmail"
    "msmtp"
)
DAILY_BACKUPS_TO_KEEP=3
BACKUP_REPO="/var/backup/restic"
DB_STAGING_DUMP="/var/backup/db_dump"

SQLITE_TO_BACKUP=(
    '{"path": "/var/lib/gotosocial/database.sqlite", "name":"gotosocial" }'
)
POSTGRES_TO_BACKUP=(
)
FILES_TO_BACKUP=(
)

check_command_exist() {
    local cmd=$1
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: $cmd could not be found" >&2
        return 1
    fi
    return 0
}

check_dependencies() {
    local -n commands_to_check=$1
    local missing=0

    for cmd in "${commands_to_check[@]}"; do
        if ! check_command_exist "$cmd"; then
            missing=1
        fi
    done

    return "$missing"
}

EMAIL_SETUP_OK=0
send_error_and_exit() {
    local error=$1
    if [[ "$EMAIL_SETUP_OK" == 1 ]]; then
        echo -e "Subject: Error from just-a-shell backup system\n\n$error" | sendmail alert@just-a-shell.dev
    fi

    echo "$error" >&2
    exit 1
}

validate_email_notification_config() {
    # This is also checked during dependency checks, however, we want to be able to send emails if depenency checks fails.
    # which means this has to run first, and we have at this point not guaranteed the existance of msmtp...
    # Chicken and egg situation :) Double checking is fine
    if ! check_command_exist msmtp; then
        echo "Warning: msmtp missing. Notifications won't be sent!"
        return 1;
    fi

    if ! msmtp --serverinfo --account=default >/dev/null 2>&1; then
        echo "Warning: misconfigured msmtp config. Notifications won't be sent!"
        return 1;
    fi
    EMAIL_SETUP_OK=1
    return 0
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
    local bkp_path="${DB_STAGING_DUMP}_bkp/"

    local cmd_output
    if ! cmd_output=$(mv "$DB_STAGING_DUMP/" "$bkp_path" 2>&1); then
        echo "Error: failed to move previous dump to the backup location: $cmd_output" >&2
        return 1
    fi

    if ! cmd_output=$(mv "$tmp_dump/" "$DB_STAGING_DUMP/" 2>&1); then
        echo "Error: failed to move tmp dump to the staging dump (a backup can be found at '$bkp_path'): $cmd_output" >&2
        return 1
    fi

    if ! cmd_output=$(rm -rf "$bkp_path"); then
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

    if ! restic -r "$BACKUP_REPO" --password-file "$RESTIC_PASSWORD_FILE" forget --keep-daily "$DAILY_BACKUPS_TO_KEEP" --prune >/dev/null 2>&1; then
        echo "Error: failed to clean up old snapshots" >&2
        return 1
    fi
    
    return 0
}

perform_graceful_exit_and_ping() {
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

validate_email_notification_config

if ! validate_restic_repository; then
    send_error_and_exit "restic repository is invalid, aborting!" 
fi

if ! check_dependencies DEPENDENCIES; then
    send_error_and_exit "missing dependencies, aborting!" 
fi
echo "Dependency check successfully completed."

STAGING_TMP="${DB_STAGING_DUMP}_tmp"
if ! (rm -rf "$STAGING_TMP" && mkdir -p "$STAGING_TMP") >/dev/null 2>&1; then
    send_error_and_exit "permission denied for creating staging directory at: '${DB_STAGING_DUMP}', aborting!" 
fi
echo "Created temporary db staging directory '$STAGING_TMP'."

if ! dump_sqlite_backups SQLITE_TO_BACKUP "$STAGING_TMP/sqlite"; then
    send_error_and_exit "failed to create backups for SQLite databases, aborting!" 
fi
echo "Dumped all SQLite databases in the temporary staging directory '$STAGING_TMP'."

if ! dump_postgres_backups POSTGRES_TO_BACKUP "$STAGING_TMP/postgres"; then
    send_error_and_exit "failed to create backups for Postgres databases, aborting!"
fi
echo "Dumped all Postgres databases in the temporary staging directory '$STAGING_TMP'."

if ! finalize_staging_environment "$STAGING_TMP"; then
    send_error_and_exit "failed to finalize the staging environment, aborting!"
fi
echo "Finalized the staging environment, the temporary dump has now replaced the previous backup dump at: $DB_STAGING_DUMP"

if ! backup_data_with_restic; then
    send_error_and_exit "failed to backup the data with restic, aborting!"
fi
echo "Finished backing up all data in restic vault at path: $BACKUP_REPO"

if ! perform_graceful_exit_and_ping; then
    send_error_and_exit "failed to graceully exit, backup is added but we didn't ping for an OK heartbeat"
fi
echo "Script finished successfully, your data is secure. Happy life :)"
