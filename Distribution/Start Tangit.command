#!/bin/zsh
set -u
cd "$HOME"
helper='/Applications/boringNotch.app/Contents/Helpers/boring-notch'
if [[ -x "$helper" ]]; then
  "$helper" tangit
else
  print 'Run Setup Boring Notch.command first to install Tangit and its tools.'
fi
print '\nPress Return to close.'
read -r
