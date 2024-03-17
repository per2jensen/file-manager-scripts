#! /bin/bash

# License
# All scripts are licensed under the 
# GNU Public License v3.0 or later.
# See license details here: https://www.gnu.org/licenses/gpl-3.0.html


# Remove most metadata from the files (using exiftool) and leave only a few.
# Can be useful when uploading photo to varius places.

# Beware - Nikon oriented script

while IFS= read -r line; do
	FILENAME="$line"
	exiftool -all:all= \
		-tagsfromfile @ \
		-ColorSpaceTags \
		-ICC_Profile \
		-ProfileDecription \
		-exif:ExposureTime \
		-exif:CreateDate \
		-exif:SubSecTimeDigitized \
		-exif:SubSecTime \
		-exif:SubSecTimeOriginal \
		-exif:FNumber \
		-exif:ImageSize \
		-LensModel \
		-Nikon:Lens \
		-Nikon:LensType \
		-Nikon:LensIdNumber \
		-exif:Rights \
		-exif:Title \
		-exif:FocalLength \
		-exif:Subject \
		-exif:ISO \
		-exif:Orientation \
		-Exif:Artist \
		-Exif:CopyRight \
		-Iptc:By-line \
		-Xmp-dc:all \
		-Xmp-iptcExt:Event \
		-Model \
		-Exif:Software \
		"$FILENAME"		
done <<< "$NAUTILUS_SCRIPT_SELECTED_FILE_PATHS"
