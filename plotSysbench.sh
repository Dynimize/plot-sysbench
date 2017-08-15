#!/bin/bash -x 

#This script is meant to be run with Sysbench 1.0

#Set the following 6 variables as required, and maybe also change $test if 
#necesary.
###########################################
tableSize=1000000
numTables=10
pwd='password'
dbName='test'
user="root"
#readOnly="on"
readOnly="on"
measureTime=60
warmupIncrementTime=30
events="true" #Requires PMU enablement and perf to be installed and working
#events="false"
pathToLuas="/usr/share/sysbench/tests/include/oltp_legacy" #Relative path to lua scripts 
#cpuUsage="true"
cpuUsage="false"
useTaskSet="false"
#useTaskSet="true"
#power="true" 	#Measuring power requires a 
		#laptop with discharging battery. Requires minumum measureTime
		#of 30 to work properly. Must also turn off system 
		#sleep/hibernate/suspend and screen dimming when idle and running on battery.
power="false"
###########################################

oltpTest="$pathToLuas/oltp.lua"

oltp_simpleTest="$pathToLuas/oltp_simple.lua"

deleteTest="$pathToLuas/delete.lua"

insertTest="$pathToLuas/insert.lua"

selectTest="$pathToLuas/select.lua"

select_random_pointsTest="$pathToLuas/select_random_points.lua"

select_random_rangesTest="$pathToLuas/select_random_ranges.lua"

update_indexTest="$pathToLuas/update_index.lua"

update_non_indexTest="$pathToLuas/update_non_index.lua"

parallel_prepare="$pathToLuas/parallel_prepare.lua"


#Hadware performance events for perf tool, either as aliases or if not available 
#then raw values. Raw values need to be adapted for each processor family
cycles="cycles"
instructions="instructions"
icacheMisses="r0280"
#icacheMisses="L1-icache-load-misses"
instructionFetches="r0380"
itlbMisses="r0185"
#itlbMisses="iTLB-load-misses"
condBranchMiss="r00C5"
#condBranchMiss="branch-misses"
condBranch="r01C4"
#condBranch="branches"


#To fully measure the speedup alloted to the mysqld process, we need to pin it
#to seperate CPU cores from the sysbench process. Otherwise, if we only dynimize
#mysqld, we are making sybench work harder to keep up with a faster mysqld,
#making sysbench steal more cpu cycles away from mysqld, thereby masking the
#visible speedup. Alternatively you can try dynimizing the sysbench process as
#well, and seeing the final throughput when running with --report-interval=10.
#Note the option --report-interval is not available with all versions of
#sysbench. 
numCPUs=$(cat /proc/cpuinfo | grep -cP "^processor\t:")
lessTime=$(($measureTime-5))

sysbenchTaskset=""

function tasksetVars
	{
	if [ $useTaskSet = "true" ]; then
		#Split physical system cores in half.
		#mysqld will get one half, sysbench the other half.
		#Get logical core ID ranges for each half. 
		#Assumes 2 logical cores per physical.
		#To better understand see /proc/cpuinfo 
		#"processor" and "core id" values.
		rangeInc=$(($numCPUs/4))
		range0Start=0
		range0End=$(($range0Start+$rangeInc-1))
		range1Start=$((range0Start+$numCPUs/2))
		range1End=$(($range1Start+$rangeInc-1))
		mysqldCPUMask="$range0Start-$range0End,$range1Start-$range1End"

		echo mysqld CPU mask will be $mysqldCPUMask
	
		range0Start=$(($range0Start+$rangeInc))	
		range1Start=$(($range1Start+$rangeInc))
		range0End=$(($range0End+$rangeInc))
		range1End=$(($range1End+$rangeInc))
		sysbenchTaskset="taskset -c $range0Start-$range0End,$range1Start-$range1End"

		echo sysbench taskset command will be $sysbenchTaskset
	fi
	}

function monitorPower
	{
	monitorTime=$1
	i=0
	total=0

	while [ $i -le $monitorTime ]
		do
		sleep 1
		volts=`cat /sys/class/power_supply/BAT0/voltage_now`
		amps=`cat /sys/class/power_supply/BAT0/current_now`
		volts=$(($volts/1000)) #convert uV to mV
		amps=$(($amps/1000)) #convert uA to mA
		watts=$(($amps*$volts))
		total=$(($total+$watts))
		i=$(($i+1))
		done	 

	avgPower=$(($total/$monitorTime))
	echo $avgPower > avgPower 
	}

function initPowerBaseline
        {
	if [ $power = "true" ]; then	
		monitorPower $(($measureTime-5))
		cat avgPower > powerBaselineOne.csv
	fi
        }

function checkDyniIsRunning
	{
	sleep 1
	dyni -status | grep "Dynimizer is running" > /dev/null 2>&1 
	}

function checkMysqldIsDynimized
	{
	sleep 1
	pid=`pidof mysqld`
	dyni -status | grep "mysqld, pid: $pid, dynimized" > /dev/null 2>&1 
	}

#Warmup run with enough time to get the mysqld process fully dynimized.
#If run with dyni on, then track how many warmup iterations it takes to get 
#mysqld dynimized, save value in warmupCount. If run with dyni off, then 
#only run as many iterations as warmuoCount. This is why dyni on should be 
#run before dyni off, so we can calibrate warmuoCount for each test. This
#allows for idential warmup times for each dyni on/off test pair.
#We don't need to use this auto-tuned warmup. We could have been conservative
#and just used a long fixed warmup time, however this dynamic approach takes 
#less time
function warmup
	{
	echo Performing warmup...
  	checkDyniIsRunning

	if [ $? = 0 ]; then
		warmupCount=0
		dynimizing=true
	fi

	keepRunning=true
	count=0
	
	while [ $count -lt $warmupCount ] || [ $warmupCount -eq 0 ]
		do
		count=$(($count+1))

        	sysbench $test \
                	--oltp-table-size=$tableSize \
			--oltp-tables-count=$numTables \
                	--mysql-db=$dbName \
                	--mysql-user=$user \
                	--mysql-password=$pwd \
                	--time=$warmupIncrementTime \
                	--oltp-read-only=$readOnly \
                	--max-requests=0 \
                	--threads=32 \
			--db-driver=mysql \
                	run > /dev/null 2>&1

		if [ $dynimizing = true ]; then
			checkMysqldIsDynimized

			if [ $? = 0 ]; then
				warmupCount=$count	
			fi
		fi
		
		done
	}

function prepare
	{
        service mysqld restart
        service mysql restart
        renice -20 `pidof mysqld`

        if [ $useTaskSet = "true" ]; then
                taskset -c -p $mysqldCPUMask `pidof mysqld`
        fi

        mysql -u $user --password=$pwd -e "DROP DATABASE $dbName;"
        mysql -u $user --password=$pwd -e "CREATE DATABASE $dbName;"

        sysbench $parallel_prepare \
                --num-threads=$numCPUs \
                --oltp-table-size=$tableSize \
                --oltp-tables-count=$numTables \
                --mysql-db=$dbName \
                --mysql-user=$user \
                --mysql-password=$pwd \
                --db-driver=mysql \
                prepare
	}

function run 
	{
	prefix=$1

	powerLog=$prefix-power.log
	eventsLog=$prefix-events.log
	cpuUsageLog=$prefix-cpuUsage.log
	sysbenchLog=$prefix.log

	powerCsv=$prefix-power.csv	
	eventsCsv=$prefix-events.csv
	cpuUsageCsv=$prefix-cpuUsage.csv
	sysbenchCsv=$prefix.csv

	rm -f $powerLog $eventsLog $cpuUsageLog $sysbenchLog 
	rm -f $powerCsv $eventsCsv $cpuUsageCsv $sysbenchCsv powerBaseline.csv

	warmup

	for i in 1 2 4 8 16 32 64 128; do 
#	for i in 16; do
		echo run sysbench with --threads=$i for $prefix 

		dyni -status

        	if [ $events = "true" ]; then
        		echo threads:$i >> $eventsLog 2>&1

        		perf stat -e \
$instructions,$cycles,$icacheMisses,\
$instructionFetches,$itlbMisses,$condBranchMiss,\
$condBranch -p `pidof mysqld` \
sleep $lessTime >> $eventsLog 2>&1 &

        	fi

		if [ $cpuUsage = "true" ]; then
			echo threads:$i >> $cpuUsageLog 2>&1

			top -b -d $lessTime -n 2 -p`pidof mysqld` >> \
				$cpuUsageLog 2>&1 &				
		fi

		#To get a more accurate power reading, consume power at a
		#steady state for a period of time, then start measuring and 
		#consuming power at that rate. Othewise there will be cross 
		#contamination between power consumption rates at different 
		#thread counts, along with the warmup.

             	if [ $power = "true" ]; then
                       (sleep 5 ; monitorPower $(($measureTime-10))) & 
               	fi

		$sysbenchTaskset sysbench \
		--test=$test \
                --oltp-table-size=$tableSize \
                --oltp-tables-count=$numTables \
		--mysql-db=$dbName \
		--mysql-user=$user \
		--mysql-password=$pwd \
		--time=$measureTime \
		--oltp-read-only=$readOnly \
		--max-requests=0 \
		--threads=$i \
		--db-driver=mysql \
		run >> $sysbenchLog 

	        if [ $power = "true" ]; then
        	        echo "threads:$i " >> $powerLog
                	cat avgPower >> $powerLog
			cat powerBaselineOne.csv >> powerBaseline.csv
        	fi

	done

	awkCmd="{if(NR>1){print \$1 \"\t\" \$2/$measureTime}}"

	cat $sysbenchLog | \
		egrep "threads:|total number of events:" | \
		tr -d "\n" | \
		sed 's/Number of threads: /\n/g' | \
		sed "s/total number of events://g" | \
		awk "$awkCmd" > $sysbenchCsv 

	if [ $events = "true" ]; then
		cat $eventsLog | \
		egrep "threads:|$instructions|$cycles|$icacheMisses|$instructionFetches|$itlbMisses|$condBranchMiss|$condBranch" |  \
		sed "s/ $instructions.*$//g" | \
		sed "s/ $cycles.*$//g" | \
		sed "s/ $icacheMisses.*$//g" | \
		sed "s/ $instructionFetches.*$//g"| \
		sed "s/ $itlbMisses.*$//g" | \
		sed "s/ $condBranchMiss.*$//g" | \
		sed "s/ $condBranch.*$//g" | \
		tr -d "," | \
		tr -d "\n" | \
		sed 's/threads:/\n/g' | \
		awk {'if(NR>1) {print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 "\t" $7 "\t" $8}'} \
		> $eventsCsv
	fi
 
	if [ $cpuUsage = "true" ]; then
		cat $cpuUsageLog | \
                sed -e '/threads:/{n;N;N;N;N;N;N;N;N;N;N;N;N;N;N;N;d}' | \
                tr "\n" " " | \
                sed -e 's/threads:/\n/g' | \
                awk {'if(NR>1) {print $1 "\t" $10}'} \
		> $cpuUsageCsv    
	fi

	if [ $power = "true" ]; then
        	cat $powerLog | \
                	tr -d "\n" | \
                	sed 's/threads:/\n/g' | \
                	awk {'if(NR>1) {print $1 "\t" $2}'} >> $powerCsv
	fi
	}

function plotConsolidated
	{
        gnuplot consolidateSysbenchGraph

        if [ $events = "true" ]; then
                gnuplot consolidateEventsGraph
        fi
	}

function runAndPlot 
	{
	test=$1
	name=$2

	echo RUN WITH DYNIMIZER
	prepare
	dyni -start
	run dyni $test $name
	dyni -stop

        echo RUN WITHOUT DYNIMIZER
	prepare
        run noDyni $test $name

	echo plotting results .svg files
	gnuplot sysbenchGraph

	if [ $events = "true" ]; then
		gnuplot eventsGraph 
	fi

	if [ $cpuUsage = "true" ]; then
		gnuplot cpuUsageGraph
	fi

        if [ $power = "true" ]; then
                gnuplot powerGraph
        fi

	#rename files for specific test name
	mv dyni.log dyni-$name.log > /dev/null 2>&1 
	mv noDyni.log noDyni-$name.log > /dev/null 2>&1 
	mv dyni-events.log dyni-events-$name.log > /dev/null 2>&1 
	mv noDyni-events.log noDyni-events-$name.log > /dev/null 2>&1 
        mv dyni-cpuUsage.log dyni-cpuUsage-$name.log > /dev/null 2>&1 
        mv noDyni-cpuUsage.log noDyni-cpuUsage-$name.log > /dev/null 2>&1 
	mv dyni-power.log dyni-power-$name.log > /dev/null 2>&1 
        mv noDyni-power.log noDyni-power-$name.log > /dev/null 2>&1 

	cp dyni.csv dyni-$name.csv > /dev/null 2>&1 
	cp noDyni.csv noDyni-$name.csv > /dev/null 2>&1 
	cp dyni-events.csv dyni-events-$name.csv > /dev/null 2>&1 
	cp noDyni-events.csv noDyni-events-$name.csv > /dev/null 2>&1 
        cp dyni-cpuUsage.csv dyni-cpuUsage-$name.csv > /dev/null 2>&1 
        cp noDyni-cpuUsage.csv noDyni-cpuUsage-$name.csv > /dev/null 2>&1 
	cp dyni-power.csv dyni-power-$name.csv > /dev/null 2>&1 
        cp noDyni-power.csv noDyni-power-$name.csv > /dev/null 2>&1 

	mv throughput.svg throughput-$name.svg > /dev/null 2>&1 

        mv IPC.svg IPC-$name.svg > /dev/null 2>&1
        mv branchMisses.svg branchMisses-$name.svg > /dev/null 2>&1
        mv icacheMisses.svg icacheMisses-$name.svg > /dev/null 2>&1
        mv itlbMisses.svg itlbMisses-$name.svg > /dev/null 2>&1
	mv transactionsPerCycle.svg transactionsPerCycle-$name.svg > /dev/null 2>&1

	mv cpuUsage.svg cpuUsage-$name.svg > /dev/null 2>&1 
	mv cpuUsageRelativeChange.svg cpuUsageRelativeChange-$name.svg > /dev/null 2>&1 
	mv cpuUsageAbsoluteChange.svg cpuUsageAbsoluteChange-$name.svg > /dev/null 2>&1 

        mv power.svg power-$name.svg > /dev/null 2>&1 
	mv powerTotalRelativeChange.svg powerTotalRelativeChange-$name.svg > /dev/null 2>&1 
	mv powerTotalAbsoluteChange.svg powerTotalAbsoluteChange-$name.svg > /dev/null 2>&1 
	mv powerIsolateRelativeChange.svg powerIsolateRelativeChange-$name.svg > /dev/null 2>&1 
	sleep 60
	}

function replotGraphs 
        {
        test=$1
        name=$2

        cp dyni-$name.csv dyni.csv  > /dev/null 2>&1
        cp noDyni-$name.csv noDyni.csv  > /dev/null 2>&1
        cp dyni-events-$name.csv dyni-events.csv  > /dev/null 2>&1
        cp noDyni-events-$name.csv noDyni-events.csv  > /dev/null 2>&1
        cp dyni-cpuUsage-$name.csv dyni-cpuUsage.csv  > /dev/null 2>&1
        cp noDyni-cpuUsage-$name.csv noDyni-cpuUsage.csv  > /dev/null 2>&1
        cp dyni-power-$name.csv dyni-power.csv  > /dev/null 2>&1
        cp noDyni-power-$name.csv noDyni-power.csv  > /dev/null 2>&1

        echo plotting results .svg files
        gnuplot sysbenchGraph

        if [ $events = "true" ]; then
                gnuplot eventsGraph
        fi

        if [ $cpuUsage = "true" ]; then
                gnuplot cpuUsageGraph
        fi

        if [ $power = "true" ]; then
                gnuplot powerGraph
        fi
     
        mv throughput.svg throughput-$name.svg > /dev/null 2>&1

        mv IPC.svg IPC-$name.svg > /dev/null 2>&1
        mv branchMisses.svg branchMisses-$name.svg > /dev/null 2>&1
        mv icacheMisses.svg icacheMisses-$name.svg > /dev/null 2>&1
        mv itlbMisses.svg itlbMisses-$name.svg > /dev/null 2>&1
        mv transactionsPerCycle.svg transactionsPerCycle-$name.svg > /dev/null 2>&1

        mv cpuUsage.svg cpuUsage-$name.svg > /dev/null 2>&1
        mv cpuUsageRelativeChange.svg cpuUsageRelativeChange-$name.svg > /dev/null 2>&1
        mv cpuUsageAbsoluteChange.svg cpuUsageAbsoluteChange-$name.svg > /dev/null 2>&1

        mv power.svg power-$name.svg > /dev/null 2>&1
        mv powerTotalRelativeChange.svg powerTotalRelativeChange-$name.svg > /dev/null 2>&1
        mv powerTotalAbsoluteChange.svg powerTotalAbsoluteChange-$name.svg > /dev/null 2>&1
        mv powerIsolateRelativeChange.svg powerIsolateRelativeChange-$name.svg > /dev/null 2>&1
        }

dyni -stop
tasksetVars
initPowerBaseline
#runAndPlot $oltpTest oltp
#runAndPlot $oltp_simpleTest oltp_simple
#runAndPlot $selectTest select
#runAndPlot $select_random_pointsTest select_random_points
#runAndPlot $select_random_rangesTest select_random_ranges

#The following tests can be I/O bound on some systems. If that is the case
#it will take a very long time for them to dynimize. 
#The delete.lua benchmark can be CPU bound if run with a very small table size.

#runAndPlot $deleteTest delete
#runAndPlot $insertTest insert
#runAndPlot $update_indexTest update_index
#runAndPlot $update_non_indexTest update_non_index

replotGraphs $oltpTest oltp
replotGraphs $oltp_simpleTest oltp_simple
replotGraphs $selectTest select
#replotGraphs $select_random_pointsTest select_random_points
replotGraphs $select_random_rangesTest select_random_ranges

plotConsolidated
