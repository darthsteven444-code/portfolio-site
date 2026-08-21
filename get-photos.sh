#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
mkdir -p public/photos
B="https://commons.wikimedia.org/wiki/Special:FilePath"
declare -A P=(
 [navy-watch]="US_Navy_071106-N-7981E-172_Gas_Turbine_Systems_Technician_(Electrical)_3rd_Class_Chris_Withers_monitors_the_ship%27s_online_generators_while_standing_watch_at_the_electrical_plant_control_console_in_damage_control_central.jpg"
 [navy-turbine]="US_Navy_110215-N-9793B-015_Sailors_check_a_gas_turbine_engine_aboard_the_guided-missile_cruiser_USS_Anzio_(CG_68).jpg"
 [navy-maint]="US_Navy_110716-N-DU438-077_Gas_Turbine_System_Technician_(Mechanical)_2nd_Class_Terence_Erroch_performs_maintenance_on_a_gas_turbine_engine_aboard.jpg"
)
for k in "${!P[@]}"; do
  echo "fetching $k ..."
  curl -sL -A "Mozilla/5.0" "$B/${P[$k]}?width=2000" -o "/tmp/$k.jpg"
  ls -la "/tmp/$k.jpg"
  if command -v cwebp >/dev/null; then
    cwebp -q 82 -resize 2000 0 "/tmp/$k.jpg" -o "public/photos/$k.webp" >/dev/null
  else
    convert "/tmp/$k.jpg" -resize 2000x -quality 82 "public/photos/$k.webp"
  fi
  rm -f "/tmp/$k.jpg"
done
echo "--- result ---"
ls -la public/photos/
