#!/bin/sh
set -eu
app_bundle="${0%/Contents/Resources/t1-login.sh}"
exec /usr/bin/open -g -j -a "$app_bundle" --args --background
