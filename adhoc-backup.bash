#!/bin/bash
##
## Ad-hoc backup tool using rsync --link-dest
## Copyright (c) 2007-2015 SATOH Fumiyasu @ OSS Technology Corp., Japan
##               <https://GitHub.com/fumiyas/adhoc-backup>
##               <http://www.OSSTech.co.jp/>
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
backup_targets=()
backup_excludes=()
backup_directory=""
backup_max_age="30"
rsync_path="${RSYNC:-rsync}"
rsync_options=()
date_dir_re='^[1-9][0-9][0-9][0-9][0-1][0-9][0-3][0-9]\.[0-2][0-9]/$'

cmd_usage="Usage: $0 [OPTIONS] CONFIG_FILE

Options:
  -v
    Verbose output
  -n
    Dry run
"

## ----------------------------------------------------------------------

while getopts vnr:a: opt; do
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

. "$config_file"

[[ -n ${#backup_targets[@]} ]] || pdie "No backup_targets in config file: $config_file"
[[ -n $backup_directory ]] || pdie "No backup_directory in config file: $config_file"
[[ -d $backup_directory ]] || pdie "Backup directory not found: $backup_directory"

## ======================================================================

backup_date_dir="$backup_directory/$date"
backup_latest_link="$backup_directory/latest"

for backup_exclude in "${backup_excludes[@]}"; do
  rsync_options=(
    "${rsync_options[@]}"
    --exclude "$backup_exclude"
  )
done

dst_dir_prev=""
date_prev=$(
  ls -F "$backup_directory/" \
  |grep -- "$date_dir_re" \
  |sort \
  |sed -n '$s#/$##p'
)
if [[ -n $date_prev && $date_prev != "$date" ]]; then
  dst_dir_prev="$backup_directory/$date_prev"
fi

## Do backup by rsync
## ----------------------------------------------------------------------

run "$rsync_path" \
  ${verbose_flag:+--verbose} \
  ${no_run_flag:+--dry-run} \
  --archive \
  --omit-dir-times \
  --hard-links \
  --relative \
  --delete \
  --delete-excluded \
  ${dst_dir_prev:+--link-dest "$dst_dir_prev"} \
  "${rsync_options[@]}" \
  "${backup_targets[@]}" \
  "$backup_date_dir" \
|| pdie "rsync command failed: $?" \
;

rm -f "$backup_latest_link" \
&& ln -s "$date" "$backup_latest_link" \
|| pdie "Cannot update link for latest backup: $backup_latest_link"

## Expires old backups
## ----------------------------------------------------------------------

if [[ $backup_max_age -le 0 ]]; then
  exit 0
fi

ls -F "$backup_directory" \
|grep "$date_dir_re" \
|sed 's#/$##' \
|sort -r \
|grep -v "^$date$" \
|tail -n +"$backup_max_age" \
|while read date; do
  run_if "$run_flag" rm -rf "$backup_directory/$date"
done

