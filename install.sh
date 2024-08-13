#!/bin/bash

set -euo pipefail
bkconfig="$HOME/.config/backup"
homeconfig="$HOME/.config"

if [[ "$#" != 0 ]]; then
	[[ -d $bkconfig ]] || mkdir -p $bkconfig

	for i; do
		[[ -d $i ]] || (echo "\"$i\" does not exist." && exit 1)
		name="$(echo $i | cut -d '/' -f2)"
		bk="$bkconfig/$name.bk"
		origin="$homeconfig/$name"
		if [[ -d "$origin" ]]; then
			[[ -d $bk ]] && rm -r $bk
			echo "backup $origin to $bk" &&
				mv "$origin" "$bk"
		fi
		echo "update $i to $origin" &&
			cp -r "$i" "$homeconfig"
	done
	exit 0

fi

configfile=$(ls -l .config | awk '/^d/ {print $9}')
# configfile=$(find .config -type d)
# echo $configfile

dotconfig="./.config"

# if [[ ! (-d $bkconfig) ]]; then
#   mkdir -p $bkconfig
# fi

[[ -d $bkconfig ]] && echo "backup dir $bkconfig existed, remove it." && rm -r "$bkconfig"
mkdir -p $bkconfig

for c in $configfile; do
	[[ -d "$homeconfig/$c" ]] && echo "backup $homeconfig/$c to $bkconfig/$c.bk" &&
		mv "$homeconfig/$c" "$bkconfig/$c.bk"

	[[ -d "$dotconfig/$c" ]] && echo "update $dotconfig/$c to $homeconfig/$c" &&
		cp -r "$dotconfig/$c" "$homeconfig"

done

[[ -d "$HOME/.config/mpd" ]] &&
	touch "$HOME/.config/mpd/state" "$HOME/.config/mpd/pid" \
		"$HOME/.config/mpd/log" "$HOME/.config/mpd/database"
