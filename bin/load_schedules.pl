#!/usr/bin/perl
use strict;
use warnings;

use Getopt::Long;
use DBI;

my $sched_csv = '';

my $res = GetOptions(
	'file=s' => sub {
		my ($k, $v) = @_;
		unless ( -e $v && -f $v ) {
			print "Invalid file: $v\n";
	        } else {
			$sched_csv = $v;
		}
	}
);

die "No file to load!\n" unless ( $sched_csv );

my $channel_id;
my $dbh = DBI->connect(
	"dbi:mysql:tvgaga_dev2:localhost",
	'tvgaga',
	'azrihyd',
);

open(CSV, $sched_csv);
while ( <CSV> ) {

	chomp;

	if ( $. == 1 ) {

		my $getchan = $dbh->prepare(qq~
		select id from channels where name like ?
		~);
		$getchan->execute( $_ );
		($channel_id) = $getchan->fetchrow_array;

		die "Channel $_ not added to db.\n" unless ( $channel_id );

		next;
	}

	my @fields = split /(?<!\\),/;

	unless ( scalar(@fields) ) {
		next;
	}

	if ( ! $fields[0] || ! $fields[3] || ! $fields[2] || ! $fields[1] || ! $channel_id ) {
		next;
	}

	# channel_id, sched_date, duration, programname, start_time
	my $sched = $dbh->prepare(qq~
	insert into schedules(channel_id, sched_date, duration, programname, start_time)
	values (?, str_to_date( ?, '%e/%c/%Y'), ?, ?, str_to_date(?, '%H:%i'))
	~);
	$fields[2] =~ s~\\,~,~g;
	$sched->execute($channel_id, $fields[0], $fields[3], $fields[2], $fields[1]);
}

close(CSV);
