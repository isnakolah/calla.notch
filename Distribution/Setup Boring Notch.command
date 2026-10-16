#!/bin/zsh
set -u
here="${0:A:h}"
cd "$HOME"
if [[ -d "$here/Boring Notch Setup.app" ]]; then
    /usr/bin/open "$here/Boring Notch Setup.app"
    exit $?
elif [[ -d "$here/boringNotch.app" ]]; then
    "$here/boringNotch.app/Contents/Helpers/boring-notch" setup --package "$here/boringNotch.app"
else
    "$here/../../Helpers/boring-notch" menu
fi
result=$?
printf '\nPress Return to close this window.\n'
read -r
exit "$result"
