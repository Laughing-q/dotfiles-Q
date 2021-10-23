#!/bin/sh
configfile=$(ls -l .config | awk '/^d/ {print $9}')

homeconfig="$HOME/.config"
bkconfig="$HOME/.config/backup"
dotconfig="./.config"

# if [[ ! (-d $bkconfig) ]]; then
#   mkdir -p $bkconfig
# fi

[[ -d $bkconfig ]] && echo "backup dir $bkconfig existed, remove it." && rm -r "$bkconfig"
mkdir -p $bkconfig

for c in $configfile; do
	[[ -d "$homeconfig/$c" ]] && echo "backup $homeconfig/$c to $bkconfig/$c.bk" && cp -r "$homeconfig/$c" "$bkconfig/$c.bk" && rm -r "$homeconfig/$c"

	[[ -d "$dotconfig/$c" ]] && echo "update $dotconfig/$c to $homeconfig/$c" && cp -r "$dotconfig/$c" "$homeconfig"

done

[[ -d "$HOME/.config/mpd" ]] && 
  touch "$HOME/.config/mpd/state" "$HOME/.config/mpd/pid" \
  "$HOME/.config/mpd/log" "$HOME/.config/mpd/database"
