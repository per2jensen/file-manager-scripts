#!/usr/bin/env python3

from PIL import Image

import argparse
import logging
import subprocess
import sys

WATERMARK='© Per Jensen, License: CC BY-NC-SA 4.0'
WM_WIDTH=700 # matches the copyright notice for pkt 36 for at 2650px wide photo
WM_HEIGHT=36
DEFAULT_WIDTH=2560
DEFAULT_PKTSIZE=36 # matches a 2560 width photo
WM_BRIGHTNESS=50
WM_SATURATION=80

watermarks = {}

logging.basicConfig(
    filename="/tmp/watermark.py.log",
    level=logging.INFO,
    format="%(asctime)s:%(levelname)s:%(message)s")

def rename_file(f):
    filename = f.rsplit(".", 1)
    return "{}_wm.{}".format(filename[0], filename[1])


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
                "-pointsize", "{}".format(pktsize), "-gravity", "east",
                "-fill", "black",  "-draw", "text -1+0 \"{}\"".format(WATERMARK),
                "-fill", "lightgrey", "-draw", "text +0+0 \"{}\"".format(WATERMARK),
                watermark],  check=True, capture_output=True, encoding="utf-8")
                logging.debug(completed_process)
                watermarks[pktsize] = watermark

            new_filename = rename_file(file)
            geometry_w = int(width / DEFAULT_WIDTH * 40)
            geometgy_h = int(width / DEFAULT_WIDTH * 35)
            logging.info("watermarking: file: '{}'".format(file))
            completed_process = subprocess.run([
            "composite", watermark, file,
            "-watermark", "{}x{}".format(WM_BRIGHTNESS, WM_SATURATION),
            "-gravity", "southeast",
#           "-geometry", "+40+35",
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
