#!/bin/sh
# Adapts the stock Linux / macOS install scripts to SecureDesk:
#  * install folder /usr/local/bin/SecureDesk (instead of /usr/local/bin/Remotely)
#  * log file /tmp/SecureDesk_Install.log
#  * an older installation in /usr/local/bin/Remotely is migrated (the device id is kept) and its folder removed
# Usage: patch-install-scripts.sh <Content folder>
set -e
cd "$1"
for f in Install-Ubuntu-x64.sh Install-Manjaro-x64.sh Install-MacOS-x64.sh Install-MacOS-arm64.sh; do
    sed -i 's/\r$//' "$f"
    sed -i 's#/usr/local/bin/Remotely#/usr/local/bin/SecureDesk#g; s#/tmp/Remotely_Install.log#/tmp/SecureDesk_Install.log#g' "$f"
    awk '
    /^ *rm -r -f \/usr\/local\/bin\/SecureDesk\/?$/ {
        print
        match($0, /^ */)
        print substr($0, 1, RLENGTH) "rm -r -f /usr/local/bin/Remotely"
        next
    }
    /ConnectionInfo.json" \]; then$/ && !done {
        print "# an older installation lived in /usr/local/bin/Remotely: carry its device id over"
        print "if [ -f \"/usr/local/bin/Remotely/ConnectionInfo.json\" ] && [ ! -f \"/usr/local/bin/SecureDesk/ConnectionInfo.json\" ]; then"
        print "    mkdir -p /usr/local/bin/SecureDesk"
        print "    cp /usr/local/bin/Remotely/ConnectionInfo.json /usr/local/bin/SecureDesk/ConnectionInfo.json"
        print "fi"
        print ""
        done = 1
    }
    { print }' "$f" > "$f.new"
    mv "$f.new" "$f"
done
