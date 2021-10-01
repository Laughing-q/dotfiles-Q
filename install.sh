configfile=$(ls -l .config | awk '/^d/ {print $9}')

homeconfig="$HOME/.config"
bkconfig="$HOME/.config/backup"
dotconfig="./.config"

if [[ ! (-d $bkconfig) ]]; then
  mkdir -p $bkconfig
fi

for c in $configfile
do
  if [[ -d "$homeconfig/$c" ]]; then
    echo "backup $homeconfig/$c to $bkconfig/$c.bk"
    cp -r "$homeconfig/$c" "$bkconfig/$c.bk"
    rm -r "$homeconfig/$c"
  fi

  if [[ -d "$dotconfig/$c" ]]; then
    echo "update $dotconfig/$c to $homeconfig/$c"
    cp -r "$dotconfig/$c" "$homeconfig"
  fi
done
