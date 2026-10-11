# Chapter 26: Development Tools

## Overview

Development tools provide code editing, version control, compilation, and debugging capabilities. This chapter covers installing and configuring development tools on StormFS Linux.

## Prerequisites

Before installing development tools, ensure the following are configured:

- Basic system installation ([Chapter 2: Installation](chapters/02-installation.md))

## Git

### Installation

```bash
# Install Git
bfsos install git
```

### Configuration

```bash
# Set global user name
git config --global user.name "Your Name"

# Set global email
git config --global user.email "your.email@example.com"

# Set default editor
git config --global core.editor vim

# Set default branch name
git config --global init.defaultBranch main

# Enable color output
git config --global color.ui auto

# View configuration
git config --list
```

### SSH Keys

```bash
# Generate SSH key
ssh-keygen -t ed25519 -C "your.email@example.com"

# Add to SSH agent
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519

# Copy public key to clipboard
cat ~/.ssh/id_ed25519.pub | clip
```

### Git Aliases

```bash
# Create useful aliases
git config --global alias.st status
git config --global alias.co checkout
git config --global alias.br branch
git config --global alias.ci commit
git config --global alias.lg "log --oneline --graph --all"
git config --global alias.last "log -1 HEAD"
git config --global alias.unstage "reset HEAD --"
```

## VS Code

### Installation

```bash
# Install VS Code
bfsos install visual-studio-code

# Or open source version
bfsos install code-oss
```

### Configuration

```bash
# Launch VS Code
code

# Open specific folder
code /path/to/project

# Install extensions from command line
code --install-extension ms-python.python
code --install-extension ms-vscode.cpptools
code --install-extension vadimcn.vscode-lldb
```

### Recommended Extensions

```bash
# Python
code --install-extension ms-python.python

# C/C++
code --install-extension ms-vscode.cpptools

# Rust
code --install-extension rust-lang.rust-analyzer

# Go
code --install-extension golang.go

# JavaScript/TypeScript
code --install-extension dbaeumer.vscode-eslint

# Git
code --install-extension eamodio.gitlens

# Remote Development
code --install-extension ms-vscode-remote.vscode-remote-pack
```

### Settings

```json
// ~/.config/Code/User/settings.json
{
    "editor.fontSize": 14,
    "editor.tabSize": 4,
    "editor.formatOnSave": true,
    "editor.minimap.enabled": false,
    "workbench.colorTheme": "Default Dark Modern",
    "terminal.integrated.fontSize": 12,
    "files.autoSave": "afterDelay"
}
```

## GCC/G++ Extras

### Installation

```bash
# Install GCC and G++
bfsos install gcc gcc-g++

# Additional tools
bfsos install binutils make autoconf automake
```

### Configuration

```bash
# Check GCC version
gcc --version

# Check G++ version
g++ --version

# Compile C program
gcc -o output input.c

# Compile C++ program
g++ -o output input.cpp

# With warnings
gcc -Wall -Wextra -o output input.c

# With optimization
gcc -O2 -o output input.c
```

### Cross-Compilation

```bash
# Install cross-compilation tools
bfsos install gcc-cross

# Cross-compile for different architecture
gcc -march=armv7-a -mfloat-abi=hard -mfpu=neon -o output input.c
```

## Make/CMake

### Make

```bash
# Install Make
bfsos install make

# Use Makefile
make

# Clean build
make clean

# Install
make install

# Specific target
make target
```

### CMake

```bash
# Install CMake
bfsos install cmake

# Create build directory
mkdir build && cd build

# Configure
cmake ..

# Build
make

# Install
make install
```

### CMakeLists.txt Example

```cmake
cmake_minimum_required(VERSION 3.10)
project(MyProject)

set(CMAKE_CXX_STANDARD 17)

add_executable(myapp main.cpp)

target_link_libraries(myapp pthread)
```

## Debugging

### GDB

```bash
# Install GDB
bfsos install gdb

# Compile with debug symbols
gcc -g -o output input.c

# Debug program
gdb output

# Common GDB commands
# break main: set breakpoint at main
# run: start program
# next: step over
# step: step into
# print variable: print variable value
# backtrace: show call stack
# quit: exit GDB
```

### Strace

```bash
# Install strace
bfsos install strace

# Trace system calls
strace ./program

# Trace specific syscalls
strace -e trace=open,read,write ./program

# Trace and save to file
strace -o output.txt ./program
```

### Valgrind

```bash
# Install Valgrind
bfsos install valgrind

# Memory check
valgrind --leak-check=full ./program

# Cache profiling
valgrind --tool=cachegrind ./program

# Call profiling
valgrind --tool=callgrind ./program
```

## Version Control Workflows

### Git Flow

```bash
# Install git-flow
bfsos install git-flow

# Initialize
git flow init

# Start feature
git flow feature start my-feature

# Finish feature
git flow feature finish my-feature

# Start release
git flow release start 1.0.0

# Finish release
git flow release finish 1.0.0
```

### GitHub CLI

```bash
# Install GitHub CLI
bfsos install github-cli

# Login
gh auth login

# Create repository
gh repo create my-repo --public

# Create pull request
gh pr create --title "My PR" --body "Description"

# List issues
gh issue list
```

## Tips

- Use `git commit -m "message"` for quick commits.
- Use `.gitignore` to exclude files from version control.
- Use `tmux` or `screen` for persistent terminal sessions.
- Consider using `ccache` for faster recompilation.
- Use `make -j$(nproc)` for parallel compilation.
- Set up a proper `.editorconfig` for consistent coding style.

## Troubleshooting

### Git Authentication Issues

1. Check SSH key:
   ```bash
   ssh -T git@github.com
   ```

2. Configure credential helper:
   ```bash
   git config --global credential.helper cache
   ```

### Compilation Errors

1. Check dependencies:
   ```bash
   pkg-config --list-all
   ```

2. Check include paths:
   ```bash
   echo | gcc -E -Wp,-v - x
   ```

### Debugger Issues

1. Ensure debug symbols are included:
   ```bash
   gcc -g -o output input.c
   ```

2. Check GDB version:
   ```bash
   gdb --version
   ```

## Next Steps

After development tools setup, proceed to [Chapter 27: System Utilities](chapters/27-utilities.md) for system utilities.
