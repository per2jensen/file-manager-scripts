#! /bin/bash

# License
# All scripts are licensed under the 
# GNU Public License v3.0 or later.
# See license details here: https://www.gnu.org/licenses/gpl-3.0.html

while IFS= read -r line; do
	FILENAME="$line"
	exiftool -r -overwrite_original  -all= "$FILENAME"		
done <<< "$NAUTILUS_SCRIPT_SELECTED_FILE_PATHS"
