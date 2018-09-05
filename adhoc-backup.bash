#!/bin/bash
##
## Ad-hoc backup tool using rsync --link-dest
## Copyright (c) 2007-2018 SATOH Fumiyasu @ OSS Technology Corp., Japan
##               <https://GitHub.com/fumiyas/adhoc-backup>
##               <https://www.OSSTech.co.jp/>
##
## License: GNU General Public License version 3
##

set -e
set -u
umask 0027

LC_ALL="C"
export LC_ALL

renice 1 "$$" >/dev/null 2>&1 || :
ionice -c 2 -n 5 -p "$$" >/dev/null 2>&1 || :

pinfo()
{
  echo "$0: INFO: $*" 1>&2
}

pwarn()
{
  echo "$0: WARNING: $*" 1>&2
}

perr()
{
  echo "$0: ERROR: $*" 1>&2
}

pdie()
{
  perr "$*"
  exit 1
}

run()
{
  [[ $# -lt 1 ]] && return 0
  [[ -n ${verbose_flag-} ]] && pinfo "run: $*"
  ${1+"$@"}
  return $?
}

run_if()
{
  [[ $# -lt 2 ]] && return 0
  [[ -n ${verbose_flag-} ]] && (shift; pinfo "run: $*")
  [[ -z ${1-} ]] && return 0
  shift
  ${1+"$@"}
  return $?
}

## Options
## ======================================================================

date=$(date "+%Y%m%d.%H")

verbose_flag=""
run_flag="set"
backup_target_host=""
backup_excludes=()
backup_directory=""
backup_max_age="30"
rsync_path="${RSYNC:-rsync}"
ssh_path="${SSH:-ssh}"
ssh_id_file=""
ssh_options=(
  -o 'ServerAliveInterval 60'
)
date_dir_re='[1-9][0-9][0-9][0-9][0-1][0-9][0-3][0-9]\.[0-2][0-9]'

cmd_usage="Usage: $0 [OPTIONS] CONFIG_FILE

Options:
  -v
    Verbose output
  -n
    Dry run
"

## ----------------------------------------------------------------------

while getopts vna: opt; do
  case "$opt" in
  v)
    verbose_flag="set"
    ;;
  n)
    run_flag=""
    ;;
  a)
    backup_max_age="$OPTARG"
    ;;
  *)
    exit 1
    ;;
  esac
done
shift $((OPTIND - 1))

[[ -n $run_flag ]] || no_run_flag="set"

if [[ $# -ne 1 ]]; then
  echo "$cmd_usage"
  exit 0
fi

config_file="$1"; shift

. "$config_file" || pdie "Loading config file failed: $config_file"

## Old adhoc-backup.conf compatilibity
## ----------------------------------------------------------------------

if [[ -n ${backup_targets+set} ]]; then
  if [[ "$(declare -p backup_targets)" == "declare -- "* ]]; then
    backup_targets=($backup_targets)
  fi
else
  backup_targets=()
fi

if [[ -n ${rsync_options+set} ]]; then
  if [[ $(declare -p rsync_options) == "declare -- "* ]]; then
    rsync_options=($rsync_options)
  fi
else
  rsync_options=()
fi

if [[ -n ${rsync_command+set} ]]; then
  rsync_path="$rsync_command"
fi

## ----------------------------------------------------------------------

[[ ${#backup_targets[@]} -eq 0 ]] && pdie "No backup_targets in config file: $config_file"
[[ -n $backup_directory ]] || pdie "No backup_directory in config file: $config_file"
[[ -d $backup_directory ]] || pdie "Backup directory not found: $backup_directory"

## ======================================================================

backup_date_dir="$backup_directory/$date"
backup_latest_link="$backup_directory/latest"

for backup_exclude in ${backup_excludes[@]+"${backup_excludes[@]}"}; do
  rsync_options+=(--exclude "$backup_exclude")
done

if [[ -n $backup_target_host ]]; then
  for ((i = 0; i < ${#ssh_options[@]}; i++)); do
    ssh_options[$i]="\"${ssh_options[$i]}\""
  done
  rsync_options=(
    --rsh "$ssh_path ${ssh_id_file:+ -i '$ssh_id_file'} ${ssh_options[*]-}"
    ${rsync_options[@]+"${rsync_options[@]}"}
  )
  for ((i = 0; i < ${#backup_targets[@]}; i++)); do
    if [[ ${backup_targets[$i]} != /* ]]; then
      ## rsync server over ssh
      backup_targets[$i]=":${backup_targets[$i]}"
    fi
    backup_targets[$i]="$backup_target_host:${backup_targets[$i]}"
  done
fi

if [[ -d $backup_latest_link ]]; then
  backup_prev_dir="$backup_latest_link"
else
  date_prev=$(
    ls -F "$backup_directory/" \
    |grep -- "^$date_dir_re/\$" \
    |grep -v "^${date//./\\.}/\$" \
    |sort \
    |sed -n '$s#/$##p'
  )
  backup_prev_dir="${date_prev:+$backup_directory/$date_prev}"
fi

## Do backup by rsync
## ----------------------------------------------------------------------

run "$rsync_path" \
  ${verbose_flag:+--verbose} \
  ${verbose_flag:+--stats} \
  ${no_run_flag:+--dry-run} \
  --archive \
  --omit-dir-times \
  --hard-links \
  --relative \
  --delete \
  --delete-excluded \
  ${backup_prev_dir:+--link-dest "$backup_prev_dir"} \
  ${rsync_options[@]+"${rsync_options[@]}"} \
  "${backup_targets[@]}" \
  "$backup_date_dir" \
|| {
  rc="$?"
  mv "$backup_date_dir" "$backup_date_dir.incomplete"
  pdie "rsync command failed ($rc)"
}

run_if "$run_flag" rm -f "$backup_latest_link" \
&& run_if "$run_flag" ln -s "$date" "$backup_latest_link" \
|| pdie "Cannot update link for latest backup: $backup_latest_link"

## Expires old backups
## ----------------------------------------------------------------------

if [[ $backup_max_age -le 0 ]]; then
  exit 0
fi

ls -F "$backup_directory" \
|grep "^$date_dir_re/\$" \
|sed 's#/$##' \
|sort -r \
|grep -v "^$date$" \
|tail -n +"$backup_max_age" \
|while read date; do
  run_if "$run_flag" rm -rf "$backup_directory/$date"
done
