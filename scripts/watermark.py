#!/usr/bin/env python3

from PIL import Image

import argparse
import logging
import subprocess

WATERMARK='© Per Jensen, License: CC BY-NC-SA 4.0'
SIZE="750x50"
DEFAULT_WIDTH=2560
DEFAULT_PKTSIZE=36  # matches a 2560 width photo
WM_BRIGHTNESS=50
WM_SATURATION=80
WM_FILE="/tmp/wm_${PKTSIZE}_${SIZE}.png"

watermarks = {}


logging.basicConfig(
    filename="/tmp/watermark.py.log",
    level=logging.DEBUG,
    format="%(asctime)s:%(levelname)s:%(message)s"
    )

def main():

    parser = argparse.ArgumentParser()
    parser.add_argument('files', nargs='+')
    args = parser.parse_args()
    
    for file in args.files:
        im = Image.open(file)
        pktsize= int(im.width / DEFAULT_WIDTH * DEFAULT_PKTSIZE) 
        logging.debug("file: '{}', width: '{}', height: '{}', pkt size: '{}'".format(file, im.width, im.height, pktsize))   

        watermark=None
        try:
            watermark = watermarks[pktsize]       
        except:
            None

        if watermark is None:
            watermark = "/tmp/wm-{}.jpg".format(pktsize)
            try:
                completed_process = subprocess.run([
                "convert", "-size", SIZE, "xc:transparent", "-font", "NewCenturySchlbk-Italic", 
                "-pointsize", "{}".format(pktsize), 
                "-fill", "black", "-annotate", "+24+34", WATERMARK,
                "-fill", "white", "-annotate", "+26+36", WATERMARK,
                "-fill", "transparent", "-annotate", "+25+35", WATERMARK,
                watermark], check=True)

                watermarks[pktsize] = watermark
            except FileNotFoundError as exc:
                print(f"Process failed because the executable could not be found.\n{exc}")
            except subprocess.CalledProcessError as exc:
                logging.error("Generating watermark size: '{}' failed".format(pktsize))
                logging.error(f"{exc}")
            except subprocess.TimeoutExpired as exc:
                logging.error(f"Process timed out.\n{exc}")
        
        


        
if __name__ == '__main__':
    main()
