#!/bin/bash

# Configurations
LOCATION_FILE="configs/locations.cfg"
LOG_FILE="configs/logs.cfg"
COMPLOG_FILE="configs/compressions.cfg"
BACKUP_DIR="backups"

if [ ! -f "$LOCATION_FILE" ]; then
    echo "Error: $LOCATION_FILE not found."
    exit 1
fi

display_locations() {
    echo -e "\nClient Locations:"

    local count=1
    while IFS=':' read -r user_host port backup_dir
    do
        echo "$count. $user_host $port $backup_dir"
        ((count++))
    done < "${LOCATION_FILE}"

    echo -e ""
}

display_logs() {
    if [ ! -f "$LOG_FILE" ]; then
        echo "Error: Log file $LOG_FILE not found."
        exit 1
    fi

    local count=1
    while IFS=':' read -r user_host port backup_dir time
    do
        echo "$count. $user_host $port $backup_dir $time"
        ((count++))
    done < "${LOG_FILE}"
}

write_log() {
    local user_host="$1"
    local port="$2"
    local backup_dir="$3"
    local timestamp="$4"
    echo "${user_host}:${port}:${backup_dir}:${timestamp}" >> "${LOG_FILE}"
}

write_comp_log() {
    local location="$1"
    local oldSize="$2"
    local newSize="$3"
    local timestamp="$4"
    echo "${location}:${oldSize}:${newSize}:${timestamp}" >> "${COMPLOG_FILE}"
}

display_comp_logs() {
    local count=1
    while IFS=':' read -r location oldSize newSize timestamp
    do
        echo "${location} ${oldSize} ${newSize} ${timestamp}"
        ((count++))
    done < "${COMPLOG_FILE}"
}

read_timestamps() {
    local filename="$1"
    local log_file="timewarp.log" 

    # Remove .timewarp extension 
    local filename="${filename%.timewarp}"
    local line=$(grep "$filename:" "$log_file")
    if [[ -z "$line" ]]; then
        echo "Error - $filename not found in log."
        return 1
    fi

    local atime=$(awk -F':' '{print $3}' <<< "$line")
    local mtime=$(awk -F':' '{print $4}' <<< "$line")
    echo "$atime,$mtime"
}

restore_nth_backup() {
    local nth="$1"
    local adjust_time_warp="${2:-false}"
    local restore_dir=""

    # Fetching the nth most recent backup directory
    restore_dir=$(ls -dt "${BACKUP_DIR}"/*/* | sed -n "${nth}p")

    if [[ -z "${restore_dir}" ]]; then
        echo "Error: No backup found for the given number."
        return 1
    fi

    local machine_name=$(basename $(dirname "${restore_dir}"))
    local timestamp=$(basename "${restore_dir}")
    IFS="-" read -ra ADDR <<< "${machine_name}"

    # Uncompress (if needed) and restore the files
    for file in "${restore_dir}"/*; do
        if [[ "${file}" == *.gz ]]; then
            gunzip "${file}"
            file="${file%.gz}"  # Update file name to uncompressed name
        fi
         if [[ "${file}" == *.timewarp && "${adjust_time_warp}" == "true" ]]; then
            IFS=',' read -ra timestamps <<< $(read_timestamps "$file")
            touch -a -d @"${timestamps[0]}" "$file"
            touch -m -d @"${timestamps[1]}" "$file"
        fi

        scp "${file}" "${ADDR[0]}:${file}"
    done

    echo "Restored backup from ${timestamp} for ${machine_name}"
}

restore_nth_location() {
    local nth="$1"
    local user_host=""
    local port=""
    local backup_dir=""
    local count=1
    local adjust_time_warp="${2:-false}"

    while IFS=':' read -r uH p bD; do
        if [[ "${count}" -eq "${nth}" ]]; then
            user_host="${uH}"
            port="${p}"
            backup_dir="${bD}"
            break
        fi
        ((count++))
    done < "${LOCATION_FILE}"

    if [[ -z "${user_host}" ]]; then
        echo "Error: No location found for the given number."
        return 1
    fi

    # Find the most recent backup for this location
    local machine_name="${user_host/@/-}-${port}"
    local restore_dir=$(ls -dt "${BACKUP_DIR}/${machine_name}"/* | head -1)

    if [[ -z "${restore_dir}" ]]; then
        echo "Error: No backup found for the given location."
        return 1
    fi

    # Uncompress (if needed) and restore the files
    for file in "${restore_dir}"/*; do
        if [[ "${file}" == *.gz ]]; then
            gunzip "${file}"
            file="${file%.gz}"  # Update file name to uncompressed name
        fi

        if [[ "${file}" == *.timewarp && "${adjust_time_warp}" == "true" ]]; then
            IFS=',' read -ra timestamps <<< $(read_timestamps "$file")
            touch -a -d @"${timestamps[0]}" "$file"
            touch -m -d @"${timestamps[1]}" "$file"
        fi
        
        scp "${file}" "${user_host}:${backup_dir}/$(basename ${file})"
    done

    echo "Restored backup from $(basename "${restore_dir}") for ${user_host}:${port}"
}


backup_from() {
    # Pulling location information from args
    local user_host="$1"
    local port="$2"
    local backup_dir="$3"
    echo "$user_host,$port, $backup_dir"

    # Generate a timestamp for backup folder (ISO8601 format)
    local timestamp=$(date "+%Y-%m-%dT%H:%M:%S%z")

    # Determining path for local backup folder
    local machine_name="${user_host/@/-}-$port"
    local backup_dir="${BACKUP_DIR}/${machine_name}/${timestamp}"

    # Creating local backup folder
    mkdir -p "$backup_dir"
    
    # Use scp to copy files over to local backup folder
    scp -p "${user_host}:${backup_dir}/*" "$backup_dir/"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to copy files from ${user_host}:${backup_dir} to $backup_dir."
        return 1
    fi

    echo "${user_host}:${backup_dir}/*"

    # Use scp to copy files over to local backup folder
    scp -p "${user_host}:${backup_dir}/*" "$backup_dir/" 

    # If SCP is successful 
    if [ $? -eq 0 ]; then
        # Iterate through files in backup_dir
        for file in "$backup_dir"/*; do
            local backupTime=$(date +%s) 

            handle_time_warp "$file"
            compress_and_log "$file"

             # Getting timestamps of file 
            local atime=$(stat -f %a "$file")
            local mtime=$(stat -f %m "$file")

            # Adding timestamps to log
            local filename=$(basename "$file")
            echo "$filename:$backupTime:$atime:$mtime" >> "$backup_dir/timewarp.log"
        done

        # Finish off backup 
        echo "Backup - Completed successfully completed for ${user_host}:${port} - "$timestamp"."
        write_log "$user_host" "$port" "$backup_dir" "$timestamp" 

    # If SCP is unsuccessful 
    else
        echo "Error - Failed to backup for ${user_host}:${port}."
    fi

}

compress_and_log(){
    local file="$1"
    local timestamp="$2"
    local user_host="$3"
    
    # Handling compression 
    if [[ "$file" == *.xyzar ]]; then
                
        echo "A .xyzar file detected!"

        # Get original size 
        local original_size=$(stat -f %z "$file")

        # Compress
        gzip "$file"
        if [ $? -ne 0 ]; then
            echo "Error: Failed to compress $file."
            return 1
        fi  
        local comp_size=$(stat -f %z "${file}.gz")

        # Log
        log_xyzar_file "$original_size" "$comp_size" "$timestamp" "$user_host"
        write_comp_log "${user_host}" "$original_size" "$comp_size" "$timestamp"
            
    fi
}

handle_time_warp(){
    local file="$1"
    local timestamp="$2"
    local user_host="$3"
    # Checking and handling for time warp

    echo "Looking for file for time warp: $file"

    if check_time_warp "$file"; then
        
        # Rename the file with .timewarp extension
        echo "Renaming: $file to ${file}.timewarp"
        mv "$file" "${file}.timewarp"

        if [ $? -ne 0 ]; then
            echo "Error: Failed to rename $file to ${file}.timewarp."
            return 1
        fi

        file="${file}.timewarp"
                
        local original_timestamp=$(stat -f %m "$file")
        local new_timestamp=$(date +%s)
        local hours_difference=$(( (new_timestamp - original_timestamp) / 3600 ))
        
        log_time_warp "$file" "$original_timestamp" "$new_timestamp" "$hours_difference"
    fi
}

backup() {
    # Stores the given function argument, which is the location number
    local locationNum="$1"

    # If there is no location number, backup from all locations
    if [ -z "$locationNum" ]; then
        echo "Backing up from all locations..."

        while IFS=':' read -r user_host port backup_dir  
        do
            backup_from "$user_host" "$port" "$backup_dir"
        done < "${LOCATION_FILE}"

    # Restore from location number
    else 
        echo "Backing up from location ${locationNum}..."

        local count=1
        while IFS=':' read -r user_host port backup_dir 
        do  
            if [[ "$count" -eq "$locationNum" ]]; then
                backup_from "$user_host" "$port" "$backup_dir"
                break
            fi
            ((count++))
        done < "${LOCATION_FILE}"
    fi
}

log_xyzar_file() {
    local original_size="$1"
    local compressed_size="$2"
    local timestamp="$3"
    local server_source="$4"
    
    local log_entry="File: $file, Original Size: $original_size, Compressed Size: $compressed_size, Timestamp: $timestamp, Server Source: $server_source"
    echo "$log_entry" >> alien_logs/$(date +"%Y-%m-%d").log
}

check_time_warp() {
    local file="$1"
    local file_timestamp=$(stat -f %m "$file")
    local current_timestamp=$(date +%s)
    local difference=$((current_timestamp - file_timestamp))

    # 3 days in seconds = 259200 seconds
    if (( abs(difference) > 259200 )); then
        return 0
    else
        return 1
    fi
}

abs() {
    echo $(( $1 < 0 ? -$1 : $1 ))
}

log_time_warp() {
    local file="$1"
    local original_timestamp="$2"
    local new_timestamp="$3"
    local hours_difference="$4"
    
    local log_entry="File: $file, Original Timestamp: $original_timestamp, New Timestamp: $new_timestamp, Difference: $hours_difference hours"
    echo "$log_entry" >> timewarp_logs/$(date +"%Y-%m-%d").log
}

# Locations 
if [[ $# -eq 0 ]]; then
    display_locations

# Logs
elif [[ "$1" == "-logs" ]]; then
    display_logs
elif [[ "$1" == "-comp" ]]; then
    display_comp_logs

# Backup
elif [[ "$1" == "-B" ]]; then

    # Backing up from a specific location number
    if [[ "$2" == "-L" && "$3" =~ ^[0-9]+$ ]]; then
        backup "$3"
    
    # Backing up from all locations 
    else
        backup 
    fi

elif [[ "$1" == "-R" ]]; then
    # If it's -R n -T, restore the nth most recent backup and adjust timestamps
    if [[ "$2" =~ ^[0-9]+$ && "$3" == "-T" ]]; then
        restore_nth_backup "$2" true

    # If it's just -R n, restore the nth most recent backup
    elif [[ "$2" =~ ^[0-9]+$ ]]; then
        restore_nth_backup "$2"

    # If it's -R -L n -T, restore from the nth location and adjust timestamps
    elif [[ "$2" == "-L" && "$3" =~ ^[0-9]+$ && "$4" == "-T" ]]; then
        restore_nth_location "$3" true

    # If it's -R -L n, restore from the nth location 
    elif [[ "$2" == "-L" && "$3" =~ ^[0-9]+$ ]]; then
        restore_nth_location "$3"

    else
        echo "Invalid arguments for -R. Please consult '-help' for proper usage."
    fi

# Any other input
else
    echo "Unknown argument(s). Please consult '-help' for proper usage."
fi
