# Gnome Files utilities

Small usefull scripts for the (Gnome Files Manager)[https://apps.gnome.org/da/Nautilus/] (aka Nautilus)

# License

All scripts are licensed under the (GNU Public License v3.0 or later)[https://www.gnu.org/licenses/gpl-3.0.html].

# Requirements

- exiftool
- imagemagick
- jpegoptim
- python3 for (watermark.py)

You can install the requirements on Ubuntu this way
```
sudo apt install \
  libimage-exiftool-perl \
  imagemagick \
  jpegoptim \
  python3
```

# Location

Copy the scripts to this location: ~/.local/share/nautilus/scripts

# Scripts

 |Script|Description|
 |------|-----------|
 |30percent.sh|run jpegoptim and reduce a jpeg image to 30% it's size|
 |reducemeta.sh|Remove most metadata from a jpeg|
 |remove-meta-data.sh|remove all metadata from a jpeg|
 |rename-2-timestamp|rename an image to a timestamp, tries to find the time of capture|
 |watermark.py|improved version 2 of my image watermark script, now a python script|
 |watermark.sh|version 1 of my image watermark script|

  **Beware**

 Some scripts changes the files, other scripts create a new file. There is no hard and fast rules on which does what. It is my typical usage that governs that, your milage may vary.

# Usage

- Select one or more files in a directory
- Right click
- Choose "programs"
- Select one of the utilities on the list

The list of utilities presented is essentially a "ls ~/.local/share/nautilus/scripts" + possibly more

The scripts operate on the contents of the env var NAUTILUS_SCRIPT_SELECTED_FILE_PATHS, provided by the file manager. 


For the script to be shown, it must be an executable, i.e. "chmod u+x \<file\>" may be needed.


# More info

- (Gnome apps page)[https://apps.gnome.org/da/Nautilus/]
- (Linux.com article anno 2006)[https://www.linux.com/news/extending-nautilus-scripts-and-extensions/]