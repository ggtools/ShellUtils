#!/usr/bin/env bash
# Bash library to process tasks using a workers model.
#
# This file is part of ShellUtils. Copyright © 2011 Christophe Labouisse.
# 
# ShellUtils is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# ShellUtils is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with ShellUtils.  If not, see <http://www.gnu.org/licenses/>.

# ==========================================
#
# Variables
#
# ==========================================

WL_VERSION_ID='$Id: workers-lib.sh 37 2005-01-21 06:12:51Z jb $'

# Locking configuration

# How long the lock should be kept during read operations
WL_KEEP_LOCK_READ=1

# How often should we check for the lock when reading/writting.
WL_POOL_LOCK_READ=8
WL_POOL_LOCK_WRITE=1

# How much time should we wait before trying to aquire the lock again when
# the input queue is empty.
WL_SLEEP_ON_EMPTY_TIME=5

# Logging interface

WL_DEBUG=1
WL_INFO=2
WL_WARN=3
WL_WARNING=$WL_WARN
WL_ERR=4
WL_ERROR=$WL_ERR
WL_FATAL=5

WL_LOGLEVEL=$WL_INFO


# ==========================================
#
# Workers interface
#
# ==========================================

# Workers can be specially written function/commands of normal ones wrapped
# by WorkerWrapper. During the execution, the following variables will
# be defined by the framework:
# WL_STREAM: stream used to get the command from.
# WL_TASK_NAME: name of the task/group to which the worker belongs.
# WL_WORKER: number of the worker withing the group.
# WL_TASK_WORKERS: number of workers in the group.
#
# Workers should not use the stream 3 & 4 which are reserved for the lib internal use.

# Wrapper to use simple functions/commands in a worker.
# The wrapper will read a given stream an pass every line to the command.
# Receiving a line equals to "DONE" (without quotes) will terminate the worker.
WorkerWrapper()
{
	local COMMAND="$1" ; shift
	local lockfile=$(GetLockFile $COMMAND)
	local rc
	wlInfo "Starting wrapped worker using $COMMAND"
	while [ 1 ]
	do
		wlDebug "Trying to lock $lockfile"
		lockfile -$WL_POOL_LOCK_READ $lockfile
		wlDebug "Got lock, reading"
		read -t $WL_KEEP_LOCK_READ input <&$WL_STREAM
		rc=$?
		rm -f $lockfile
		wlDebug "Unlocked"
		if [ $rc -eq 0 ]
		then
			[ "$input" = "DONE" ] && wlDebug "DONE message received, quitting" && break
			$COMMAND $input
		else
			wlDebug "Didn't read anything ($rc)"
			sleep $WL_SLEEP_ON_EMPTY_TIME
		fi
	done

	wlInfo "Stopping wrapped worker"
}


# Start workers on a specially designed command. The command will be responsible
# for reading the given stream.
# This function is responsible for defining WL_STREAM, WL_TASK_NAME, WL_WORKER and
# WL_TASK_WORKERS.
_StartWorkersInternal()
{
	local NBWORKERS=$1 ; shift
	local STREAM=$1 ; shift
	local COMMAND=$1 ; shift
	local NAME=$1 ; shift
	local ARGS=$@
	local max=$NBWORKERS+1
	local lockfile=/tmp/wl-$$-$NAME.lock
	local n
	wlInfo "Starting $NBWORKERS workers on stream $STREAM for command $NAME"
	wlDebug "Debug lockfile is $lockfile"
	eval _STREAMS_$NAME=$STREAM
	eval _LOCKFILE_$NAME="$lockfile"
	for ((n=1 ; max-n; n++))
	do
		(WL_STREAM=$STREAM; WL_TASK_NAME=$NAME; WL_WORKER=$n; WL_TASK_WORKERS=$NBWORKERS; $COMMAND $ARGS) &
		eval _WORKERS_$NAME[$n]=$!
	done
	__WORKERS[${#__WORKERS[*]}]=$NAME
}

# Start workers on a specially designed command. The command will be responsible
# for reading the given stream.
StartWorkers()
{
	local NBWORKERS=$1 ; shift
	local STREAM=$1 ; shift
	local COMMAND=$1 ; shift
	local ARGS=$@
	_StartWorkersInternal $NBWORKERS $STREAM $COMMAND $COMMAND $ARGS
}

# Start workers on a simple command using the WorkerWrapper function.
StartWrappedWorkers()
{
	local NBWORKERS=$1 ; shift
	local STREAM=$1 ; shift
	local COMMAND=$1 ; shift
	_StartWorkersInternal $NBWORKERS $STREAM WorkerWrapper $COMMAND $COMMAND
}

GetWorkers()
{
	local COMMAND=$1
	local tmp=_WORKERS_$COMMAND[@]
	echo ${!tmp}
}

# Send a command to a worker group
SendCommand()
{
	local GROUP=$1 ; shift
	local message=$@
	local STREAM=$(GetStream $GROUP)
	local lockfile=$(GetLockFile $GROUP)
	wlDebug "Sending \"$message\" to $GROUP"
	wlDebug "Trying to lock $lockfile"
	lockfile -$WL_POOL_LOCK_WRITE $lockfile
	wlDebug "Got lock writing"
	echo >&$STREAM $message
	rm -f $lockfile
}

GetStream()
{
	local GROUP=$1
	local tmp=_STREAMS_$GROUP
	echo ${!tmp}
}

GetLockFile()
{
	local GROUP=$1
	local tmp=_LOCKFILE_$GROUP
	echo ${!tmp}
}

StopWorkers()
{
	local GROUP=$1
	wlInfo "Sending stop message for $GROUP"
	local n
	for n in $(GetWorkers $GROUP)
	do
		SendCommand $GROUP DONE
	done
}

StopAllWorkers()
{
	wlInfo "Sending stop message to all workers"
	local proc
	for proc in ${__WORKERS[@]}
	do
		StopWorkers $proc
	done
}

KillWorkers()
{
	local GROUP=$1
	wlInfo "Killing workers for $GROUP"
	local n
	for n in $(GetWorkers $GROUP)
	do
		wlDebug "Killing $n"
		ps $n >/dev/null 2>&1 && kill $n
	done
	rm -rf $(GetLockFile $GROUP)
}

# Kill all workers started by the framework. If the WL_CLEANUP variable
# is defined, $WL_CLEANUP will be called after killing.
KillAllWorkers()
{
	wlInfo "Killing all workers"
	local proc
	for proc in ${__WORKERS[@]}
	do
		KillWorkers $proc
	done

	if [ "$WL_CLEANUP" != "" ]
	then
		wlDebug "Calling $WL_CLEANUP"
		$WL_CLEANUP
	else
		wlDebug "No cleanup"
	fi
}

# ==========================================
#
# Logging interface
#
# ==========================================

# Log a message with timestamp, worker information depending on the
# log level.
# If the WL_DEBUGLOG_FILE variable is not empty all messages regardless
# of the level will be logged in this file.
wlLog()
{
	local levelName=$1 ; shift
	local msg=$@
	local tmp=WL_$levelName
	local level=${!tmp}

	if [ "$level" = "" ]
	then
		level=$WL_INFO
	fi

	if [ $level -ge $WL_LOGLEVEL -o "$WL_DEBUGLOG_FILE" != "" ]
	then
		if [ "$WL_TASK_NAME" = "" ]
		then
			local info=Top
		else
			local info="$WL_TASK_NAME[$WL_STREAM] ($WL_WORKER/$WL_TASK_WORKERS)"
		fi

		local line=$(date +"%d-%m-%Y %T $info [$levelName]: $msg")

		if [ $level -ge $WL_LOGLEVEL ]; then echo $line ; fi
		if [ "$WL_DEBUGLOG_FILE" != "" ]; then echo $line >>"$WL_DEBUGLOG_FILE" ; fi
	fi
}

wlDebug()
{
	wlLog DEBUG $@
}

wlInfo()
{
	wlLog INFO $@
}

wlWarn()
{
	wlLog WARN $@
}

wlError()
{
	wlLog ERROR $@
}

wlFatal()
{
	wlLog FATAL $@
	KillAllWorkers
	exit 128
}

# Log the output of a command. Stdout will be logged with a priority specified
# as the first argument while stderr will be logged as ERROR.
wlLogCommand()
{
	local STDINLEVEL=$1 ; shift
	local COMMAND=$@
	exec 3> >(while read line ; do wlError $line ; done)
	$COMMAND 2>&3 | while read line ; do wlLog $STDINLEVEL $line ; done
	exec 3>&-
}

# It is recommanded to set a trap like this on exit.
# trap KillAllWorkers 1 2 3 15

#rm -f $PIPE
#mkfifo $PIPE
#exec 5<>$PIPE
