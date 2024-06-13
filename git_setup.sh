#!/bin/bash

##############################################################################
#
#  Program :	GitSet v1
#  Arch    :	x86_64 
#  Author  : 	StormOS-Dev
#  Website : 	https://sourceforge.net/projects/hackman-linux/
#
##############################################################################

_msg() {
    printf "\n"
    term_cols=$(tput cols)
    str="$1"
    tput setaf 5; printf '%*s\n' "${term_cols}" '' | tr ' ' - ; tput sgr0
    tput setaf 4; printf "%*s\n" $(((${#str}+$term_cols)/2)) "$str"; tput sgr0
    tput setaf 5; printf '%*s\n' "${term_cols}" '' | tr ' ' - ; tput sgr0
}

_msg "Setting up Git Repository!"

git init
git config --global user.name "bfitzgit23"
git config --global user.email "dfitz@me.com"
sudo git config --system core.editor nano
git config --global credential.helper cache
git config --global credential.helper 'cache --timeout=25000'
git config --global push.default simple

_msg "Git Repository Setup Complete!"
