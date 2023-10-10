#! /bin/bash
#
#  watermark a jpg file with the file stored in the WM variable
#
#  The watermark is 750x50 pixels, this matches a photo with width 2560 pixels (to my liking)
#  The script scales the watermark to other widths
#
#  Got some very good inspiration here: https://amytabb.com/til/photography/2021/01/23/image-magick-watermark/
#  thanks :-)

WATERMARK='© Per Jensen, License: CC BY-NC-SA 4.0'
SIZE=750x50
PKTSIZE=36
WM_BRIGHTNESS=50
WM_SATURATION=80
WM_FILE="/tmp/wm_${PKTSIZE}_${SIZE}.png"

# create watermark
convert -size $SIZE xc:transparent -font NewCenturySchlbk-Italic \
  -pointsize $PKTSIZE \
  -fill black       -annotate +24+34 "$WATERMARK" \
  -fill white       -annotate +26+36 "$WATERMARK" \
  -fill transparent -annotate +25+35 "$WATERMARK" \
  "$WM_FILE"


while IFS= read -r file; do
    BASE=$(basename "$file")
	
	BASE2="${BASE%.*}"
	#echo base: $BASE2
		
	EXT="${BASE##*.}"
	#echo ext: $EXT

    PHOTO_WM="${BASE2}_wm.${EXT}"

    # stamp watermark on photo
    composite "${WM_FILE}" "$file" \
       -watermark ${WM_BRIGHTNESS}x${WM_SATURATION} \
       -gravity southeast  \
       -geometry -10+10  \
       "${PHOTO_WM}"
done <<< "$NAUTILUS_SCRIPT_SELECTED_FILE_PATHS"
