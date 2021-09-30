xmodmap ~/.config/zsh/.xmodmap
/* export PATH=$PATH:/home/laughing/.local/bin */

picom -b &
wal -i /home/laughing/Pictures/DT/0026.jpg > /dev/null &

fcitx &
dunst &

exec dwm
