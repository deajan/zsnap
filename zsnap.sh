#!/bin/bash

###### ZFS snapshot management script - Samba vfs objects shadow_copy or shadow_copy2 previous versions friendly
###### Written in 2010-2013 by Orsiris "Ozy" de Jong (www.netpower.fr)

ZSNAP_VERSION=0.9 #### Build 2808201301

## Default log file if configuration file is not loaded
LOG_FILE=/var/log/zsnap.log
DEBUG=no
SCRIPT_PID=$$


LOCAL_USER=$(whoami)
LOCAL_HOST=$(hostname)

MAIL_ALERT_MSG="Warning: Execution of zsnap for $ZFS_VOLUME (pid $SCRIPT_PID) as $LOCAL_USER@$LOCAL_HOST produced some errors."

function Log
{
        # Writes a standard log file including normal operation
        DATE=$(date)
        echo "$DATE - $1" >> $LOG_FILE
        if [ $silent -ne 1 ]
        then
                echo "$1"
        fi
}

function LogError
{
	Log "$1"
	error_alert=1
}

function TrapError
{
        local JOB="$0"
        local LINE="$1"
        local CODE="${2:-1}"
        echo "Error in ${JOB}: Near line ${LINE}, exit code ${CODE}"
}

function TrapStop
{
        LogError " /!\ WARNING: Manual exit of zsnap script. zfs snapshots may not be mounted."
        exit 1
}

function TrapQuit
{
	if [ $error_alert -ne 0 ]
	then
        	SendAlert
        	LogError "Zsnap script finished with errors."
	else
        	if [ "$DEBUG" == "yes" ]
        	then
                	Log "Zsnap script finshed."
        	fi
	fi
}


function SendAlert
{
        cat $LOG_FILE | gzip -9 > /tmp/zsnap_lastlog.gz
        if type -p mutt > /dev/null 2>&1
        then
                echo $MAIL_ALERT_MSG | $(which mutt) -x -s "Zsnap script alert for $ZFS_VOLUME" $DESTINATION_MAILS -a /tmp/zsnap_lastlog.gz
                if [ $? != 0 ]
                then
                        Log "WARNING: Cannot send alert email via $(which mutt) !!!"
                else
                        Log "Sent alert mail using mutt."
                fi
        elif type -p mail > /dev/null 2>&1
        then
                echo $MAIL_ALERT_MSG | $(which mail) -a /tmp/zsnap_lastlog.gz -s "Zsnap script alert for $ZFS_VOLUME" $DESTINATION_MAILS
                if [ $? != 0 ]
                then
                        Log "WARNING: Cannot send alert email via $(which mail) with attachments !!!"
                        echo $MAIL_ALERT_MSG | $(which mail) -s "Zsnap script alert for $ZFS_VOLMUE" $DESTINATION_MAILS
                        if [ $? != 0 ]
                        then
                                Log "WARNING: Cannot send alert email via $(which mail) without attachments !!!"
                        else
                                Log "Sent alert mail using mail command without attachment."
                        fi
                else
                        Log "Sent alert mail using mail command."
                fi
        else
                Log "WARNING: Cannot send alert email (no mutt / mail present) !!!"
                return 1
        fi
}

function LoadConfigFile
{
        if [ ! -f "$1" ]
        then
                LogError "Cannot load zsnap configuration file [$1]. Zsnap script cannot work."
                return 1
        elif [[ $1 != *.conf ]]
        then
                LogError "Wrong configuration file supplied [$1]. Zsnap cannot work."
		return 1
        else
                egrep '^#|^[^ ]*=[^;&]*'  "$1" > "/dev/shm/zsnap_config_$SCRIPT_PID"
                source "/dev/shm/zsnap_config_$SCRIPT_PID"
        fi
}

function CheckEnvironment
{
	if ! type -p zfs > /dev/null 2>&1
	then
		LogError "zfs not present. zsnap cannot work."
		return 1
	fi

	if ! type -p zpool > /dev/null 2>&1
	then
		LogError "zpool not present. zsnap cannot work."
		return 1
	fi
}

# Count number of snapshots of $ZFS_VOLUME
function CountSnaps
{
	SNAP_COUNT=$($(which zfs) list -t snapshot -H | grep "$ZFS_VOLUME@" | wc -l)
	if [ $? != 0 ]
	then
		LogError "CountSnaps: Cannot count snapshots of volume $ZFS_VOLUME"
		return 1
	elif [ $verbose -eq 1 ]
	then
		Log "CountSnaps: There are $SNAP_COUNT snapshots in $ZFS_VOLUME"
		return 0
	fi
}

# Destroys a snapshot given as argument
function DestroySnap
{
        if [ "$USE_SHADOW_COPY2" == "no" ]
        then
		mountpoint=$(mount | grep $1 | cut -d' ' -f3)
		if [ "$mountpoint" != "" ]
		then
			umount $mountpoint
			if [ $? != 0 ]
			then
				LogError "DestroySnap: Cannot unmount snapshot $1 from $mountpoint"
				return 1
			elif [ $verbose -eq 1 ]
			then
				Log "DestroySnap: Snapshot $1 unmounted from $mountpoint"
			fi
		fi
	fi

	$(which zfs) destroy $1
	if [ $? != 0 ]
	then
		LogError "DestroySnap: Cannot destroy snapshot $1"
		return 1
	else
	Log "DestroySnap: Snapshot $1 destroyed"
	fi

	if [ -d $mountpoint ] && [ "$mountpoint" != "" ]
	then
		rm -r $mountpoint
		if [ $? != 0 ]
		then
			LogError "DestroySnap: Cannot delete mountpoint $mountpoint"
			return 1
		elif [ $verbose -eq 1 ]
		then
			Log "DestroySnap: Mountpoint $mountpoint deleted"
		fi
	fi
}

# Destroys oldest snapshot, or destroys all snapshots in volume if argumennt "all" is given
function DestroySnaps
{
	for snap in $($(which zfs) list -t snapshot -H | grep "$ZFS_VOLUME@" | cut -f1)
	do
		DestroySnap $snap
		if [ "$1" != "all" ]
		then
			break;
		fi
	done
}

# Gets disk usage of zpool $ZFS_POOL
function GetZvolUsage
{
	USED_SPACE=$($(which zpool) list -H | grep $ZFS_POOL | cut -f5 | cut -d'%' -f1)
	if [ $? != 0 ]
	then
		LogError "GetZvolUsage: Cannot get disk usage of pool $ZFS_POOL"
		return 1
	elif [ $verbose -eq 1 ]
	then
		Log "GetZvolUsage: Disk usage of $ZFS_POOL = $USED_SPACE %"
	fi
}

# Mounts all current snapshots of $ZFS_VOLUME in samba vfs shadow_copy compatible format
function MountSnaps
{
	zvol_mountpoint=$($(which zfs) get mountpoint $ZFS_VOLUME -H | cut -f3)
	for snap in $($(which zfs) list -t snapshot -H | grep "$ZFS_VOLUME@" | cut -f1)
	do
		snap_mountpoint=$(echo $snap | cut -d'@' -f2)
		if [ $(mount | grep $snap_mountpoint | wc -l) -eq 0 ]
		then
			mkdir -p $zvol_mountpoint/@GMT-$snap_mountpoint
			if [ $? != 0 ]
			then
				LogError "MountSnaps: Cannot create mountpoint directory $zvol_mountpoint/$snap_mountpoint"
				return 1
			elif [ $verbose -eq 1 ]
			then
				Log "MountSnaps: Created mountpoint directory $zvol_mountpount/@GMT-$snap_mountpoint"
			fi
			mount -t zfs $snap $zvol_mountpoint/@GMT-$snap_mountpoint
			if [ $? != 0 ]
			then
				LogError "MountSnaps: Cannot mount $snap on $zvol_mountpoint/@GMT-$snap_mountpoint"
				return 1
			elif [ $verbose -eq 1 ]
			then
				Log "MountSnaps: Snapshot $snap mounted on $zvol_mountpoint/@GMT-$snap_mountpoint"
			fi
		fi
	done
}

# Unmounts all snapshots and deletes its mountpoint directories
function UnmountSnaps
{
        for mountpoint in $(mount | grep "$ZFS_VOLUME@" | cut -d' ' -f3)
        do
                umount $mountpoint
                if [ $? != 0 ]
                then
                        LogError "UnmountSnaps: Cannot unmount $mountpoint"
                elif [ $verbose -eq 1 ]
		then
                        Log "UnmountSnaps: $mountpoint unmounted"
                fi

                rm -r $mountpoint
                if [ $? != 0 ]
                then
                        LogError "UnmountSnaps: Cannot delete mountpoint $mountpoint"
                elif [ $verbose -eq 1 ]
		then
                        Log "UnmountSnaps: Mountpoint $mountpoint deleted"
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
		LogError "CreateSnap: Cannot create snapshot $ZFS_VOLUME@$SNAP_TIME"
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
	if [ $verbose -eq 1 ]
	then
		Log "There are currently $SNAP_COUNT snapshots on volume $ZFS_VOLUME for $USED_SPACE % disk usage"
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

	if [ $verbose -eq 1 ]
	then
		Log "After enforcing, there are $SNAP_COUNT snapshots on volume $ZFS_VOLUME for $USED_SPACE % disk usage"
	fi

	if [ $max_space_reached -eq 1 ]
	then
		LogError "Warning: $MAX_SPACE disk usage was reached."
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
	echo ""
	echo "Snapshot list"
	for snap in $($(which zfs) list -t snapshot -H | grep "$ZFS_VOLUME@" | cut -f1)
	do
		echo "$snap"
	done
}

function Init
{
	set -o pipefail
	set -o errtrace

        trap TrapStop SIGINT SIGQUIT SIGKILL SIGTERM SIGHUP
	trap TrapQuit EXIT
	if [ "$DEBUG" == "yes" ]
	then
        	trap 'TrapError ${LINENO} $?' ERR
	fi

	ZFS_POOL=$(echo $ZFS_VOLUME | cut -d'/' -f1)
	LOG_FILE=/var/log/zsnap_${ZFS_VOLUME##*/}.log
}

function Usage
{
	echo "Zsnap $ZSNAP_VERSION written in 2010-2013 by Orsiris "Ozy" de Jong | ozy@netpower.fr"
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
	echo "mount - (does not apply to shadow_copy2 use) Mounts all snapshots. Mounting is automatic, this is only needed in case of a recovery."
	echo "umount - (does not apply to shadow_copy2 use) Unmounts all snapshots. Unmounting is automatic, this is only needed in case of a recovery."
	echo
	echo "--silent - Will run Zsnap without any output to stdout. Usefull for cron tasks."
	echo "--verbose - Will add function output."
	exit 128
}

# General flags
silent=0
verbose=0
# Alert flags
error_alert=0

for i in "$@"
do
	case $i in
		--silent)
		silent=1
		;;
		--verbose)
		verbose=1
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
					DestroySnap "$3"
				else
					Usage
				fi
				;;
				*)
				Usage
				;;
			esac
                else
                        LogError "Configuration file could not be loaded."
                        exit 1
                fi
        else
                LogError "No configuration file provided."
                exit 1
        fi
fi
