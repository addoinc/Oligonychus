#!/usr/bin/ksh

export OLIGONYCHUS_HOME=/home/mrblue/perl/oligonychus

for sched_file in $OLIGONYCHUS_HOME/data/*.csv;
do
	$OLIGONYCHUS_HOME/bin/load_schedules.pl -file $sched_file
done
