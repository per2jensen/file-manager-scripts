#! /bin/bash

# License
# All scripts are licensed under the 
# GNU Public License v3.0 or later.
# See license details here: https://www.gnu.org/licenses/gpl-3.0.html


# Remove most metadata from the files (using exiftool) and leave only a few.
# Can be useful when uploading photo to varius places.


echo "DEBUG: '$NAUTILUS_SCRIPT_SELECTED_FILE_PATHS'" | cat -A | tee -a /tmp/scrubexif.log


while IFS= read -r line; do
    FILE_DIR=$(dirname "$line")
    BASE_NAME=$(basename "$line")

    echo "Scrubbing file: \"$BASE_NAME\" in \"$FILE_DIR\"" | tee -a /tmp/scrubexif.log

    # ensure `scrubexif` is only run if a file is selected  
    if [[ -z "$BASE_NAME"  ]]; then
        echo "$0:  No file selected, skipping." | tee -a /tmp/scrubexif.log
        continue
    fi

  docker run --rm \
      --read-only --security-opt no-new-privileges \
      --tmpfs /tmp \
      -v "$FILE_DIR:/photos" \
      per2jensen/scrubexif:latest --clean-inline "$BASE_NAME"  | tee -a /tmp/scrubexif.log

done <<< "$NAUTILUS_SCRIPT_SELECTED_FILE_PATHS"
