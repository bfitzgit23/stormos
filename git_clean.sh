#!/bin/bash

##############################################################################
#
#  Program :	Clean_Up v1
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

_msg "Cleaning up repo..."

mv .git/config config
rm -rf .git
sh ./git_setup*
mv config .git/config
git add --all .
git commit -m "Initialise Repo"
git push origin master --force

_msg "Clean up completed..."
