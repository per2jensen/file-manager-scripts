#!/bin/bash
#
# watermark files mentioned in Nautilus' envvar NAUTILUS_SCRIPT_SELECTED_FILE_PATHS
#  and make them 1500 px on the longest side and 81% quality for web use.
# - Tiled semi-transparent watermark overlay across the image (optional)
# - White frame around the image
# - Copyright stamp in the lower-right corner of the frame
# 
# Optionally set the TEXT variable to add a tiled watermark overlay across the image.
#
# Optimized: watermark overlay is generated once per unique image size + pointsize.
# Cache files are named overlay_WxH_psNN.png so different pointsizes never collide.
#
set -euo pipefail

OPACITY="35"          # 0–100 (percent), used with -evaluate Multiply
POINTSIZE=130
FONT="Montserrat-SemiBold"
ANGLE=30
DENSITY=4
QUALITY=81
MAXSIZE=1500
OVERLAY_CACHE="/tmp/wm_overlay_cache"

# Frame settings
FRAME_COLOR="white"
FRAME_TOP=10          # px — border on top
FRAME_SIDE=10         # px — border on sides
FRAME_BOTTOM=10       # px — border on bottom

# Copyright stamp in the frame
TEXT=""  # Optional tiled text overlay (e.g. "© hunde.pics/igp2026")
COPYRIGHT_TEXT='Copyright Per Jensen, www.hunde.pics, license: CC BY-NC-SA 4.0'
COPYRIGHT_FONT="Montserrat-Regular"
COPYRIGHT_POINTSIZE=12
COPYRIGHT_COLOR="black"
# Fine-tune position relative to SouthEast corner.
# Positive X moves text further LEFT from the right edge.
# Positive Y moves text further UP from the bottom edge.
COPYRIGHT_OFFSET_X=16
COPYRIGHT_OFFSET_Y=2

rm -rf "$OVERLAY_CACHE"
mkdir -p "$OVERLAY_CACHE"

# --- Overlay generation ---
# Note: generate_overlay runs in a subshell via $() so counters are
# tracked in the main shell by checking the cache file directly.
generate_overlay() {
    local w="$1"
    local h="$2"
    local ps="$3"
    local overlay="$OVERLAY_CACHE/overlay_${w}x${h}_ps${ps}.png"

    # Return early if cached — caller tracks the hit
    if [ -f "$overlay" ]; then
        return
    fi

    local ANNOTATIONS=()
    for ((row=0; row<DENSITY; row++)); do
        for ((col=0; col<DENSITY; col++)); do
            local X=$((col * w / DENSITY))
            local Y=$((row * h / DENSITY))
            ANNOTATIONS+=(-annotate "-${ANGLE}x-${ANGLE}+${X}+${Y}" "$TEXT")
        done
    done

    # Step 1: draw opaque white text on transparent canvas
    convert -size ${w}x${h} xc:none \
        -font "$FONT" \
        -fill "white" \
        -pointsize "$ps" \
        -gravity NorthWest \
        "${ANNOTATIONS[@]}" \
        PNG32:/tmp/wm_text_${w}x${h}.png

    # Step 2: reduce alpha to OPACITY% so text is semi-transparent
    convert /tmp/wm_text_${w}x${h}.png \
        -channel Alpha \
        -evaluate Multiply "0.${OPACITY}" \
        +channel \
        PNG32:"$overlay"

    rm -f /tmp/wm_text_${w}x${h}.png
}

# --- Main loop ---
COUNT_OK=0
COUNT_ERR=0
CACHE_HITS=0
CACHE_GENERATED=0


while IFS= read -r file; do
    BASE=$(basename "$file")
	
	BASE2="${BASE%.*}"
	#echo base: $BASE2
		
	EXT="${BASE##*.}"
	#echo ext: $EXT

    BASENAME="${BASE2}_wm.${EXT}"

    # Auto-orient first so dimensions reflect actual displayed orientation
    ORIENTED="/tmp/wm_oriented_$$.jpg"
    convert "$file" -auto-orient "$ORIENTED"

    W=$(identify -format "%w" "$ORIENTED")
    H=$(identify -format "%h" "$ORIENTED")

    # Scale watermark pointsize proportionally to the longest side.
    # Calibrated so a 6000px image gets the default POINTSIZE (130pt)
    # with a minimum floor of 24pt to stay readable.
    LONGEST=$(( W > H ? W : H ))
    EFFECTIVE_POINTSIZE=$(( LONGEST * POINTSIZE / 6000 ))
    (( EFFECTIVE_POINTSIZE < 24 )) && EFFECTIVE_POINTSIZE=24

    # Build the convert command as an array so we can optionally insert the overlay
    CMD=(convert "$ORIENTED")

    if [[ -n "$TEXT" ]]; then
        OVERLAY_FILE="$OVERLAY_CACHE/overlay_${W}x${H}_ps${EFFECTIVE_POINTSIZE}.png"
        if [ -f "$OVERLAY_FILE" ]; then
            (( CACHE_HITS++ )) || true
        else
            generate_overlay "$W" "$H" "$EFFECTIVE_POINTSIZE"
            (( CACHE_GENERATED++ )) || true
        fi
        CMD+=("$OVERLAY_FILE" -compose Over -composite)
    fi

    CMD+=(
        -resize "${MAXSIZE}x${MAXSIZE}>"
        -bordercolor "$FRAME_COLOR"
        -border "${FRAME_SIDE}x${FRAME_TOP}"
        -gravity South
        -background "$FRAME_COLOR"
        -splice "0x${FRAME_BOTTOM}"
        -gravity SouthEast
        -font "$COPYRIGHT_FONT"
        -pointsize "$COPYRIGHT_POINTSIZE"
        -fill "$COPYRIGHT_COLOR"
        -annotate "+${COPYRIGHT_OFFSET_X}+${COPYRIGHT_OFFSET_Y}" "$COPYRIGHT_TEXT"
        -quality "$QUALITY"
        "$BASENAME"
    )

    if "${CMD[@]}"; then
        rm -f "$ORIENTED"
        echo "Done: $BASENAME"
        (( COUNT_OK++ )) || true
    else
        rm -f "$ORIENTED"
        echo "Error processing $file"
        (( COUNT_ERR++ )) || true
    fi

done <<< "$NAUTILUS_SCRIPT_SELECTED_FILE_PATHS"

echo ""
echo "=== Watermark summary ==="
echo "  Processed OK        : $COUNT_OK"
echo "  Errors              : $COUNT_ERR"
[[ -n "$TEXT" ]] && echo "  Overlay text        : $TEXT" || echo "  Overlay text        : (none)"
if [[ -n "$TEXT" ]]; then
    echo "  Overlay cache hits  : $CACHE_HITS"
    echo "  Overlay generated   : $CACHE_GENERATED"
fi
[[ "$CLEAR_CACHE" == "1" ]] && echo "  Cache cleared       : yes" || echo "  Cache cleared       : no"
echo "========================="
