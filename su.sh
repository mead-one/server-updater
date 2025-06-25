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

# -------- Variables --------
# Uncomment and set the variables below

# The name of the server, used for tracking updates installed on this server
server_name="chris-desktop"

# The position of the update files, absolute path or relative to the working
# directory
base_path="./update-files"

# The command to install packages using the package manager
# Substitute position of package names with {..} if multiple packages are
# supported or {} if only one package at a time is supported
#package_manager_command="sudo apt-get install -y {..}"
package_manager_command="doas pacman -Syu --noconfirm {..}"

# List dependencies required by project that can be installed using the package
# manager
dependencies=("nodejs" "mariadb-server" "mariadb-client" "python3")
# -------- End Variables --------

# Function to refresh the database, adding new updates and files to the database
# and marking deleted files as deleted
function refresh_updates {
    # Check if everything in $updates is in the database
    for update in $updates; do
        echo $update
        # Check if the update is in the database
        if ! sqlite3 "$db_path" "SELECT id FROM updates WHERE name='$update';" | grep -q "$update"; then
            # If the update is not in the database, add it
            echo "Adding update '$update' to database"
            sqlite3 "$db_path" "INSERT INTO updates (name,added_at) VALUES ('$update',datetime('now'));"
        fi
    done

    # Check that every update in the database is present in $updates, and mark
    # any updates that are not present as deleted
    for update in $(sqlite3 "$db_path" "SELECT name FROM updates;"); do
        if ! echo "$updates" | grep -q "$update"; then
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
    if [ ! -d "${base_path}$1" ]; then
        echo "ERROR: Argument '$1' is not a directory"
        exit 1
    fi

    # Check if the directory is writable
    if [ ! -w "${base_path}$1" ]; then
        echo "ERROR: Directory '${base_path}$1' is not writable"
        exit 1
    fi

    # Get the update id from the database
    local update_id=$(sqlite3 "$db_path" "SELECT id FROM updates WHERE name='$1';")
    if [ -z "$update_id" ]; then
        echo "ERROR: Update '$1' not found in database"
        exit 1
    fi

    # Check that every file in the directory is in the database
    for file in $(find "${base_path}$1" -type f); do
        # Get base name of file and extension as separate variables
        local file_name=$(basename "$file")
        local file_extension="${file_name##*.}"
        file_name="${file_name%.*}"

        # Check if the file is in the database
        if ! sqlite3 "$db_path" "SELECT id FROM files WHERE name='$file';" | grep -q "$file"; then
            # If the file is not in the database, add it
            echo "Adding file '$file' to database"
            sqlite3 "$db_path" "INSERT INTO files (name,extension,added_at,update_id) VALUES ('$file_name','$file_extension',datetime('now'),$update_id);"
        fi
    done

    # Check that every file in the database is present in the directory, and mark
    # any files that are not present as deleted
    for file in $(sqlite3 "$db_path" "SELECT name FROM files;"); do
        if ! find "${base_path}$1" -type f | grep -q "$file"; then
            echo "Marking file '$file' as deleted"
            sqlite3 "$db_path" "UPDATE files SET deleted=1 WHERE name='$file';"
        fi
    done
}

# Show update menu, using dialog
function updates_menu {
    local temp_file=$(mktemp)
    local menu_items=()

    if [[ ! -f "$db_path" ]]; then
        echo "ERROR: Database '$db_path' does not exist"
        return 1
    fi

    # # Get menu items from the database
    # for update in $updates; do
    #     local update_id=$(sqlite3 "$db_path" "SELECT id FROM updates WHERE name='$update';")
    #     menu_items+=("$update_id $update")
    # done
    #
    # # Sort menu items newest first
    # menu_items=($(printf '%s\n' "${menu_items[@]}" | sort -r))
    
    while IFS='|' read -r id name; do
        if [[ -n "$id" && -n "$name" && "$name" != "data" ]]; then
            menu_items+=("$id $name")
        fi
    done < <(sqlite3 "$db_path" "SELECT id, name FROM updates WHERE deleted IS NULL OR deleted = 0 ORDER BY name;")

    echo menu_items

    if [[ ${#menu_items[@]} -eq 0 ]]; then
        dialog --title "No Updates" --msgbox "No updates found" 10 50
        return 1
    fi

    dialog \
        --title "Server Updater" \
        --menu "Select an update:" \
        20 60 10 \
        "${menu_items[@]}" \
        2> "$temp_file"

    local exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        local selected_id=$(cat "$temp_file")
        local selected_name=$(echo "$updates" | sed -n "${selected_id}p")
        rm -f "$temp_file"
        echo "SELECTED_ID=$selected_id"
        echo "SELECTED_UPDATE=$selected_name"
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

    local server_id=$(sqlite3 "$db_path" "SELECT id FROM hosts WHERE name='$server_name';")
    
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
    LEFT JOIN host_files hf ON f.id = hf.file_id AND hf.host_id = '$server_id'
    WHERE f.deleted IS NULL OR f.deleted = 0)
    ORDER BY full_name ASC;
    "

    # Read files and build menu items
    while IFS='|' read -r id name installed failed; do
        if [[ -n "$file_id" && -n "$full_name" ]]; then
            local status_display=""
            local status_colour=""

            if [[ "$failed" == "1" ]]; then
                status_display="FAILED"
                status_color="\Z1"
            elif [["$installed" == "1" ]]; then
                status_display="INSTALLED"
                status_color="\Z2"
            else
                status_display="-"
                status_color="\Zn"
            fi

            local display_text=$(printf "%-40s %s%s\Zn" "$full_name" "$status_colour" "$status_display")
            menu_items+=("$id $display_text")
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
        --title "Files in '$update_name'" \
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
        # local updates_result=$(updates_menu)
        updates_menu
        local updates_status=$?

        if [[ $updates_status -ne 0 ]]; then
            echo "Exiting due to error"
            exit 1
        fi

        eval "$updates_result"

        local files_result=$(files_menu "$UPDATE_ID" "$UPDATE_NAME")
        local files_status=$?

        if [[ $files_status -eq 0 ]]; then
            echo "Files menu result:"
            echo "$files_result"

            eval "$files_result"

            case "$ACTION" in
                "INSTALL_ALL")
                    echo "Installing all files for update $UPDATE_ID"
                    ;;
                "INSTALL_FAILED")
                    echo "Retrying failed files for update $UPDATE_ID"
                    ;;
                "INSTALL_FILE")
                    echo "Installing file $FILENAME for update $UPDATE_ID"
                    ;;
            esac

            if ! dialog --yesno "Continue with another operation?" 8 40; then
                break
            fi
        fi
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then 
    # Check dependencies
    # Check if sqlite3 is installed, as it is required by this script
    if ! [ -x "$(command -v sqlite3)" ]; then
        echo 'Error: sqlite3 is not installed.' >&2
        exit 1
    fi

    # If the server name is not set, set it to the hostname
    if [ -z "$server_name" ]; then
        echo "WARNING: Server name is not set, using hostname as server name"
        server_name=$(hostname)
    fi

    # If the base path is not set, set it to a falder named "update-files" in the
    # current working directory
    if [ -z "$base_path" ]; then
        echo "WARNING: Base path is not set,  using './update-files' as base path"
        base_path="./update-files/"
    else
        # Append a trailing slash to the base path if it does not already have one
        if [ "${base_path: -1}" != "/" ]; then
        base_path="$base_path/"
        fi
    fi

    # Ensure the base path exists and is readable
    if [ ! -d "$base_path" ]; then
        echo "ERROR: Base path '$base_path' does not exist or is not readable"
        exit 1
    fi

    # Set the path to the sqlite database
    db_path="$base_path/data/updates.db"

    # List all directories in the base path, omitting the base directory, in reverse
    # alphabetical order
    updates=$(find "$base_path" -maxdepth 1 -type d | sed "s|$base_path||" | sed "s|data||")

    # Create sqlite database if it does not exist
    # Create ./data directory if it does not exist
    if [ ! -f "$db_path" ]; then
    echo "WARNING: Database '${db_path}' does not exist, creating..."
    mkdir -p "$base_path/data"
    sqlite3 "$db_path" "CREATE TABLE updates (id INTEGER PRIMARY KEY, name TEXT UNIQUE, added_at TEXT NOT NULL, deleted INTEGER);"
    sqlite3 "$db_path" "CREATE TABLE files (id INTEGER PRIMARY KEY, update_id INTEGER NOT NULL, name TEXT, extension TEXT, added_at TEXT, deleted INTEGER, FOREIGN KEY (update_id) REFERENCES updates(id));"
    sqlite3 "$db_path" "CREATE TABLE hosts (id INTEGER PRIMARY KEY, name TEXT UNIQUE, added_at TEXT);"
    sqlite3 "$db_path" "CREATE TABLE host_updates (id INTEGER PRIMARY KEY, host_id INTEGER NOT NULL, update_id INTEGER NOT NULL, FOREIGN KEY (host_id) REFERENCES hosts(id), FOREIGN KEY (update_id) REFERENCES updates(id));"
    sqlite3 "$db_path" "CREATE TABLE host_files (id INTEGER PRIMARY KEY, host_id INTEGER NOT NULL, file_id INTEGER NOT NULL, FOREIGN KEY (host_id) REFERENCES hosts(id), FOREIGN KEY (file_id) REFERENCES files(id));"
    fi

    # Ensure the database is writable
    # If the database is not writable, exit with an error
    if [ ! -w "$db_path" ]; then
        echo "ERROR: Database '$db_path' is not writable"
        exit 1
    fi

    # If the database is writable, check if the server name is already in the
    # database
    if sqlite3 "$db_path" "SELECT id FROM hosts WHERE name='$server_name';"; then
        echo "Found host '$server_name' in database"
    else
        echo "WARNING: '$server_name' not found in database, adding..."
        sqlite3 "$db_path" "INSERT INTO hosts (name,added_at) VALUES ('$server_name',datetime('now'));"
    fi

    run_update_workflow
fi

