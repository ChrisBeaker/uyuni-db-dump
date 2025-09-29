#!/bin/bash
#
# A script to back up the susemanager and reportdb databases from
# the uyuni-server container using podman.
# It reads connection details directly from /etc/rhn/rhn.conf inside the container.
#
# Please make sure to use a directory where sufficient disk space is available. 
# The default is /var/lib/containers/storage/db-dumps/ which is part of the base storage of SUSE Multi Linux Manager   
# Location can be set in the "Configuration" section

set -o pipefail # Ensures that a pipeline command fails if any command in it fails

# --- Configuration ---
CONTAINER_NAME="uyuni-server"
BACKUP_DIR="/var/lib/containers/storage/db-dumps/"
CONFIG_FILE="/etc/rhn/rhn.conf"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")

# --- Pre-run Checks ---
# 1. Ensure the backup directory exists on the host
mkdir -p "$BACKUP_DIR"
if [ ! -d "$BACKUP_DIR" ]; then
    echo "Error: Backup directory '$BACKUP_DIR' could not be created."
    exit 1
fi

# 2. Check if the container is running
if ! podman container exists "$CONTAINER_NAME" || ! podman container inspect --format '{{.State.Running}}' "$CONTAINER_NAME" | grep -q 'true'; then
    echo "Error: Container '$CONTAINER_NAME' is not running or does not exist."
    exit 1
fi
echo "Container '$CONTAINER_NAME' is running. Proceeding with backup."

# --- Helper Function to Read Config from Container ---
# Usage: get_config <key_name>
get_config() {
    local key=$1
    # Executes cat in the container, pipes it to the host, and parses it here.
    podman exec "$CONTAINER_NAME" cat "$CONFIG_FILE" | grep "^${key} " | awk -F' = ' '{print $2}'
}

# --- Backup Function ---
# This function handles the backup logic for a single database.
# Usage: backup_database <config_prefix>
# Example: backup_database "db" for susemanager
#          backup_database "report_db" for reportdb
backup_database() {
    local prefix=$1
    echo "--------------------------------------------------------"

    # 1. Extract database details from the container's config file
    local DB_USER=$(get_config "${prefix}_user")
    local DB_PASS=$(get_config "${prefix}_password")
    local DB_NAME=$(get_config "${prefix}_name")
    local DB_HOST=$(get_config "${prefix}_host")
    local DB_PORT=$(get_config "${prefix}_port")
    local SSL_ENABLED=$(get_config "${prefix}_ssl_enabled")

    # Check if we got the required values
    if [ -z "$DB_USER" ] || [ -z "$DB_PASS" ] || [ -z "$DB_NAME" ]; then
        echo "Error: Could not read database configuration for prefix '${prefix}'. Skipping."
        return 1
    fi

    echo "Starting backup for database: '$DB_NAME' on host '$DB_HOST'"

    # 2. Prepare environment variables for podman exec
    # These variables (PGUSER, PGPASSWORD, etc.) are used by pg_dump inside the container.
    local PODMAN_ENV_VARS=(
        -e PGUSER="$DB_USER"
        -e PGPASSWORD="$DB_PASS"
        -e PGHOST="$DB_HOST"
        -e PGPORT="$DB_PORT"
        -e PGDATABASE="$DB_NAME"
    )

    # 3. Handle SSL configuration
    if [[ "$SSL_ENABLED" == "1" ]]; then
        echo "SSL is enabled for this database."
        local SSL_ROOT_CERT=$(get_config "${prefix}_sslrootcert")
        if [ -n "$SSL_ROOT_CERT" ]; then
            PODMAN_ENV_VARS+=(-e PGSSLMODE="verify-ca" -e PGSSLROOTCERT="$SSL_ROOT_CERT")
            echo "SSL mode set to 'verify-ca' with root cert at $SSL_ROOT_CERT"
        else
            PODMAN_ENV_VARS+=(-e PGSSLMODE="require") # Fallback if cert path is missing
            echo "Warning: SSL is enabled but no root cert was found. Setting SSL mode to 'require'."
        fi
    fi

    # 4. Define backup file name on the host
    local BACKUP_FILE="$BACKUP_DIR/${DB_NAME}_${TIMESTAMP}.sql.gz"

    # 5. Execute the backup command
    # The output of pg_dump is piped to gzip and saved on the host machine.
    echo "Dumping database to: $BACKUP_FILE"
    podman exec "${PODMAN_ENV_VARS[@]}" "$CONTAINER_NAME" pg_dump -U "$DB_USER" -h "$DB_HOST" -p "$DB_PORT" "$DB_NAME" | gzip > "$BACKUP_FILE"

    # 6. Check the exit code of the pipeline
    if [ $? -eq 0 ]; then
        echo "✅ Backup of '$DB_NAME' completed successfully."
    else
        echo "❌ ERROR: Backup of '$DB_NAME' failed."
        # Clean up the failed (and likely empty) backup file
        rm -f "$BACKUP_FILE"
    fi
}

# --- Main Execution ---
echo "Starting Uyuni database backup process at $(date)"
backup_database "db"        # Backs up the 'susemanager' database
backup_database "report_db" # Backs up the 'reportdb' database
echo "--------------------------------------------------------"
echo "Backup script finished at $(date)"