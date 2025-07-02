#!/bin/bash
# Server Updater
# --------------
#
# This script is used to manage updates to a server, particularly for one of
# an array of servers used by a project. It is designed to be run on update day
# (or any day) and will install any updates that are available.
#
# The script can optionally be provided with a directory name (usually a date)
# as an argument. The script will then read the files in that directory and
# create a database of the available updates. The script can then install the
# updates all at once or one at a time, and track the success or failure of each
# update.

# If .env file does not exist, exit with an error
if [ ! -f ".env" ]; then
    echo "ERROR: Environment file '.env' does not exist"
    echo "Copy '.env.default' to '.env' and edit to set variables"
    exit 1
fi

source .env

# Global variables
HOST_ID=""
SELECTED_ID=""
SELECTED_UPDATE=""
ACTION=""
FILE_ID=""
FILENAME=""

function init {
    # Check dependencies
    # Check if sqlite3 is installed, as it is required by this script
    if ! [ -x "$(command -v sqlite3)" ]; then
        echo 'Error: sqlite3 is not installed.' >&2
        exit 1
    fi

    # If the server name is not set, set it to the hostname
    if [ -z "$SERVER_NAME" ]; then
        echo "WARNING: Server name is not set, using hostname as server name"
        SERVER_NAME=$(hostname)
    fi

    # If the base path is not set, set it to a falder named "update-files" in the
    # current working directory
    if [ -z "$BASE_PATH" ]; then
        echo "WARNING: Base path is not set,  using './update-files' as base path"
        BASE_PATH="./update-files/"
    else
        # Append a trailing slash to the base path if it does not already have one
        if [ "${BASE_PATH: -1}" != "/" ]; then
        BASE_PATH="$BASE_PATH/"
        fi
    fi

    # Ensure the base path exists and is readable
    if [ ! -d "$BASE_PATH" ]; then
        echo "ERROR: Base path '$BASE_PATH' does not exist or is not readable"
        exit 1
    fi

    # Set the path to the sqlite database
    db_path="${BASE_PATH}data/updates.db"

    # Create sqlite database if it does not exist
    # Create ./data directory if it does not exist
    if [ ! -f "$db_path" ]; then
    echo "WARNING: Database '${db_path}' does not exist, creating..."
    mkdir -p "$BASE_PATH/data"
    sqlite3 "$db_path" "CREATE TABLE updates (id INTEGER PRIMARY KEY, name TEXT UNIQUE, added_at TEXT NOT NULL, deleted INTEGER);"
    sqlite3 "$db_path" "CREATE TABLE files (id INTEGER PRIMARY KEY, update_id INTEGER NOT NULL, name TEXT, extension TEXT, added_at TEXT, deleted INTEGER, FOREIGN KEY (update_id) REFERENCES updates(id));"
    sqlite3 "$db_path" "CREATE TABLE hosts (id INTEGER PRIMARY KEY, name TEXT UNIQUE, added_at TEXT);"
    sqlite3 "$db_path" "CREATE TABLE host_updates (id INTEGER PRIMARY KEY, host_id INTEGER NOT NULL, update_id INTEGER NOT NULL, installed INTEGER, empty INTEGER, failed INTEGER, FOREIGN KEY (host_id) REFERENCES hosts(id), FOREIGN KEY (update_id) REFERENCES updates(id));"
    sqlite3 "$db_path" "CREATE TABLE host_files (id INTEGER PRIMARY KEY, host_id INTEGER NOT NULL, file_id INTEGER NOT NULL, installed INTEGER, failed INTEGER, FOREIGN KEY (host_id) REFERENCES hosts(id), FOREIGN KEY (file_id) REFERENCES files(id));"
    fi

    # Ensure the database is writable
    # If the database is not writable, exit with an error
    if [ ! -w "$db_path" ]; then
        echo "ERROR: Database '$db_path' is not writable"
        exit 1
    fi

    # If the database is writable, check if the server name is already in the
    # database
    if sqlite3 "$db_path" "SELECT id FROM hosts WHERE name='$SERVER_NAME';"; then
        echo "Found host '$SERVER_NAME' in database"
        # Set global variable for host id
        HOST_ID=$(sqlite3 "$db_path" "SELECT id FROM hosts WHERE name='$SERVER_NAME';")
    else
        echo "WARNING: '$SERVER_NAME' not found in database, adding..."
        sqlite3 "$db_path" "INSERT INTO hosts (name,added_at) VALUES ('$SERVER_NAME',datetime('now'));"
    fi
}

# Function to refresh the database, adding new updates and files to the database
# and marking deleted files as deleted
function refresh_updates {
    # List all directories in the base path, omitting the base directory, in reverse
    # alphabetical order
    local updates=$(find "$BASE_PATH" -maxdepth 1 -type d | sed "s|$BASE_PATH||" | sed "s|data||")

    # Check if everything in $updates is in the database
    for update in $updates; do
        local installed=0
        local failed=0
        local empty=0
        local update_id=""
        local file_count=0
        local failed_count=0
        local uninstalled_count=0
        local query_result=""

        # Check if the update is in the database, if so set update_id
        if ! sqlite3 "$db_path" "SELECT name FROM updates WHERE name='$update';" | grep -q "$update"; then
            # If the update is not in the database, add it
            echo "Adding update '$update' to database"
            sqlite3 "$db_path" "INSERT INTO updates (name,added_at) VALUES ('$update',datetime('now'));"
        fi

        # Set update_id
        update_id=$(sqlite3 "$db_path" "SELECT id FROM updates WHERE name='$update';")

        # Refresh files in the update
        refresh_files "$update"

        # If any file in the update is not in the database, add it
        for file in $(find "$BASE_PATH$update" -type f ! -name ".*"); do
            # Get base name of file and extension as separate variables
            local file_name=$(basename "$file")
            local file_extension="${file_name##*.}"
            file_name="${file_name%.*}"

            # Check if the file is in the database
            if ! sqlite3 "$db_path" "SELECT name FROM files WHERE name='$file_name' AND extension='$file_extension' AND update_id=(SELECT id FROM updates WHERE name='$update');" | grep -q "$file_name"; then
                # If the file is not in the database, add it
                echo "Adding file '$file' to database"
                sqlite3 "$db_path" "INSERT INTO files (name,extension,added_at,update_id) VALUES ('$file_name','$file_extension',datetime('now'),(SELECT id FROM updates WHERE name='$update'));"
            fi
        done

        # Check if host_updates table has an entry for the update
        query_result=$(sqlite3 "$db_path" "SELECT COUNT(id) FROM host_updates WHERE host_id='$HOST_ID' AND update_id='$update_id';")
        if [[ query_result -eq 0 ]]; then
            # If the update is not in the database, add it
            echo "Adding update '$update' to host '$SERVER_NAME' database"
            sqlite3 "$db_path" "INSERT INTO host_updates (host_id,update_id,installed,failed,empty) VALUES ('$HOST_ID','$update_id',$installed,$failed,$empty);"
        fi

        # If no files in the update are in the database, mark update as empty
        file_count=$(sqlite3 "$db_path" "SELECT COUNT(id) FROM files WHERE update_id='$update_id' AND (deleted IS NULL OR deleted = 0);")
        failed_count=$(sqlite3 "$db_path" "SELECT COUNT(hf.id) FROM host_files hf JOIN files f ON hf.file_id = f.id WHERE hf.host_id='$HOST_ID' AND (f.deleted IS NULL OR f.deleted = 0) AND f.update_id='$update_id' AND (hf.failed NOT NULL AND NOT(hf.failed=0));")
        uninstalled_count=$(sqlite3 "$db_path" "SELECT COUNT(hf.id) FROM host_files hf JOIN files f ON hf.file_id = f.id WHERE hf.host_id='$HOST_ID' AND (f.deleted IS NULL OR f.deleted = 0) AND f.update_id='$update_id' AND (hf.installed IS NULL OR hf.installed=0);")

        if [[ $file_count -eq 0 ]]; then
            empty=1
        # If any file in the database has failed, mark update as failed
        elif [[ $failed_count -gt 0 ]]; then
            failed=1
        # If every file in the database is installed, mark update as installed
        elif [[ $uninstalled_count -eq 0 ]]; then
            installed=1
        fi

        # Update status of the update
        sqlite3 "$db_path" "UPDATE host_updates SET installed=$installed, failed=$failed, empty=$empty WHERE host_id='$HOST_ID' AND update_id='$update_id'"
    done

    # Check that every update in the database is present in $updates, and mark
    # any updates that are not present as deleted
    for update in $(sqlite3 "$db_path" "SELECT name FROM updates;"); do
        if ! find "$BASE_PATH" -type d -name "$update" | grep -q "$update"; then
            echo "Marking update '$update' as deleted"
            sqlite3 "$db_path" "UPDATE updates SET deleted=1 WHERE name='$update';"
        fi
    done
}

function refresh_files {
    # Check for exactly one argument
    if [ $# -ne 1 ]; then
        echo "ERROR: Exactly one argument required"
        exit 1
    fi

    # Check if the argument is a directory
    if [ ! -d "${BASE_PATH}$1" ]; then
        echo "ERROR: Argument '$1' is not a directory"
        exit 1
    fi

    # Check if the directory is writable
    if [ ! -w "${BASE_PATH}$1" ]; then
        echo "ERROR: Directory '${BASE_PATH}$1' is not writable"
        exit 1
    fi

    # Get the update id from the database
    local update_id=$(sqlite3 "$db_path" "SELECT id FROM updates WHERE name='$1';")
    if [ -z "$update_id" ]; then
        echo "ERROR: Update '$1' not found in database"
        exit 1
    fi

    # Check that every file in the directory is in the database
    for file in $(find "${BASE_PATH}$1" -type f ! -name ".*"); do
        # Get base name of file and extension as separate variables
        local file_name=$(basename "$file")
        local file_extension="${file_name##*.}"
        local file_id=""
        local query_result=""
        file_name="${file_name%.*}"

        # Check if the file is in the database
        query_result=$(sqlite3 "$db_path" "SELECT COUNT(id) FROM files WHERE name='$file_name' AND extension = '$file_extension' AND update_id = '$update_id';")
        if [[ query_result -eq 0 ]]; then
            # If the file is not in the database, add it
            echo "Adding file '$file' to database"
            sqlite3 "$db_path" "INSERT INTO files (name,extension,added_at,update_id) VALUES ('$file_name','$file_extension',datetime('now'),$update_id);"
        fi

        # Get the file id
        file_id=$(sqlite3 "$db_path" "SELECT id FROM files WHERE name='$file_name' AND extension='$file_extension' AND update_id=$update_id;")

        # Ensure the host_files table has an entry for the file
        query_result=$(sqlite3 "$db_path" "SELECT COUNT(id) FROM host_files WHERE host_id='$HOST_ID' AND file_id='$file_id';")
        if [[ query_result -eq 0 ]]; then
            # If the file is not in the database, add it
            echo "Adding file '$file' to host '$SERVER_NAME' database"
            sqlite3 "$db_path" "INSERT INTO host_files (host_id,file_id,installed,failed) VALUES ('$HOST_ID','$file_id',0,0);"
        fi
    done

    # Check that every file in the database is present in the directory, and mark
    # any files that are not present as deleted
    for file in $(sqlite3 "$db_path" "SELECT name,extension FROM files WHERE update_id = '$update_id' AND deleted IS NULL OR deleted = 0;"); do
        while IFS='|' read -r name extension; do
            local file_name="${name}.${extension}"
            if ! find "${BASE_PATH}$1" -type f -name "$file_name" | grep -q "$file_name"; then
                echo "Marking file '${BASE_PATH}$1/$file_name' as deleted"
                sqlite3 "$db_path" "UPDATE files SET deleted=1 WHERE name='$name' AND extension='$extension' AND update_id='$update_id';"
            fi
        done < <(echo "$file")
    done
}

# Show main menu, using dialog
function main_menu {
    local temp_file=$(mktemp)
    local menu_items=()

    menu_items+=("UPDATES" "Update Server")
    
    menu_items+=("QUIT" "Quit")

    dialog \
        --colors \
        --title "Server Updater" \
        --menu "Select an option:" \
        20 60 40 \
        "${menu_items[@]}" \
        2> "$temp_file"

    local exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        SELECTED_ID=$(cat "$temp_file" | sed -E 's/^([0-9]+).*/\1/')
        SELECTED_UPDATE=$(cat "$temp_file" | sed -E 's/^[0-9]+ (.*)/\1/')

        rm -f "$temp_file"

        case "$SELECTED_ID" in
            "UPDATES")
                ACTION="UPDATES"
                return 0
                ;;
            "QUIT")
                ACTION="QUIT"
                return 0
                ;;
        esac
    else
        rm -f "$temp_file"
        return 1
    fi
}

# Show update menu, using dialog
function updates_menu {
    local temp_file=$(mktemp)
    local menu_items=()

    if [[ ! -f "$db_path" ]]; then
        echo "ERROR: Database '$db_path' does not exist"
        return 1
    fi

    local query="
    SELECT
        u.id,
        u.name,
        COALESCE(uh.installed, 0) as installed,
        COALESCE(uh.failed, 0) as failed,
        COALESCE(uh.empty, 0) as empty
    FROM updates u
    LEFT JOIN host_updates uh ON u.id = uh.update_id AND uh.host_id = '$HOST_ID'
    WHERE u.deleted IS NULL OR u.deleted = 0
    ORDER BY u.name DESC;
    "

    # Read files and build menu items
    while IFS='|' read -r id name installed failed empty; do
        if [[ -n "$id" && -n "$name" ]]; then
            local status_display=""
            local status_colour=""

            if [[ $failed == "1" ]]; then
                status_display="FAILED"
                status_color="\Z1"
            elif [[ $installed == "1" ]]; then
                status_display="INSTALLED"
                status_color="\Z2"
            elif [[ $empty == "1" ]]; then
                status_display="EMPTY"
                status_color="\Z3"
            else
                status_display="-"
                status_color="\Z3"
            fi

            local padding_length=$((20 - ${#name}))
            padding_length=$(($padding_length < 0 ? 0 : $padding_length))

            local padding=$(printf "%*s" "$padding_length" "" | tr ' ' '.')
            local display_text="${name}${padding}[${status_color}${status_display}\Zn]"
            menu_items+=($id $display_text)
        fi
    done < <(sqlite3 "$db_path" "$query")

    if [[ ${#menu_items[@]} -eq 0 ]]; then
        dialog --title "No Updates" --msgbox "No updates found" 10 50
        return 1
    fi

    dialog \
        --colors \
        --title "Server Updater" \
        --menu "Select an update:" \
        20 60 40 \
        "${menu_items[@]}" \
        2> "$temp_file"

    local exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        SELECTED_ID=$(cat "$temp_file" | sed -E 's/^([0-9]+).*/\1/')
        SELECTED_UPDATE=$(cat "$temp_file" | sed -E 's/^[0-9]+ (.*)/\1/')

        rm -f "$temp_file"
    else
        rm -f "$temp_file"
        return 1
    fi
 
    return 0
}

function files_menu {
    local update_id=$1
    local update_name=$2
    local temp_file=$(mktemp)
    local menu_items=()

    if [[ -z "$update_id" ]]; then
        dialog --title "Error" --msgbox "No update ID provided" 10 50
        return 1
    fi

    local query="
    SELECT
        f.id,
        CASE
            WHEN f.extension IS NOT NULL AND f.extension != ''
            THEN f.name || '.' || f.extension
            ELSE f.name
        END as full_name,
        COALESCE(hf.installed, 0) as installed,
        COALESCE(hf.failed, 0) as failed
    FROM files f
    LEFT JOIN host_files hf ON f.id = hf.file_id AND hf.host_id = '$HOST_ID'
    WHERE f.update_id = $update_id
    AND f.deleted IS NULL OR f.deleted = 0
    ORDER BY full_name ASC;
    "

    # Read files and build menu items
    while IFS='|' read -r id name installed failed; do
        if [[ -n "$id" && -n "$name" ]]; then
            local status_display=""
            local status_colour=""

            if [[ $failed == "1" ]]; then
                status_display="FAILED"
                status_color="\Z1"
            elif [[ $installed == "1" ]]; then
                status_display="INSTALLED"
                status_color="\Z2"
            else
                status_display="-"
                status_color="\Z3"
            fi

            local padding_length=$((30 - ${#name}))
            padding_length=$(($padding_length < 0 ? 0 : $padding_length))

            local padding=$(printf "%*s" "$padding_length" "" | tr ' ' '.')
            local display_text="${name}${padding}[${status_color}${status_display}\Zn]"
            menu_items+=($id $display_text)
        fi
    done < <(sqlite3 "$db_path" "$query")

    if [[ ${#menu_items[@]} -eq 0 ]]; then
        dialog --title "No Files" --msgbox "No files found" 10 50
        return 1
    fi

    # Special items
    menu_items=("INSTALL_ALL" "Install All Files" "INSTALL_FAILED" "Retry Failed Files" "${menu_items[@]}")

    dialog \
        --colors \
        --title "Files in '$SELECTED_UPDATE'" \
        --menu "Select files to install:" \
        25 80 15 \
        "${menu_items[@]}" \
        2> "$temp_file"

    local exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        local selected_id=$(cat "$temp_file")
        local selected_name=$(echo "$updates" | sed -n "${selected_id}p")
        rm -f "$temp_file"

        case "$selected_id" in
            "INSTALL_ALL")
                echo "ACTION=INSTALL_ALL"
                echo "UPDATE_ID=$update_id"
                return 0
                ;;
            "INSTALL_FAILED")
                echo "ACTION=INSTALL_FAILED"
                echo "UPDATE_ID=$update_id"
                return 0
                ;;
            *)
                # Individual file selected
                local selected_filename=$(sqlite3 "$db_path" "
                    SELECT CASE
                        WHEN extension IS NOT NULL AND extension != ''
                        THEN name || '.' || extension
                        ELSE name
                    END
                    FROM files WHERE id = $selected_id;
                ")
                echo "ACTION=INSTALL_FILE"
                echo "FILE_ID=$selected_id"
                echo "FILENAME=$selected_name"
                echo "UPDATE_ID=$update_id"
                return 0
                ;;
        esac
    else
        rm -f "$temp_file"
        return 1
    fi

}

function run_update_workflow {
    while true; do
        if main_menu; then
            case "$ACTION" in
                "UPDATES")
                    if updates_menu; then
                        if [[ $updates_status -ne 0 ]]; then
                            echo "Exiting due to error"
                            exit 1
                        fi

                        if files_menu "$SELECTED_ID" "$SELECTED_UPDATE"; then
                            echo "Files menu action: $ACTION"

                            case "$ACTION" in
                                "INSTALL_ALL")
                                    echo "Installing all files for update $UPDATE_ID"
                                    read -r ans
                                    ;;
                                "INSTALL_FAILED")
                                    echo "Retrying failed files for update $UPDATE_ID"
                                    read -r ans
                                    ;;
                                "INSTALL_FILE")
                                    echo "Installing file $FILENAME for update $UPDATE_ID"
                                    read -r ans
                                    ;;
                            esac

                            if ! dialog --yesno "Continue with another operation?" 8 40; then
                                break
                            fi
                        fi
                    else
                        echo "Updates menu cancelled or failed"
                        break
                    fi
                    ;;
                "QUIT")
                    echo "Exiting due to user request"
                    break
                    ;;
            esac
        fi
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    init

    refresh_updates

    run_update_workflow
fi

