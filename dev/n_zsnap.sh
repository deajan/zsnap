#!/usr/bin/env bash

###### ZFS snapshot management script - Samba vfs objects shadow_copy or shadow_copy2 previous versions friendly
PROGRAM="zsnap"
AUTHOR="(L) 2010-2016 by Orsiris de Jong"
CONTACT="http://www.netpower.fr/zsanp - ozy@netpower.fr"
PROGRAM_VERSION=0.9.4
PROGRAM_BUILD=2016031401

MAIL_ALERT_MSG="Warning: Execution of zsnap for $ZFS_VOLUME (pid $SCRIPT_PID) as $LOCAL_USER@$LOCAL_HOST produced some errors."

source "./ofunctions.sh"


function TrapStop {
        Logger "/!\ Manual exit of zsnap script. zfs snapshots may not be mounted." "WARN"
        exit 1
}

function TrapQuit {
	if [ $ERROR_ALERT -ne 0 ]; then
        	SendAlert
        	Logger "Zsnap script finished with errors." "ERROR"
	else
        	if [ "$_DEBUG" == "yes" ]
        	then
                	Logger "Zsnap script finshed." "NOTICE"
        	fi
	fi
}

function CheckEnvironment {
	if ! type -p zfs > /dev/null 2>&1
	then
		Logger "zfs not present. zsnap cannot work." "CRITICAL"
		Usage
	fi

	if ! type -p zpool > /dev/null 2>&1
	then
		Logger "zpool not present. zsnap cannot work." "CRITICAL"
		Usage
	fi
}

# Count number of snapshots of $ZFS_VOLUME
function CountSnaps {
	SNAP_COUNT=$($(which zfs) list -t snapshot -H | grep "^$ZFS_VOLUME@" | wc -l)
	if [ $? != 0 ]; then
		SNAP_COUNT=0
	fi
	if [ "$_VERBOSE" -ne 0 ]; then
		Logger "CountSnaps: There are $SNAP_COUNT snapshots in $ZFS_VOLUME" "NOTICE"
		return 0
	fi
}

# Destroys a snapshot given as argument
function DestroySnap {
        if [ "$USE_SHADOW_COPY2" != "yes" ]
        then
		mountpoint=$(mount | grep $1 | cut -d' ' -f3)
		if [ "$mountpoint" != "" ]; then
			umount "$mountpoint"
			if [ $? != 0 ]; then
				Logger "DestroySnap: Cannot unmount snapshot $1 from $mountpoint" "ERROR"
				return 1
			elif [ "$_VERBOSE" -ne 0 ]; then
				Logger "DestroySnap: Snapshot $1 unmounted from $mountpoint" "NOTICE"
			fi
		fi
	fi

	$(which zfs) destroy $1
	if [ $? != 0 ]; then
		Logger "DestroySnap: Cannot destroy snapshot $1" "ERROR"
		return 1
	else
	Logger "DestroySnap: Snapshot $1 destroyed" "NOTICE"
	fi

	if [ -d $mountpoint ] && [ "$mountpoint" != "" ]; then
		rm -r $mountpoint
		if [ $? != 0 ]; then
			Logger "DestroySnap: Cannot delete mountpoint $mountpoint" "ERROR"
			return 1
		elif [ "$_VERBOSE" -ne 0 ]; then
			Logger "DestroySnap: Mountpoint $mountpoint deleted" "NOTICE"
		fi
	fi
}

# Destroys oldest snapshot, or destroys all snapshots in volume if argumennt "all" is given
function DestroySnaps {
	arg="$1"
	destroycount=0
	for snap in $($(which zfs) list -t snapshot -H | grep "^$ZFS_VOLUME@" | cut -f1)
	do
		DestroySnap $snap
		destroycount=$(($destroycount + 1))
		if [ "$arg" == "" ]; then
			break;
		elif [ "$arg" == "all" ]; then
			break;
		elif [ $destroycount -ge "$arg" ]; then
			break;
		fi
	done
}

# Gets disk usage of zpool $ZFS_POOL
function GetZvolUsage {
	USED_SPACE=$($(which zpool) list -H | grep $ZFS_POOL | cut -f5 | cut -d'%' -f1)
	## Added support for new zfsonlinux 0.6.4 zpool output
	if [ "$USED_SPACE" == "-" ]; then
		USED_SPACE=$($(which zpool) list -H | grep $ZFS_POOL | cut -f7 | cut -d'%' -f1)
	fi

	if [ $? != 0 ]; then
		Logger "GetZvolUsage: Cannot get disk usage of pool $ZFS_POOL" "ERROR"
		return 1
	elif [ "$_VERBOSE" -ne 0 ]; then
		Logger "GetZvolUsage: Disk usage of $ZFS_POOL = $USED_SPACE %" "NOTICE"
	fi
}

# Mounts all current snapshots of $ZFS_VOLUME in samba vfs shadow_copy compatible format
function MountSnaps {
	zvol_mountpoint=$($(which zfs) get mountpoint $ZFS_VOLUME -H | cut -f3)
	for snap in $($(which zfs) list -t snapshot -H | grep "^$ZFS_VOLUME@" | cut -f1)
	do
		snap_mountpoint=$(echo $snap | cut -d'@' -f2)
		if [ "$(mount | grep $snap_mountpoint | wc -l)" -eq 0 ]; then
			mkdir -p $zvol_mountpoint/@GMT-$snap_mountpoint
			if [ $? != 0 ]; then
				Logger "MountSnaps: Cannot create mountpoint directory $zvol_mountpoint/$snap_mountpoint" "ERROR"
				return 1
			elif [ "$_VERBOSE" -ne 0 ]; then
				Logger "MountSnaps: Created mountpoint directory $zvol_mountpoint/@GMT-$snap_mountpoint" "NOTICE"
			fi
			mount -t zfs $snap $zvol_mountpoint/@GMT-$snap_mountpoint
			if [ $? != 0 ]; then
				Logger "MountSnaps: Cannot mount $snap on $zvol_mountpoint/@GMT-$snap_mountpoint" "ERROR"
				return 1
			elif [ "$_VERBOSE" -ne 0 ]; then
				Logger "MountSnaps: Snapshot $snap mounted on $zvol_mountpoint/@GMT-$snap_mountpoint" "NOTICE"
			fi
		fi
	done
}

# Unmounts all snapshots and deletes its mountpoint directories
function UnmountSnaps {
        for mountpoint in $(mount | grep "^$ZFS_VOLUME@" | cut -d' ' -f3)
        do
                umount "$mountpoint"
                if [ $? != 0 ]
                then
                        Logger "UnmountSnaps: Cannot unmount $mountpoint" "ERROR"
                elif [ "$_VERBOSE" -ne 0 ]; then
                        Logger "UnmountSnaps: $mountpoint unmounted" "NOTICE"
                fi

                rm -r "$mountpoint"
                if [ $? != 0 ]
                then
                        Logger "UnmountSnaps: Cannot delete mountpoint $mountpoint" "ERROR"
                elif [ "$_VERBOSE" -ne 0 ]; then
                        Logger "UnmountSnaps: Mountpoint $mountpoint deleted" "NOTICE"
                fi
        done
}

# Creates a new snapshot. Unmounts snapshots before creation and remounts them afterwards so snapshot mountpoints won't be snapshotted
function CreateSnap {
	if [ "$USE_SHADOW_COPY2" == "no" ]; then
		UnmountSnaps
	fi
	if [ "$USE_UTC" != "no" ]; then
		SNAP_TIME=$(date -u +%Y.%m.%d-%H.%M.%S)
	else
		SNAP_TIME=$(date +%Y.%m.%d-%H.%M.%S)
	fi
	$(which zfs) snapshot $ZFS_VOLUME@$SNAP_TIME
	if [ $? != 0 ]; then
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
function VerifyParamsAndCreateSnap {
	max_space_reached=0
	GetZvolUsage
	CountSnaps
	if [ "$_VERBOSE" -ne 0 ]; then
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

	if [ "$_VERBOSE" -ne 0 ]; then
		Logger "After enforcing, there are $SNAP_COUNT snapshots on volume $ZFS_VOLUME for $USED_SPACE % disk usage" "NOTICE"
	fi

	if [ $max_space_reached -eq 1 ]; then
		Logger "$MAX_SPACE disk usage was reached." "WARN"
	fi

	CreateSnap
}

function Status {
	echo "zsnap $ZSNAP_VERSION status"
	echo ""
	GetZvolUsage
	CountSnaps
	echo "Number of snapshots (min < actual < max): $MIN_SNAPSHOTS < $SNAP_COUNT < $MAX_SNAPSHOTS"
	echo "Disk usage: $ZFS_POOL: $USED_SPACE %"
	if [ "$_VERBOSE" -ne 0 ]; then
		echo ""
		echo "Snapshot list"
		for snap in $($(which zfs) list -t snapshot -H | grep "^$ZFS_VOLUME@" | cut -f1)
		do
			echo "$snap"
		done
	fi
}

function Init {
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

function Usage {
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
if [ $? == 0 ]; then
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
				if [ "$3" != "" ]; then
					if [[ "$3" == *"@"* ]]; then
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
