#!/bin/bash

# TODO
# - Add subsystem that will keep any other command in queue if the tty is in use (this includes the looplistener, TCP, and all other commands). This is sort of already in existence with the ".inuse" files I have most scripts creating, but not entirely 
# - Add IP address whitelisting/blocking -- include BLOCK and WHITELIST commands
# - Add alias so when certain IP addresses connect, they can be translated to the alias (this alias will also be used for outgoing connections so the IP address doesn't have to be typed in

source ./tty-common

function ungraceful {
	absorb "Connection severed" > "${TTY}"
	rm -vf /dev/shm/tty-tcp-{con,q,hist}*."${QID}"
	sleep 1
	ttyuninit
	debugprint "Connection ID ${QID} had to be shut down ungracefully; remote host likely severed connection or timed out without ${TERMCH} signal."
	exit 1
}

trap ungraceful EXIT SIGINT SIGTERM SIGHUP

debugprint "TCP connection initiated. Checking whether active connection to TTY is already running."

########### Verify a connection isn't already open

BUSY='TRUE'
WAITCOUNT=30

# https://gist.github.com/earthgecko/3089509
QID=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 5 | head -n 1)
debugprint "This connection's queue ID is ${QID}"
while [[ "${BUSY}" == "TRUE" ]]; do

	## TODO: Replace all crappy ls command checks with if [[ -f /path/to/file ]]; then
	ISQUEUE=$(ls /dev/shm/tty-tcp-{con,q}* 2> /dev/null)
	ISUSED=$(ls /dev/shm/${TTYNAME}.inuse 2> /dev/null)	
	debugprint "ISQUEUE is ${ISQUEUE}"
	debugprint "ISUSED is ${ISUSED}"

	if [[ -n "${ISQUEUE}" ]]; then
		# Connection already open; put this guy in queue if he's not already
		debugprint "Queue already exists; putting ID ${QID} in queue if not already queued"
		ISQUEUED=$(ls /dev/shm/tty-tcp-q."${QID}" 2>/dev/null)
		if [[ -z "${ISQUEUED}" ]]; then
			# This request has not yet been queued; add to queue
			debugprint "This request ID ${QID} has not yet been queued. Adding to queue"
			QUEUE=1
			for i in $(ls /dev/shm/tty-tcp-q* 2>/dev/null | grep -v "${QID}"); do
			# See how many are in queue
				((QUEUE++))
			done
			# Add to queue with number
			####### This will never happen for the first one since it doesn't need to be in queue, and the other ones will follow suit
			echo "${QUEUE}" > /dev/shm/tty-tcp-q."${QID}"
			debugprint "Successfully added ID ${QID} to queue as number ${QUEUE}"
		fi
		
		# Advance up in queue if previous items have advanced
		PREVNUM=${QUEUE}
		((PREVNUM--))
		if [[ "${PREVNUM}" -lt 1 ]]; then
			# We're at the top of the queue-- check to see if active connection is closed at last
			debugprint "ID ${QID} is at the top of the queue, checking to see if active connection has been closed"
			ISCON=$(ls /dev/shm/tty-tcp-con* 2> /dev/null)
			if [[ -z "${ISCON}" ]]; then
				debugprint "The previous active connection has been closed. Establishing protocol for ID ${QID}"
				BUSY='FALSE'
				break
			fi
		else
			PREVQ=$(grep "${PREVNUM}" /dev/shm/tty-tcp-q* | cut -d ':' -f 1)
			if [[ -z "${PREVQ}" ]]; then
			# The previous item in the queue doesn't exist anymore, move this item up one
				debugprint "Previous item in queue has been moved up. Moving ID ${QID} to ${PREVNUM}"
				QUEUE="${PREVNUM}"
				echo "${QUEUE}" > /dev/shm/tty-tcp-q."${QID}"
			fi
		fi

		# Line is still busy; nothing to do
		debugprint "Line is busy for ID ${QID}. Will check again in 5 seconds."
	else
		# There is no queue and no active connection; exit loop
		debugprint "No active connection or queue, establishing connection for ID ${QID}"
		BUSY='FALSE'
		break
	fi

	# Throttle check of the busy line to every 5 seconds; only send busy message once every 2.5 minutes
	((WAITCOUNT++))
	if [[ "${WAITCOUNT}" -ge 30 ]]; then
		echo "Line busy. You are ${QUEUE} in queue. Please stand by."
		WAITCOUNT=0
	elif [[ -n "${ISUSED}" ]]; then
		# The specified TTY is in use by another program
		echo "Machine busy. There is no ETA of availability. Please stand by."
	fi
	sleep 5
done

########### No queue, send welcome message to remote machine
touch /dev/shm/tty-tcp-con."${QID}"
echo "${TCPWELCOME}"

ttyinit

BLOCKLOC=0
CHARWAIT=$(echo "scale=4; 5.4 / ${BAUD}" | bc)
TIMEOUT=$(echo "${TCPTIMEOUT} / ${CHARWAIT}" | bc)
RESETTO="${TIMEOUT}"

while true; do
	#start=$(date +%s.%N)
	debugprint "PREVREMCHAR is ${PREVREMCHAR}, and BLOCKLOC  is ${BLOCKLOC}"	
	# Attempt to get character from local machine
	if [[ "${BLOCKLOC}" -gt 0 ]]; then
		debugprint "REMCHAR received; blocking input ${BLOCKLOC} time(s)"
		read -n 1 -t "${CHARWAIT}" OBLIVION < "${TTY}"
		((BLOCKLOC--))
	else
		read -n 1 -t "${CHARWAIT}" LOCCHAR < "${TTY}"
		LOCFAIL=${?}
		if [[ -z "${LOCCHAR}" ]]; then
			if [[ "${LOCFAIL}" -ne 0 ]]; then
				# No character was input before timeout; increment timeout
				echo "Nothing to see here in the oblivion" > /dev/null 2>&1
				((TIMEOUT--))
			else
				# A NUL character was received, which we can safely assume is a newline; output newline to remote machine
				printf '\n'
				TIMEOUT="${RESETTO}"
			fi
		else
			# Send character to history file and remote machine
			printf "%s" "${LOCCHAR}" | tee -a /dev/shm/tty-tcp-hist-loc."${QID}"
			TIMEOUT="${RESETTO}"
		fi
	fi
	
	# Attempt to get character from remote machine
	read -n 1 -t "${CHARWAIT}" REMCHAR
	REMFAIL="${?}"
	if [[ -z "${REMCHAR}" ]]; then
		if [[ "${REMFAIL}" -ne 0 ]]; then
			# No character was input before timeout; do nothing here
			echo "Nothing to see here in the oblivion" > /dev/null 2>&1
			((TIMEOUT--))
		else
			# A NUL character was received, which we can safely assume is a newline; output newline to remote machine
			printf '\n' > "${TTY}"
			PREVREMCHAR='NEWLINE'
			TIMEOUT="${RESETTO}"
			if [[ "${BLOCKLOC}" -ge 4 ]]; then
				((BLOCKLOC++))
			else
				((BLOCKLOC += 2))
			fi
		fi
	else
		# Send received character to history file and current loop
		printf "%s" "${REMCHAR}" >> /dev/shm/tty-tcp-hist-rem."${QID}" 
		printf "%s" "${REMCHAR}" > "${TTY}"
		PREVREMCHAR=$(printf "%s" "${REMCHAR}" | tr a-z A-Z)
		TIMEOUT="${RESETTO}"
		if [[ "${BLOCKLOC}" -ge 4 ]]; then
			((BLOCKLOC++))
		else
			((BLOCKLOC += 2))
		fi

		#BTIME=$(time read -n 1 BLACKHOLE < "${TTY}")
		#debugprint "BLACKHOLE is ${BLACKHOLE} and took this time to load: ${BTIME}"
	fi

	# Check history file for TERMCH sequence and terminate session if found
	ISTERM=$(grep -i "${TERMCH}" /dev/shm/tty-tcp-hist-loc."${QID}" > /dev/null 2>&1)
	if [[ -n "${ISTERM}" ]]; then
		echo && printf '\n' > "${TTY}"
		echo "EOF" && absorb "EOF"
		printf '\n' > "${TTY}"
		rm -f /dev/shm/tty-tcp-con."${QID}" > /dev/null 2>&1
		debugprint "Connection with ID ${QID} closed gracefully"
		exit 0
	fi

	# If timeout is over threshold, it means the connection has gone idle and needs to be closed
	# I just realised that we say "open a connection" when a connection to another system needs to be made
	# and "close a connection" when we mean to sever that connection. However, the most basic kind of
	# communications happen on a CLOSED circuit, meaning both "ends" of the circuit's loop are connected,
	# whilst when a circuit is OPEN, something such as a switch, electromagnet, or optoisolator has
	# broken the conneciton. This computer term is kind of opposite of the original circuit/circuit loop/
	# serial line nomenclature.
	if [[ "${TIMEOUT}" -le 0 ]]; then
		debugprint "Idle timeout for "${QID}" reached. Closing connection."
		ungraceful
	fi
		
#end=$(date +%s.%N)
#runtime=$( echo "$end - $start" | bc -l )
#debugprint "${runtime}"
done
