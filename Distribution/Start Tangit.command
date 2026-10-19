#!/bin/zsh
set -u
cd "$HOME"
helper='/Applications/calla.notch.app/Contents/Helpers/calla-notch'
if [[ -x "$helper" ]]; then
  "$helper" tangit
else
  print 'Run Setup calla.notch.command first to install Tangit and its tools.'
fi
print '\nPress Return to close.'
read -r
