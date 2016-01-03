#!/bin/sh
##
## Ad-hoc backup tool
## Copyright (c) 2007-2012 SATOH Fumiyasu @ OSS Technology Corp., Japan
##               <http://www.OSSTech.co.jp/>
##
## License: GNU General Public License version 3
## Date: 2012-07-23, since 2005-05-23
##

set -e
set -u
umask 0027

LC_ALL="C"
PATH="/opt/osstech/bin:/usr/xpg4/bin:/bin:/usr/bin"
export LC_ALL PATH

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
  [ "$#" -lt 1 ] && return 0
  [ -n "${verbose_flag-}" ] && pinfo "run: $*"
  ${1+"$@"}
  return $?
}

run_if()
{
  [ "$#" -lt 2 ] && return 0
  [ -n "${verbose_flag-}" ] && (shift; pinfo "run: $*")
  [ -z "${1-}" ] && return 0
  shift
  ${1+"$@"}
  return $?
}

## Options
## ======================================================================

date="`date "+%Y%m%d%H%M"`"

verbose_flag=""
run_flag="yes"
backup_max_age="30"
rsync_command="${RSYNC:-rsync}"
rsync_options=""
date_dir_re='^[1-9][0-9][0-9][0-9][0-1][0-9][0-3][0-9][0-2][0-9][0-5][0-9]/$'

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
    verbose_flag="yes"
    ;;
  n)
    run_flag=""
    ;;
  r)
    root="$OPTARG"
    ;;
  a)
    backup_max_age="$OPTARG"
    ;;
  *)
    exit 1
    ;;
  esac
done
shift `expr $OPTIND - 1 || :`

[ -n "$run_flag" ] || no_run_flag="yes"

if [ "$#" -ne 1 ]; then
  echo "$cmd_usage"
  exit 0
fi

config_file="$1"; shift

. "$config_file"

[ -n "$backup_targets" ] || pdie "No backup_targets in config file: $config_file"
[ -n "$backup_directory" ] || pdie "No backup_directory in config file: $config_file"
[ -d "$backup_directory" ] || pdie "Backup directory not found: $backup_directory"

## ======================================================================

dst_dir="$backup_directory/$date"

dst_dir_prev=""
date_prev="`ls -F "$backup_directory/" |grep "$date_dir_re" |sort -n |sed -n '$s#/$##p'`"
if [ -n "$date_prev" ] && [ x"$date_prev" != x"$date" ]; then
  dst_dir_prev="$backup_directory/$date_prev"
fi

## Remove comments in $backup_targets
backup_targets="`echo "$backup_targets" |grep -v '^[ 	]*#'`"

## Expand file glob(3) in $backup_targets
src_list=""
for src in $backup_targets; do
  if command test -e "$src"; then
    : OK
  else
    pwarn "Target not found: $src"
    continue
  fi
  src_list="$src_list $src"
done
if [ -z "$src_list" ]; then
  pdie "No targets found"
fi

## Do backup by rsync
## ----------------------------------------------------------------------

run "$rsync_command" \
  ${verbose_flag:+--verbose} \
  ${no_run_flag:+--dry-run} \
  --archive \
  --hard-links \
  --relative \
  --delete \
  --delete-excluded \
  --exclude ".??*.sw?" \
  ${dst_dir_prev:+--link-dest} ${dst_dir_prev:+"$dst_dir_prev"} \
  $rsync_options \
  $src_list \
  "$dst_dir"

## Expires old backups
## ----------------------------------------------------------------------

if [ "$backup_max_age" -le 0 ]; then
  exit 0
fi

ls -F "$backup_directory" \
|grep "$date_dir_re" \
|sed 's#/$##' \
|sort -nr \
|grep -v "^$date$" \
|tail -n +"$backup_max_age" \
|while read date; do
  run_if "$run_flag" rm -rf "$backup_directory/$date"
done

