#!/usr/bin/env python3

'''
License
GNU Public License v3.0 or later.
See license details here: https://www.gnu.org/licenses/gpl-3.0.html

See this for help on exif tag "orientation": 
https://unix.stackexchange.com/questions/634115/imagemagick-gravity-portrait-photo-frame-of-reference-rotated-90
'''


from PIL import Image

import argparse
import logging
import subprocess
import sys

WATERMARK='© Per Jensen, license CC BY-NC-SA 4.0'
WM_WIDTH=700 # matches the copyright notice at pkt 36
WM_HEIGHT=36
DEFAULT_WIDTH=2560
DEFAULT_PKTSIZE=32 # matches a 2560 width photo
WM_BRIGHTNESS=30
WM_SATURATION=50

watermarks = {}

logging.basicConfig(
    filename="/tmp/watermark.py.log",
    level=logging.INFO,
    format="%(asctime)s:%(levelname)s:%(message)s")

def rename_file(f):
    filename = f.rsplit(".", 1)
    return "{}_wm.{}".format(filename[0], filename[1])

def rename_auto_orient_file(f):
    filename = f.rsplit(".", 1)
    return "{}_auto_orient.{}".format(filename[0], filename[1])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('files', nargs='+')
    args = parser.parse_args()
    
    for file in args.files:
        im = Image.open(file)
        width = im.width
        if width < 1100:
            width = 1100

        pktsize= int(width / DEFAULT_WIDTH * DEFAULT_PKTSIZE)
        wm_width=int(width / DEFAULT_WIDTH * WM_WIDTH)
        wm_height=int(width / DEFAULT_WIDTH * WM_HEIGHT)
        logging.info("file: '{}', width: '{}', height: '{}', watermark pkt size: '{}'".format(file, im.width, im.height, pktsize))   

        watermark=None
        try:
            watermark = watermarks[pktsize]       
        except:
            None

        try:
            if watermark is None:
                watermark = "/tmp/wm-{}.png".format(pktsize)

                completed_process = subprocess.run([
                "convert",  "-size",  "{}x{}".format(wm_width, wm_height),  "xc:transparent",  "-font", "NewCenturySchlbk-Italic",
                "-pointsize", "{}".format(pktsize), "-gravity", "southeast",
                "-fill", "black",  "-draw", "text -1+0 \"{}\"".format(WATERMARK),
                "-fill", "lightgrey", "-draw", "text +0+0 \"{}\"".format(WATERMARK),
                watermark],  check=True, capture_output=True, encoding="utf-8")
                logging.debug(completed_process)
                watermarks[pktsize] = watermark

            new_filename = rename_file(file)
            geometry_w = int(width / DEFAULT_WIDTH * 40)
            geometgy_h = int(width / DEFAULT_WIDTH * 35)
            logging.info("watermarking: file: '{}'".format(file))

            # check if Exif Orientation is "TopLeft", if not use IM -auto-orient feature on a copied image
            cp =  subprocess.run([
            "identify", "-format", r"'%[orientation]'", file],
            check=True, capture_output=True, encoding="utf-8")
            logging.debug(cp)
            if (cp.stdout.find("TopLeft") == -1): #Exif Orientation is not TopLeft, let's fix that
                file_auto_orient = rename_auto_orient_file(file)
                cp =  subprocess.run([
                "convert", "-auto-orient", file, file_auto_orient], # don't change original file
                check=True, capture_output=True, encoding="utf-8")
                logging.debug(cp)
                file = file_auto_orient  

            # composite watermark and image
            completed_process = subprocess.run([
            "composite", watermark, file,
            "-watermark", "{}x{}".format(WM_BRIGHTNESS, WM_SATURATION),
            "-gravity", "southeast",
            "-geometry", "+{}+{}".format(geometry_w, geometgy_h),
            new_filename], check=True, capture_output=True, encoding="utf-8")
            logging.debug(completed_process)
        except FileNotFoundError as exc:
            print(f"Process failed because the executable could not be found.\n{exc}")
            sys.exit(-1)
        except subprocess.CalledProcessError as exc:
            logging.error("stderr: {}".format(exc.stderr))
            logging.error("stdout: {}".format(exc.stdout))
            logging.error(f"{exc}")
        except subprocess.TimeoutExpired as exc:
            logging.error(f"Process timed out.\n{exc}")

if __name__ == '__main__':
    main()
