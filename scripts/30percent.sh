#! /bin/bash

#
#  combine jpegoptim and convert -resize 30% to make a quite small jpg file
#

# https://stackoverflow.com/questions/965053/extract-filename-and-extension-in-bash
split_filename () {
        for fullpath in "$1"
        do
            FILENAME="${fullpath##*/}"                      # Strip longest match of */ from start
            DIR="${fullpath:0:${#fullpath} - ${#FILENAME}}" # Substring from 0 thru pos of filename
            BASE="${FILENAME%.[^.]*}"                       # Strip shortest match of . plus at least one non-dot char from end
            EXT="${FILENAME:${#BASE} + 1}"                  # Substring from len of base thru end
            if [[ -z "$BASE" && -n "$EXT" ]]; then          # If we have an extension and no base, it's really the base
                BASE=".$EXT"
                EXT=""
            fi
            echo -e "$fullpath:\n\tDIR  = \"$DIR\"\n\tBASE = \"$BASE\"\n\text  = \"$EXT\"" >> /tmp/30%.txt
        done
}

while IFS= read -r line; do
	split_filename "$line"
	echo "$FILENAME" >> /tmp/30%.txt
	TEMPNAME="${DIR}${BASE}"
	jpegoptim -m30 --stdout "$FILENAME" > "${TEMPNAME}-30%.${EXT}"
	convert -resize 30% "${TEMPNAME}-30%.${EXT}" "${TEMPNAME}_small.${EXT}"
	rm "${TEMPNAME}-30%.${EXT}"
done <<< "$NAUTILUS_SCRIPT_SELECTED_FILE_PATHS"
