# Chapter 25: Graphics and Design

## Overview

Graphics and design applications provide image editing, vector graphics, 3D modeling, and desktop publishing tools. This chapter covers installing and configuring graphics applications on StormFS Linux.

## Prerequisites

Before installing graphics applications, ensure the following are configured:

- Desktop environment or window manager ([Chapters 17-21](chapters/17-xfce.md))

## GIMP

### Installation

```bash
# Install GIMP
bfsos install gimp

# With additional plugins
bfsos install gimp-gmic
```

### Launching GIMP

```bash
# Launch GIMP
gimp

# Open specific file
gimp /path/to/image.png

# Single-window mode
gimp --single-window
```

### Configuration

```bash
# GIMP configuration directory
~/.config/GIMP/

# Reset configuration
rm -rf ~/.config/GIMP/

# Install plugins
cp /path/to/plugin ~/.config/GIMP/2.10/plug-ins/
chmod +x ~/.config/GIMP/2.10/plug-ins/plugin-name
```

### Common Operations

```bash
# Batch processing with GIMP
gimp -i -b '(gimp-file-load 1 "/path/to/input.png")' \
     -b '(gimp-file-save 1 0 "/path/to/output.jpg" "output.jpg" 0)' \
     -b '(gimp-quit 0)'

# Script-Fu console
# Filters → Script-Fu → Console
```

### Plugins

```bash
# Popular GIMP plugins
# - G'MIC (image processing)
# - Resynthesizer (texture synthesis)
# - BIMP (batch processing)
# - Liquid Rescale (content-aware scaling)

# Install G'MIC
bfsos install gimp-gmic
```

## Inkscape

### Installation

```bash
# Install Inkscape
bfsos install inkscape
```

### Launching Inkscape

```bash
# Launch Inkscape
inkscape

# Open specific file
inkscape /path/to/drawing.svg

# Export as PNG
inkscape --export-type=png --export-filename=output.png input.svg
```

### Configuration

```bash
# Inkscape configuration directory
~/.config/inkscape/

# Reset configuration
rm -rf ~/.config/inkscape/

# Extensions directory
~/.config/inkscape/extensions/
```

### Common Operations

```bash
# Convert SVG to PNG
inkscape --export-type=png --export-filename=output.png input.svg

# Convert SVG to PDF
inkscape --export-type=pdf --export-filename=output.pdf input.svg

# Export with specific DPI
inkscape --export-dpi=300 --export-type=png output.png input.svg
```

### Extensions

```bash
# Popular Inkscape extensions
# - Remove Background
# - Convert to LaTeX
# - Perfect Freehand
# - Inkscape Open Clip Art

# Install extensions
cp /path/to/extension.py ~/.config/inkscape/extensions/
```

## Darktable

### Installation

```bash
# Install Darktable
bfsos install darktable
```

### Launching Darktable

```bash
# Launch Darktable
darktable

# Open specific image
darktable /path/to/image.raw
```

### Configuration

```bash
# Darktable configuration directory
~/.config/darktable/

# Library database
~/.config/darktable/library.db

# Reset configuration
rm -rf ~/.config/darktable/
```

### Common Operations

```bash
# Import photos
darktable --library /path/to/photos/

# Export edited photos
darktable-cli input.raw output.jpg

# Batch export
darktable-cli --core --width 1920 --height 1080 input.raw output.jpg
```

### Modules

```bash
# Key Darktable modules
# - Basic: exposure, white balance, contrast
# - Color: color balance, color zones
# - Detail: sharpen, denoise
# - Geometry: crop, rotate, perspective
# - Effects: vignetting, grain, bloom
```

## Blender

### Installation

```bash
# Install Blender
bfsos install blender
```

### Launching Blender

```bash
# Launch Blender
blender

# Open specific file
blender /path/to/file.blend

# Background mode (rendering)
blender -b file.blend -o //output -f 1
```

### Configuration

```bash
# Blender configuration directory
~/.config/blender/

# Add-ons directory
~/.config/blender/addons/

# Scripts directory
~/.config/blender/scripts/
```

### Common Operations

```bash
# Render single frame
blender -b file.blend -o //output -f 1

# Render animation
blender -b file.blend -o //output -a

# Python scripting
blender --background --python script.py
```

### Add-ons

```bash
# Popular Blender add-ons
# - Animation Nodes
# - Rigify
# - Cell Fracture
# - Archipack

# Enable add-ons
# Edit → Preferences → Add-ons
```

## Scribus

### Installation

```bash
# Install Scribus
bfsos install scribus
```

### Launching Scribus

```bash
# Launch Scribus
scribus

# Open specific file
scribus /path/to/document.sla
```

### Configuration

```bash
# Scribus configuration directory
~/.config/scribus/

# Profiles directory
~/.config/scribus/profiles/

# Reset configuration
rm -rf ~/.config/scribus/
```

### Common Operations

```bash
# Create PDF
# File → Export → Save as PDF

# Preflight check
# Tools → Preflight Verifier

# Color management
# Edit → Colors and Brushes
```

## Other Graphics Tools

### ImageMagick

```bash
# Install ImageMagick
bfsos install imagemagick

# Convert image formats
convert input.png output.jpg

# Resize image
convert input.jpg -resize 800x600 output.jpg

# Add text to image
convert input.jpg -gravity center -pointsize 24 -annotate 0 "Text" output.jpg

# Create montage
montage *.jpg -geometry 200x200+10+10 -tile 3x3 output.jpg
```

### FeatherPad (Lightweight Text Editor)

```bash
# Install FeatherPad
bfsos install featherpad

# Launch FeatherPad
featherpad
```

### Viewnior (Lightweight Image Viewer)

```bash
# Install Viewnior
bfsos install viewnior

# Launch Viewnior
viewnior /path/to/image.png
```

## Tips

- GIMP is powerful for raster image editing; consider using it instead of Photoshop.
- Inkscape is excellent for vector graphics and logo design.
- Darktable provides professional photo processing capabilities.
- Blender can handle 3D modeling, animation, and video editing.
- Use ImageMagick for batch image processing via command line.
- Consider using Krita for digital painting.

## Troubleshooting

### GIMP Not Starting

1. Check configuration:
   ```bash
   rm -rf ~/.config/GIMP/
   ```

2. Check dependencies:
   ```bash
   ldd /usr/bin/gimp
   ```

### Inkscape Performance Issues

1. Reduce complexity of SVG files
2. Use the Preview mode for faster rendering
3. Consider using the command-line for batch operations

### Blender Rendering Issues

1. Check GPU drivers:
   ```bash
   lspci | grep -i vga
   ```

2. Enable GPU rendering:
   ```bash
   # Edit → Preferences → System → Cycles Render Devices
   ```

## Next Steps

After graphics setup, proceed to [Chapter 26: Development Tools](chapters/26-development.md) for development environment setup.
