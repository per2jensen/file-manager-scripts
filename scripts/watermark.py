#!/usr/bin/env python3

from PIL import Image

import argparse
import logging
import subprocess

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
    level=logging.DEBUG,
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
        pktsize= int(im.width / DEFAULT_WIDTH * DEFAULT_PKTSIZE)
        wm_width=int(im.width / DEFAULT_WIDTH * WM_WIDTH)
        wm_height=int(im.width / DEFAULT_WIDTH * WM_HEIGHT)
        logging.debug("file: '{}', width: '{}', height: '{}', pkt size: '{}'".format(file, im.width, im.height, pktsize))   

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
                "-fill", "lightgrey", "-draw", "text +0+0 \"{}\"".format(WATERMARK),
                "-fill", "darkgrey",  "-draw", "text -2+0 \"{}\"".format(WATERMARK),
                watermark],  check=True, capture_output=True, encoding="utf-8")
                logging.debug(completed_process)
                watermarks[pktsize] = watermark
        except FileNotFoundError as exc:
            print(f"Process failed because the executable could not be found.\n{exc}")
        except subprocess.CalledProcessError as exc:
            logging.error("Generating watermark size: '{}' failed".format(pktsize))
            logging.error(f"{exc}")
        except subprocess.TimeoutExpired as exc:
            logging.error(f"Process timed out.\n{exc}")


        try:
            new_filename = rename_file(file)
            logging.info("watermarking: file: '{}'".format(file))
            completed_process = subprocess.run([
            "composite", watermark, file,
            "-watermark", "{}x{}".format(WM_BRIGHTNESS, WM_SATURATION),
            "-gravity", "southeast",
            "-geometry", "+20+20",
            new_filename], check=True, capture_output=True, encoding="utf-8")
            logging.debug(completed_process)
        except FileNotFoundError as exc:
            print(f"Process failed because the executable could not be found.\n{exc}")
        except subprocess.CalledProcessError as exc:
            logging.error("Stamping watermark failed")
            logging.error(f"{exc}")
        except subprocess.TimeoutExpired as exc:
            logging.error(f"Process timed out.\n{exc}")

if __name__ == '__main__':
    main()
