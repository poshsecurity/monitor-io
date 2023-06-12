#!/bin/bash
#
# NetMonitor script to manage, display, and record fping results
#
#	Date		Comments
#	----------	----------------------------------------------
#	2023-01-01	Initial version created
#
version="v1.0"

#
# Configuration settings
#
declare -i timecnt=10		# Test count and display time (recommend >= 5)
declare -i delayrng=30		# Delay range (max-min) threshold for event summary
declare -i lcdmode=2		# LCD color mode (0 = none, 1 = errors, 2 = normal)
declare -i usedefgw=1		# Use DefGW as target if pingable (1 = true, 0 = false)
tz=""				# Timezone ("" = set via IP geolocation, else see
				#	options from "timedatectl list-timezones")
suiddir="/usr/local/bin"	# Directory containing setuid (privileged) binaries
csvdir="/dev/shm/netmonitor"	# Directory of CSV data files (accessed via browser)
errfile="Latest_NetMonitor_Errors.log"
resfile="Latest_NetMonitor_Results.log"
sumfile="NetMonitor_Event_Summary.csv"

#
# Local functions
#
show_info () {
	${suiddir}/lcdwrite -f -c w -1 "${1}" -2 "${2}"
}
show_error () {
	echo "${1} ${2}" >${csvdir}/${errfile}
	if [ "${3}" != "" ]; then
		echo "${3}" >>${csvdir}/${errfile}
	fi
	cat ${csvdir}/${errfile}
	${suiddir}/lcdwrite -f -c r -1 "${1}" -2 "${2}"
}

#
# Create CSV directory if needed
#
if [ ! -d ${csvdir} ]; then
	mkdir ${csvdir}
fi

#
# Verify parameter of configured fping targets file, one entry per line:
#	8.8.8.8
#	www.google.com
#	...
#
# NOTE: Default gateway is automatically used as first entry (if pingable)
#
if [ ${#} -lt 1 ]; then
	show_error "Target Filename" "Not Provided"
	exit 1
fi
targets="${1}"
if [ ! -s ${targets} ]; then
	show_error "Target File" "Empty or Missing" "${targets}"
	exit 1
fi

#
# Display initial banner
#
show_info "NetMonitor ${version}" "  monitor-io.com"
sleep 5

#
# Await network configuration by checking IP routes
#
routes="/dev/shm/routes.log"
for (( i=1; i>0; i++ )); do	# Wait forever
	ip route show >${routes}
	declare -i routecnt=$(grep -v -c '169.254.' ${routes})
	if [ ${?} -eq 0 ] && [ ${routecnt} -ge 2 ]; then	# Expecting default and local LAN
		break
	fi
	show_info "Awaiting Network" "${i}"
	sleep 1
done

#
# Display IP address for local access
#
declare -a iparray=($(hostname -I))	# Obtain all IP addresses
ipaddr="${iparray[0]}"			# Display first one
show_info "Local IP Address" "${ipaddr}"
sleep 5
show_info "For SSH and Web" "${ipaddr}"
sleep 5

#
# If configured (and pingable), use default gateway as initial target
#
defgw=""
if [ ${usedefgw} -eq 1 ]; then
	# Expected format: default via 192.168.1.1 dev eth0 proto dhcp metric 100
	declare -a rarray=($(grep 'default' ${routes}))
	if [ ${?} -eq 0 ]; then
		${suiddir}/fping -q ${rarray[2]}
		if [ ${?} -eq 0 ]; then
			defgw="${rarray[2]}\n"		# Add newline for 'echo -ne' usage
			show_info "DefGW 1st Target" "${rarray[2]}"
			sleep 5
		fi
	fi
fi

#
# Await time sync (needed for accurate data records)
#
tsync=""
for (( i=300; i>0; i-- )); do	# Wait finite period
	tsync="$(${suiddir}/timedatectl show -p NTPSynchronized --value)"
	if [ "${tsync}" == "yes" ]; then
		break
	fi
	show_info "TimeSync Pending" "${i}"
	sleep 1
done
if [ "${tsync}" != "yes" ]; then
	show_error "TimeSync Failure" "Date/Time/TZ = ?" \
		"CSV files may have inaccurate Date, Time, and/or Timezone"
	sleep 10
fi

#
# Update timezone if it doesn't match configured (and geolocate if not configured)
#
tzlabel="Timezone"
tzone="$(${suiddir}/timedatectl show -p Timezone --value)"	# Obtain current timezone
if [ "${tz}" != "${tzone}" ]; then
	#
	# If timezone not configured and time sync was successful, attempt to geolocate
	#
	if [ "${tz}" == "" ] && [ "${tsync}" == "yes" ]; then
		declare -a tzarray=($(curl -s -S ipinfo.io/timezone 2>&1))
		if [ ${?} -ne 0 ] || [ ${#tzarray[*]} -ne 1 ]; then
			show_error "IP Geolocation" "Failure" "${tzarray[*]}"
			sleep 10
		else
			tz="${tzarray[0]}"
		fi
	fi

	#
	# If configured or geolocated timezone available (and doesn't match current), update timezone
	#
	if [ "${tz}" != "" ] && [ "${tz}" != "${tzone}" ]; then
		tdc="$(${suiddir}/timedatectl set-timezone ${tz} 2>&1)"		# Change timezone
		if [ ${?} -ne 0 ]; then
			show_error "Invalid Timezone" "${tz}" "${tdc}"
			exit 1
		fi
		tzlabel="Timezone Updated"
		tzone="$(${suiddir}/timedatectl show -p Timezone --value)"	# Obtain updated timezone
	fi
fi
show_info "${tzlabel}" "${tzone}"
sleep 5

#
# Main processing loop
#
lastcolor=""
declare -i i=1
fplog="/dev/shm/fping.log"
show_info "Displayed Values" "LossPct DelayMax"	# Displayed during first fping execution
while [ 1 ]; do
	#
	# Execute fping to default gateway and configured targets, expected output:
	#	192.168.1.1    : xmt/rcv/%loss = 15/15/0%, min/avg/max = 0.416/0.539/1.11
	#	8.8.8.8        : xmt/rcv/%loss = 15/15/0%, min/avg/max = 6.25/6.25/6.25
	#	www.google.com : xmt/rcv/%loss = 15/15/0%, min/avg/max = 3.82/4.75/5.67
	#	...
	#
	declare -i fpbeg=$(date +%s)
	{ echo -ne "${defgw}"; cat ${targets}; } | ${suiddir}/fping -q -r 0 -c ${timecnt} >${fplog} 2>&1
	if [ ${?} -eq 2 ]; then
		#
		# Process (possible immediate) return if name resolution failure(s)
		#
		declare -i fpend=$(date +%s)
		echo "DNS:Failure(s)" >>${fplog}	# Add failure entry
		if [ $(( fpend - fpbeg )) -le $(( timecnt / 2 )) ]; then
			sleep ${timecnt}		# Maintain cycle time
		fi
	fi

	#
	# Parse each line of fping output
	#
	hdr="IPAddress"
	csv="${ipaddr}"
	declare -i j=1 sumevent=0
	while read fpline; do
		#
		# Extract fields from line of results
		#
		declare -a fparray=(${fpline})	# Convert to array
		target="${fparray[0]}"		# First entry is target
		csv="${csv},${target}"
		hdr="${hdr},Target${j}"

		#
		# Process loss if present, else add nulls
		#
		if [ "${fparray[2]}" == "xmt/rcv/%loss" ]; then
			declare -a lossarray=(${fparray[4]//[\/%,]/ })	# "10/10/0%,"
			losspct="${lossarray[2]}"
			csv="${csv},${lossarray[0]},${lossarray[1]},${lossarray[2]}"
		else
			losspct="100"
			csv="${csv},,,"
		fi
		hdr="${hdr},Transmit${j},Receive${j},LossPct${j}"
		if [ "${losspct}" != "0" ]; then
			(( sumevent=1 ))	# Summary event if loss not zero
		fi

		#
		# Process delay if present, else add nulls
		#
		if [ "${fparray[5]}" == "min/avg/max" ]; then
			declare -a delarray=(${fparray[7]//\// })	# "3.82/4.75/5.67"
			delaymin="${delarray[0]}"
			delaymax="${delarray[2]}"
			csv="${csv},${delarray[0]},${delarray[1]},${delarray[2]}"
		else
			delaymin="0.000"
			delaymax="0.000"
			csv="${csv},,,"
		fi
		hdr="${hdr},DelayMin${j},DelayAvg${j},DelayMax${j}"
		declare -i min=${delaymin%.*} max=${delaymax%.*}	# Use integer only
		if [ $(( max-min )) -ge ${delayrng} ]; then
			(( sumevent=1 ))	# Summary event if range over threshold
		fi

		#
		# Display results for the next target (showing only one per cycle)
		#
		if [ ${i} -eq $(( j++ )) ]; then
			color="0"
			if [ ${lcdmode} -gt 0 ]; then
				color="r"			# Red is default
				if [ "${losspct}" == "0" ]; then
					if [ ${lcdmode} -gt 1 ]; then
						color="g"	# Green if 0% loss
					else
						color="0"	# None instead of green
					fi
				elif [ "${losspct}" != "100" ]; then
					color="y"		# Yellow if not 100% loss
				fi
			fi
			if [ "${color}" != "${lastcolor}" ]; then
				${suiddir}/lcdwrite -c ${color}
				lastcolor="${color}"
			fi
			${suiddir}/lcdwrite -f -1 "${target}" -2 "  ${losspct}%  ${delaymax}ms"
		fi
	done <${fplog}

	#
	# Increment display counter to next target for the next cycle,
	#	else display IP address after end of cycle
	#
	if [ ${i} -lt ${j} ]; then
		(( i++ ))
	else
		${suiddir}/lcdwrite -f -1 "Local IP Address" -2 "${ipaddr}"
		(( i=1 ))	# Restart at first target
	fi

	#
	# Obtain and prepend end time (date/time/tz) to CSV record
	#
	datetime="$(date +%Y-%m-%d,%H:%M:%S,%Z)"
	hdr="Date,Time,Timezone,${hdr}"
	csv="${datetime},${csv}"

	#
	# Output latest test results
	#
	cp ${fplog} ${csvdir}/${resfile}

	#
	# Add CSV record to daily file
	#
	csvfile="${csvdir}/NetMonitor_${datetime%%,*}_${ipaddr//[.:]/-}.csv"
	if [ ! -s ${csvfile} ]; then
		echo "${hdr}" >${csvfile}		# Initialize new file with header if needed
	fi
	echo "${csv}" >>${csvfile}

	#
	# Add CSV record to event summary if event detected
	#
	csumfile="${csvdir}/${sumfile}"			# Complete event summary file
	if [ ${sumevent} -eq 1 ]; then
		if [ ! -s ${csumfile} ]; then
			echo "${hdr}" >${csumfile}	# Initialize new file with header if needed
		fi
		echo "${csv}" >>${csumfile}
	fi

	#
	# Remove old CSV files to maintain storage
	#
	find ${csvdir} -name '*.csv' -type f -mtime +30 -exec rm -f {} ';'
done
#
