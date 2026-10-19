#!/bin/zsh
set -u
here="${0:A:h}"
cd "$HOME"
if [[ -d "$here/calla.notch Setup.app" ]]; then
    /usr/bin/open "$here/calla.notch Setup.app"
    exit $?
elif [[ -d "$here/calla.notch.app" ]]; then
    "$here/calla.notch.app/Contents/Helpers/calla-notch" setup --package "$here/calla.notch.app"
else
    "$here/../../Helpers/calla-notch" menu
fi
result=$?
printf '\nPress Return to close this window.\n'
read -r
exit "$result"
