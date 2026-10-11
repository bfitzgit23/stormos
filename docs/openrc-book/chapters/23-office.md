# Chapter 23: Office Suites

## Overview

Office suites provide document creation, spreadsheets, and presentation tools. This chapter covers installing and configuring office applications on StormFS Linux.

## Prerequisites

Before installing office suites, ensure the following are configured:

- Desktop environment or window manager ([Chapters 17-21](chapters/17-xfce.md))

## LibreOffice

### Installation

```bash
# Install LibreOffice
bfsos install libreoffice-bin

# Or with additional languages
bfsos install libreoffice-bin-l10n-en-us
```

### LibreOffice Components

```bash
# Writer (word processor)
libreoffice --writer

# Calc (spreadsheet)
libreoffice --calc

# Impress (presentation)
libreoffice --impress

# Draw (diagramming)
libreoffice --draw

# Base (database)
libreoffice --base

# Math (formula editor)
libreoffice --math
```

### Configuration

```bash
# Launch LibreOffice
libreoffice

# First-run wizard
libreoffice --first-run

# Reset configuration
rm -rf ~/.config/libreoffice
```

### User Profile

```bash
# Profile location
~/.config/libreoffice/4/user/

# Backup profile
cp -r ~/.config/libreoffice ~/libreoffice-backup

# Restore profile
cp -r ~/libreoffice-backup ~/.config/libreoffice
```

### Extensions

```bash
# List installed extensions
unopkg list

# Install extension
unopkg add /path/to/extension.oxt

# Remove extension
unopkg remove extension-id
```

### Default Applications

```bash
# Set LibreOffice as default for document types
xdg-mime default libreoffice-writer.desktop application/vnd.oasis.opendocument.text
xdg-mime default libreoffice-calc.desktop application/vnd.oasis.opendocument.spreadsheet
xdg-mime default libreoffice-impress.desktop application/vnd.oasis.opendocument.presentation
```

### Configuration File

Edit `~/.config/libreoffice/4/user/registrymodifications.xcu` or use the GUI:

```bash
# Open LibreOffice options
libreoffice --options
```

## OnlyOffice

### Installation

```bash
# Install OnlyOffice
bfsos install onlyoffice-desktopeditors
```

### Configuration

```bash
# Launch OnlyOffice
onlyoffice-desktopeditors

# Open document
onlyoffice-desktopeditors /path/to/document.docx
```

### Supported Formats

```bash
# OnlyOffice supports:
# - Microsoft Office formats (.docx, .xlsx, .pptx)
# - OpenDocument formats (.odt, .ods, .odp)
# - PDF files
# - Other formats
```

### Integration

```bash
# Set as default for Microsoft Office formats
xdg-mime default onlyoffice-desktopeditors.desktop application/vnd.openxmlformats-officedocument.wordprocessingml.document
xdg-mime default onlyoffice-desktopeditors.desktop application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
xdg-mime default onlyoffice-desktopeditors.desktop application/vnd.openxmlformats-officedocument.presentationml.presentation
```

## Document Viewers

### Evince (GNOME Document Viewer)

```bash
# Install Evince
bfsos install evince

# Launch Evince
evince /path/to/document.pdf

# Set as default PDF viewer
xdg-mime default evince.desktop application/pdf
```

### Okular (KDE Document Viewer)

```bash
# Install Okular
bfsos install okular

# Launch Okular
okular /path/to/document.pdf

# Set as default PDF viewer
xdg-mime default okular.desktop application/pdf
```

### Configuration

```bash
# Configure Evince
gsettings set org.gnome.Evince.Default auto-reload true

# Configure Okular
# Via GUI: Settings → Configure Okular
```

## Other Office Tools

### AbiWord (Lightweight Word Processor)

```bash
# Install AbiWord
bfsos install abiword

# Launch AbiWord
abiword /path/to/document.odt
```

### Gnumeric (Lightweight Spreadsheet)

```bash
# Install Gnumeric
bfsos install gnumeric

# Launch Gnumeric
gnumeric /path/to/spreadsheet.ods
```

### Pandoc (Document Converter)

```bash
# Install Pandoc
bfsos install pandoc

# Convert document formats
pandoc input.docx -o output.odt
pandoc input.md -o output.pdf
pandoc input.html -o output.docx
```

## Tips

- LibreOffice is the most compatible open-source office suite.
- OnlyOffice provides excellent Microsoft Office compatibility.
- Use `LibreOffice --headless` for batch conversions.
- Consider using online office suites for collaboration.
- Enable spell checking in LibreOffice via Tools → Language.
- Use templates for consistent document formatting.

## Troubleshooting

### LibreOffice Not Starting

1. Check user profile:
   ```bash
   rm -rf ~/.config/libreoffice
   ```

2. Run in safe mode:
   ```bash
   libreoffice --safe-mode
   ```

3. Check dependencies:
   ```bash
   ldd /usr/lib/libreoffice/program/soffice.bin
   ```

### Font Issues

1. Install additional fonts:
   ```bash
   bfsos install ttf-liberation
   bfsos install ttf-dejavu
   bfsos install noto-fonts
   ```

2. Clear font cache:
   ```bash
   fc-cache -fv
   ```

### PDF Generation Issues

1. Check printer configuration:
   ```bash
   lpstat -p
   ```

2. Use alternative PDF generator:
   ```bash
   libreoffice --convert-to pdf document.docx
   ```

## Next Steps

After office suite configuration, proceed to [Chapter 24: Multimedia](chapters/24-multimedia.md) for multimedia applications.
