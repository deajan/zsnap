#!/usr/bin/env bash

###### ZFS snapshot management script - Samba vfs objects shadow_copy or shadow_copy2 previous versions friendly
PROGRAM="zsnap"
AUTHOR="(L) 2010-2016 by Orsiris de Jong"
CONTACT="http://www.netpower.fr/zsanp - ozy@netpower.fr"
PROGRAM_VERSION=0.9.4
PROGRAM_BUILD=2016031401

MAIL_ALERT_MSG="Warning: Execution of zsnap for $ZFS_VOLUME (pid $SCRIPT_PID) as $LOCAL_USER@$LOCAL_HOST produced some errors."

#### MINIMAL-FUNCTION-SET BEGIN ####

# Environment variables
_DRYRUN=0
_SILENT=0

# Initial error status, logging 'WARN', 'ERROR' or 'CRITICAL' will enable alerts flags
ERROR_ALERT=0
WARN_ALERT=0


## allow debugging from command line with _DEBUG=yes
if [ ! "$_DEBUG" == "yes" ]; then
	_DEBUG=no
	SLEEP_TIME=.1
	_VERBOSE=0
else
	SLEEP_TIME=1
	trap 'TrapError ${LINENO} $?' ERR
	_VERBOSE=1
fi

SCRIPT_PID=$$

LOCAL_USER=$(whoami)
LOCAL_HOST=$(hostname)

## Default log file until config file is loaded
if [ -w /var/log ]; then
	LOG_FILE="/var/log/$PROGRAM.log"
else
	LOG_FILE="./$PROGRAM.log"
fi

## Default directory where to store temporary run files
if [ -w /tmp ]; then
	RUN_DIR=/tmp
elif [ -w /var/tmp ]; then
	RUN_DIR=/var/tmp
else
	RUN_DIR=.
fi


# Default alert attachment filename
ALERT_LOG_FILE="$RUN_DIR/$PROGRAM.last.log"

# Set error exit code if a piped command fails
	set -o pipefail
	set -o errtrace


function Dummy {
	sleep .1
}

function _Logger {
	local svalue="${1}" # What to log to screen
	local lvalue="${2:-$svalue}" # What to log to logfile, defaults to screen value
	echo -e "$lvalue" >> "$LOG_FILE"

	if [ $_SILENT -eq 0 ]; then
		echo -e "$svalue"
	fi
}

function Logger {
	local value="${1}" # Sentence to log (in double quotes)
	local level="${2}" # Log level: PARANOIA_DEBUG, DEBUG, NOTICE, WARN, ERROR, CRITIAL

	# <OSYNC SPECIFIC> Special case in daemon mode we should timestamp instead of counting seconds
	if [ "$sync_on_changes" == "1" ]; then
		prefix="$(date) - "
	else
		prefix="TIME: $SECONDS - "
	fi
	# </OSYNC SPECIFIC>

	if [ "$level" == "CRITICAL" ]; then
		_Logger "$prefix\e[41m$value\e[0m" "$prefix$level:$value"
		ERROR_ALERT=1
		return
	elif [ "$level" == "ERROR" ]; then
		_Logger "$prefix\e[91m$value\e[0m" "$prefix$level:$value"
		ERROR_ALERT=1
		return
	elif [ "$level" == "WARN" ]; then
		_Logger "$prefix\e[93m$value\e[0m" "$prefix$level:$value"
		WARN_ALERT=1
		return
	elif [ "$level" == "NOTICE" ]; then
		_Logger "$prefix$value"
		return
	elif [ "$level" == "DEBUG" ]; then
		if [ "$_DEBUG" == "yes" ]; then
			_Logger "$prefix$value"
			return
		fi
	else
		_Logger "\e[41mLogger function called without proper loglevel.\e[0m"
		_Logger "$prefix$value"
	fi
}

# Portable child (and grandchild) kill function tester under Linux, BSD and MacOS X
function KillChilds {
	local pid="${1}"
	local self="${2:-false}"

	if children="$(pgrep -P "$pid")"; then
		for child in $children; do
			KillChilds "$child" true
		done
	fi

	# Try to kill nicely, if not, wait 30 seconds to let Trap actions happen before killing
	if [ "$self" == true ]; then
		kill -s SIGTERM "$pid" || (sleep 30 && kill -9 "$pid" &)
	fi
	# sleep 30 needs to wait before killing itself
}

function SendAlert {

	local mail_no_attachment=
	local attachment_command=

	if [ "$DESTINATION_MAILS" == "" ]; then
		return 0
	fi

	if [ "$_DEBUG" == "yes" ]; then
		Logger "Debug mode, no warning email will be sent." "NOTICE"
		return 0
	fi

	# <OSYNC SPECIFIC>
	if [ "$_QUICK_SYNC" == "2" ]; then
		Logger "Current task is a quicksync task. Will not send any alert." "NOTICE"
		return 0
	fi
	# </OSYNC SPECIFIC>

	eval "cat \"$LOG_FILE\" $COMPRESSION_PROGRAM > $ALERT_LOG_FILE"
	if [ $? != 0 ]; then
		Logger "Cannot create [$ALERT_LOG_FILE]" "WARN"
		mail_no_attachment=1
	else
		mail_no_attachment=0
	fi
	MAIL_ALERT_MSG="$MAIL_ALERT_MSG"$'\n\n'$(tail -n 50 "$LOG_FILE")
	if [ $ERROR_ALERT -eq 1 ]; then
		subject="Error alert for $INSTANCE_ID"
	elif [ $WARN_ALERT -eq 1 ]; then
		subject="Warning alert for $INSTANCE_ID"
	else
		subject="Alert for $INSTANCE_ID"
	fi

	if [ "$mail_no_attachment" -eq 0 ]; then
		attachment_command="-a $ALERT_LOG_FILE"
	fi
	if type mutt > /dev/null 2>&1 ; then
		cmd="echo \"$MAIL_ALERT_MSG\" | $(type -p mutt) -x -s \"$subject\" $DESTINATION_MAILS $attachment_command"
		Logger "Mail cmd: $cmd" "DEBUG"
		eval $cmd
		if [ $? != 0 ]; then
			Logger "Cannot send alert email via $(type -p mutt) !!!" "WARN"
		else
			Logger "Sent alert mail using mutt." "NOTICE"
			return 0
		fi
	fi

	if type mail > /dev/null 2>&1 ; then
		if [ "$mail_no_attachment" -eq 0 ] && $(type -p mail) -V | grep "GNU" > /dev/null; then
			attachment_command="-A $ALERT_LOG_FILE"
		elif [ "$mail_no_attachment" -eq 0 ] && $(type -p mail) -V > /dev/null; then
			attachment_command="-a $ALERT_LOG_FILE"
		else
			attachment_command=""
		fi
		cmd="echo \"$MAIL_ALERT_MSG\" | $(type -p mail) $attachment_command -s \"$subject\" $DESTINATION_MAILS"
		Logger "Mail cmd: $cmd" "DEBUG"
		eval $cmd
		if [ $? != 0 ]; then
			Logger "Cannot send alert email via $(type -p mail) with attachments !!!" "WARN"
			cmd="echo \"$MAIL_ALERT_MSG\" | $(type -p mail) -s \"$subject\" $DESTINATION_MAILS"
			Logger "Mail cmd: $cmd" "DEBUG"
			eval $cmd
			if [ $? != 0 ]; then
				Logger "Cannot send alert email via $(type -p mail) without attachments !!!" "WARN"
			else
				Logger "Sent alert mail using mail command without attachment." "NOTICE"
				return 0
			fi
		else
			Logger "Sent alert mail using mail command." "NOTICE"
			return 0
		fi
	fi

	if type sendmail > /dev/null 2>&1 ; then
		cmd="echo -e \"Subject:$subject\r\n$MAIL_ALERT_MSG\" | $(type -p sendmail) $DESTINATION_MAILS"
		Logger "Mail cmd: $cmd" "DEBUG"
		eval $cmd
		if [ $? != 0 ]; then
			Logger "Cannot send alert email via $(type -p sendmail) !!!" "WARN"
		else
			Logger "Sent alert mail using sendmail command without attachment." "NOTICE"
			return 0
		fi
	fi

	if type sendemail > /dev/null 2>&1 ; then
		if [ "$SMTP_USER" != "" ] && [ "$SMTP_PASSWORD" != "" ]; then
			SMTP_OPTIONS="-xu $SMTP_USER -xp $SMTP_PASSWORD"
		else
			SMTP_OPTIONS=""
		fi
		$(type -p sendemail) -f $SENDER_MAIL -t $DESTINATION_MAILS -u "$subject" -m "$MAIL_ALERT_MSG" -s $SMTP_SERVER $SMTP_OPTIONS > /dev/null 2>&1
		if [ $? != 0 ]; then
			Logger "Cannot send alert email via $(type -p sendemail) !!!" "WARN"
		else
			Logger "Sent alert mail using sendemail command without attachment." "NOTICE"
			return 0
		fi
	fi

	# If function has not returned 0 yet, assume it's critical that no alert can be sent
	Logger "Cannot send alert (neither mutt, mail, sendmail nor sendemail found)." "ERROR" # Is not marked critical because execution must continue

	# Delete tmp log file
	if [ -f "$ALERT_LOG_FILE" ]; then
		rm "$ALERT_LOG_FILE"
	fi
}

function TrapError {
	local job="$0"
	local line="$1"
	local code="${2:-1}"
	if [ $_SILENT -eq 0 ]; then
		echo -e " /!\ ERROR in ${job}: Near line ${line}, exit code ${code}"
	fi
}

function LoadConfigFile {
	local config_file="${1}"


	if [ ! -f "$config_file" ]; then
		Logger "Cannot load configuration file [$config_file]. Cannot start." "CRITICAL"
		exit 1
	elif [[ "$1" != *".conf" ]]; then
		Logger "Wrong configuration file supplied [$config_file]. Cannot start." "CRITICAL"
		exit 1
	else
		grep '^[^ ]*=[^;&]*' "$config_file" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" # WITHOUT COMMENTS
		# Shellcheck source=./sync.conf
		source "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID"
	fi

	CONFIG_FILE="$config_file"
}

#### MINIMAL-FUNCTION-SET END ####


function TrapStop
{
	Logger "/!\ Manual exit of zsnap script. zfs snapshots may not be mounted." "WARN"
	exit 1
}

function TrapQuit
{
	if [ $ERROR_ALERT -ne 0 ]
	then
		SendAlert
		Logger "Zsnap script finished with errors." "ERROR"
	else
		if [ "$_DEBUG" == "yes" ]
		then
			Logger "Zsnap script finshed." "NOTICE"
		fi
	fi
}

function CheckEnvironment
{
	if ! type -p zfs > /dev/null 2>&1
	then
		Logger "zfs not present. zsnap cannot work." "CRITICAL"
		exit 1
	fi

	if ! type -p zpool > /dev/null 2>&1
	then
		Logger "zpool not present. zsnap cannot work." "CRITICAL"
		exit 1
	fi
}

# Count number of snapshots of $ZFS_VOLUME
function CountSnaps
{
	SNAP_COUNT=$($(which zfs) list -t snapshot -H | grep "^$ZFS_VOLUME@" | wc -l)
	if [ $? != 0 ]
	then
		SNAP_COUNT=0
	fi
	if [ "$_VERBOSE" -ne 0 ]
	then
		Logger "CountSnaps: There are $SNAP_COUNT snapshots in $ZFS_VOLUME" "NOTICE"
		return 0
	fi
}

# Destroys a snapshot given as argument
function DestroySnap
{
	if [ "$USE_SHADOW_COPY2" != "yes" ]
	then
		mountpoint=$(mount | grep $1 | cut -d' ' -f3)
		if [ "$mountpoint" != "" ]
		then
			umount "$mountpoint"
			if [ $? != 0 ]
			then
				Logger "DestroySnap: Cannot unmount snapshot $1 from $mountpoint" "ERROR"
				return 1
			elif [ "$_VERBOSE" -ne 0 ]
			then
				Logger "DestroySnap: Snapshot $1 unmounted from $mountpoint" "NOTICE"
			fi
		fi
	fi

	$(which zfs) destroy $1
	if [ $? != 0 ]
	then
		Logger "DestroySnap: Cannot destroy snapshot $1" "ERROR"
		return 1
	else
	Logger "DestroySnap: Snapshot $1 destroyed" "NOTICE"
	fi

	if [ -d $mountpoint ] && [ "$mountpoint" != "" ]
	then
		rm -r $mountpoint
		if [ $? != 0 ]
		then
			Logger "DestroySnap: Cannot delete mountpoint $mountpoint" "ERROR"
			return 1
		elif [ "$_VERBOSE" -ne 0 ]
		then
			Logger "DestroySnap: Mountpoint $mountpoint deleted" "NOTICE"
		fi
	fi
}

# Destroys oldest snapshot, or destroys all snapshots in volume if argumennt "all" is given
function DestroySnaps
{
	arg="$1"
	destroycount=0
	for snap in $($(which zfs) list -t snapshot -H | grep "^$ZFS_VOLUME@" | cut -f1)
	do
		DestroySnap $snap
		destroycount=$(($destroycount + 1))
		if [ "$arg" == "" ]
		then
			break;
		elif [ "$arg" == "all" ]
		then
			break;
		elif [ $destroycount -ge "$arg" ]
		then
			break;
		fi
	done
}

# Gets disk usage of zpool $ZFS_POOL
function GetZvolUsage
{
	USED_SPACE=$($(which zpool) list -H | grep $ZFS_POOL | cut -f5 | cut -d'%' -f1)
	## Added support for new zfsonlinux 0.6.4 zpool output
	if [ "$USED_SPACE" == "-" ]
	then
		USED_SPACE=$($(which zpool) list -H | grep $ZFS_POOL | cut -f7 | cut -d'%' -f1)
	fi

	if [ $? != 0 ]
	then
		Logger "GetZvolUsage: Cannot get disk usage of pool $ZFS_POOL" "ERROR"
		return 1
	elif [ "$_VERBOSE" -ne 0 ]
	then
		Logger "GetZvolUsage: Disk usage of $ZFS_POOL = $USED_SPACE %" "NOTICE"
	fi
}

# Mounts all current snapshots of $ZFS_VOLUME in samba vfs shadow_copy compatible format
function MountSnaps
{
	zvol_mountpoint=$($(which zfs) get mountpoint $ZFS_VOLUME -H | cut -f3)
	for snap in $($(which zfs) list -t snapshot -H | grep "^$ZFS_VOLUME@" | cut -f1)
	do
		snap_mountpoint=$(echo $snap | cut -d'@' -f2)
		if [ "$(mount | grep $snap_mountpoint | wc -l)" -eq 0 ]
		then
			mkdir -p $zvol_mountpoint/@GMT-$snap_mountpoint
			if [ $? != 0 ]
			then
				Logger "MountSnaps: Cannot create mountpoint directory $zvol_mountpoint/$snap_mountpoint" "ERROR"
				return 1
			elif [ "$_VERBOSE" -ne 0 ]
			then
				Logger "MountSnaps: Created mountpoint directory $zvol_mountpoint/@GMT-$snap_mountpoint" "NOTICE"
			fi
			mount -t zfs $snap $zvol_mountpoint/@GMT-$snap_mountpoint
			if [ $? != 0 ]
			then
				Logger "MountSnaps: Cannot mount $snap on $zvol_mountpoint/@GMT-$snap_mountpoint" "ERROR"
				return 1
			elif [ "$_VERBOSE" -ne 0 ]
			then
				Logger "MountSnaps: Snapshot $snap mounted on $zvol_mountpoint/@GMT-$snap_mountpoint" "NOTICE"
			fi
		fi
	done
}

# Unmounts all snapshots and deletes its mountpoint directories
function UnmountSnaps
{
	for mountpoint in $(mount | grep "^$ZFS_VOLUME@" | cut -d' ' -f3)
	do
		umount "$mountpoint"
		if [ $? != 0 ]
		then
			Logger "UnmountSnaps: Cannot unmount $mountpoint" "ERROR"
		elif [ "$_VERBOSE" -ne 0 ]
		then
			Logger "UnmountSnaps: $mountpoint unmounted" "NOTICE"
		fi

		rm -r "$mountpoint"
		if [ $? != 0 ]
		then
			Logger "UnmountSnaps: Cannot delete mountpoint $mountpoint" "ERROR"
		elif [ "$_VERBOSE" -ne 0 ]
		then
			Logger "UnmountSnaps: Mountpoint $mountpoint deleted" "NOTICE"
		fi
	done
}

# Creates a new snapshot. Unmounts snapshots before creation and remounts them afterwards so snapshot mountpoints won't be snapshotted
function CreateSnap
{
	if [ "$USE_SHADOW_COPY2" == "no" ]
	then
		UnmountSnaps
	fi
	if [ "$USE_UTC" != "no" ]
	then
		SNAP_TIME=$(date -u +%Y.%m.%d-%H.%M.%S)
	else
		SNAP_TIME=$(date +%Y.%m.%d-%H.%M.%S)
	fi
	$(which zfs) snapshot $ZFS_VOLUME@$SNAP_TIME
	if [ $? != 0 ]
	then
		Logger "CreateSnap: Cannot create snapshot $ZFS_VOLUME@$SNAP_TIME" "ERROR"
		return 1
	fi
	Log "CreateSnap: Snapshot $ZFS_VOLUME@$SNAP_TIME created"
	if [ "$USE_SHADOW_COPY2" == "no" ]
	then
		MountSnaps
	fi
}

# Does the same as CreateSnap, but verifies enforcing parameters first
function VerifyParamsAndCreateSnap
{
	max_space_reached=0
	GetZvolUsage
	CountSnaps
	if [ "$_VERBOSE" -ne 0 ]
	then
		Logger "There are currently $SNAP_COUNT snapshots on volume $ZFS_VOLUME for $USED_SPACE % disk usage" "NOTICE"
	fi

	while [ $MAX_SNAPSHOTS -lt $SNAP_COUNT ]
	do
		DestroySnaps
		CountSnaps
	done

	while [ $MAX_SPACE -lt $USED_SPACE ] && [ $SNAP_COUNT -ge $MIN_SNAPSHOTS ]
	do
		DestroySnaps
		GetZvolUsage
		CountSnaps
		max_space_reached=1
	done

	if [ "$_VERBOSE" -ne 0 ]
	then
		Logger "After enforcing, there are $SNAP_COUNT snapshots on volume $ZFS_VOLUME for $USED_SPACE % disk usage" "NOTICE"
	fi

	if [ $max_space_reached -eq 1 ]
	then
		Logger "$MAX_SPACE disk usage was reached." "WARN"
	fi

	CreateSnap
}

function Status
{
	echo "zsnap $ZSNAP_VERSION status"
	echo ""
	GetZvolUsage
	CountSnaps
	echo "Number of snapshots (min < actual < max): $MIN_SNAPSHOTS < $SNAP_COUNT < $MAX_SNAPSHOTS"
	echo "Disk usage: $ZFS_POOL: $USED_SPACE %"
	if [ "$_VERBOSE" -ne 0 ]
	then
		echo ""
		echo "Snapshot list"
		for snap in $($(which zfs) list -t snapshot -H | grep "^$ZFS_VOLUME@" | cut -f1)
		do
			echo "$snap"
		done
	fi
}

function Init
{
	set -o pipefail
	set -o errtrace

	trap TrapStop SIGINT SIGQUIT SIGTERM SIGHUP
	trap TrapQuit EXIT

	ZFS_POOL=$(echo $ZFS_VOLUME | cut -d'/' -f1)
	if [ -w /var/log ]; then
		LOG_FILE="/var/log/zsnap_${ZFS_VOLUME##*/}.log"
	else
		LOG_FILE="./zsnap.${ZFS_VOLUME##*/}.log"
	fi
}

function Usage
{
	echo "$PROGRAM $PROGRAM_VERSION $PROGRAM_BUILD"
	echo "$AUTHOR"
	echo "$CONTACT"
	echo ""
	echo "Manages snapshot of a given dataset and mounts them as subdirectories of dataset."
	echo ""
	echo "Usage: zsnap /path/to/snapshot.conf [status|createsimple|create|destroyoldest|destroyall|destroy zvolume@YYYY.MM.DD-HH.MM.SS|mount|umount] [--silent] [--verbose]"
	echo
	echo "status - List status info"
	echo "createsimple - Will create a snapshot and mount it without any prior checks."
	echo "create - Will verifiy number of snapshots, destroy them until there are less than SNAPMAX, keeping at least SNAPMIN depending of disk usage, then create a new snapshot."
	echo "destroyoldest - Will destroy the oldest snapshot of the dataset."
	echo "destroyall - Will destroy all snapshots of the dataset."
	echo "destroy yourdataset@YYYY.MM.DD-HH.MM.SS - Will destroy a given snapshot."
	echo "destroy XX - Will destroy XX oldest snapshots."
	echo "mount - (does not apply to shadow_copy2 use) Mounts all snapshots. Mounting is automatic, this is only needed in case of a recovery."
	echo "umount - (does not apply to shadow_copy2 use) Unmounts all snapshots. Unmounting is automatic, this is only needed in case of a recovery."
	echo
	echo "--silent - Will run Zsnap without any output to stdout. Usefull for cron tasks."
	echo "--verbose - Will add function output."
	exit 128
}

for i in "$@"
do
	case $i in
		--silent)
		_SILENT=1
		;;
		--verbose)
		_VERBOSE=1
		;;
		--help|-h)
		Usage
		;;
	esac
done

CheckEnvironment
if [ $? == 0 ]
then
	if [ "$1" != "" ]
	then
		LoadConfigFile "$1"
		if [ $? == 0 ]
		then
			Init
			case "$2" in
				destroyoldest)
				DestroySnaps
				;;
				destroyall)
				DestroySnaps all
				;;
				create)
				VerifyParamsAndCreateSnap
				;;
				createsimple)
				CreateSnap
				;;
				status)
				Status
				;;
				mount)
				MountSnaps
				;;
				umount)
				UnmountSnaps
				;;
				destroy)
				if [ "$3" != "" ]
				then
					if [[ "$3" == *"@"* ]]
					then
						DestroySnap "$3"
					else
						DestroySnaps "$3"
					fi
				else
					Usage
				fi
				;;
				*)
				Usage
				;;
			esac
		else
			Logger "Configuration file could not be loaded." "CRITICAL"
			exit 1
		fi
	else
		Logger "No configuration file provided." "CRITICAL"
		exit 1
	fi
fi
