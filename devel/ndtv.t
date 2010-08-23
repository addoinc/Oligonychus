#!/usr/bin/perl
use strict;
use warnings;

# Total number of tests
use Test::More tests => 9;

BEGIN {
	if ( -e $ENV{OLIGONYCHUS_HOME} && -d $ENV{OLIGONYCHUS_HOME} ) {
		unshift(@INC, "$ENV{OLIGONYCHUS_HOME}/lib/");
		unshift(@INC, "$ENV{OLIGONYCHUS_HOME}/conf/");
	} else {
		print "Error(1): Environment variable OLIGONYCHUS_HOME incorrect/not set.\n";
	}

	## FIRST TEST
	use_ok( 'TvgagaConf', qw($config $bot_conf) );

	## FOURTH TEST
	#use_ok('AzriSpider');

	## SIXTH TEST
	#use_ok('ParserFactory');

	## 8th TEST
	#use_ok('PostTaskFactory');
};

## SECOND TEST
sub ok_chnames() {
	my @l = keys( %{$config} );
	print "Channels list: ", join(', ', @l), "\n";
	return scalar( @l );
};
#ok(ok_chnames, "channels");

## THIRD TEST
sub ok_ndtv() {
	my $ret = $config->{ 'ndtv' }->{'get_params'}->();

	foreach my $set ( @{ $ret } ) {
		print $set->{'qstr'}, " : ", $set->{'outf'}, " : ",  $set->{'args'}->[1], "\n";
	}

	print "Total urls returns: ", scalar( @{ $ret } ), "\n";
	return scalar( @{ $ret } );
};
ok(ok_ndtv, "ndtv");

# FIFTH TEST
sub ok_spider {

	my $ret_con = shift;
	$ret_con ||= 0;

	my $ret = $config->{ 'ndtv' }->{'get_params'}->();

	my $content = '';
	my $err = AzriSpider::spider(
		config => $bot_conf,
		url => $config->{'Star'}->{'schedules_url'} . $ret->[0]->{'qstr'},
		content => \$content,
	);

	if ( $err ) {
		print "Error spidering Star : ", $content, "\n";
		return 0;
	}

	print $content, "\n";
	unless ( $ret_con ) {
		print "Content Length: ", length($content), "\n";
		return length( $content );
	} else {
		return $content;
	}
};
#ok(ok_spider, 'spider');

# SEVENTH TEST
sub ok_parse() {
	my $con = ok_spider(1);

	my $ret = $config->{ 'ndtv' }->{'get_params'}->();

	my $out_file = "$ENV{OLIGONYCHUS_HOME}/devel/data/";
	$out_file .= $config->{ 'ndtv' }->{'schedules_csv'};

	if ( $ret->[0]->{'outf'} ) {
		$out_file = "$ENV{OLIGONYCHUS_HOME}/devel/data/";
		$out_file .= $ret->[0]->{'outf'} . $config->{ 'ndtv' }->{'schedules_csv'};
	}

	my $parser = ParserFactory::get_parser(
		channel => 'ndtv',
		schedules_csv => $out_file,
		args => $ret->[0]->{'args'},
	);
	unless ( $parser->isa('AzParser::ParseStar') ) {
		print "Parser factory error!\n";
		return 0;
	}

	# pass content to appropriate site parser module
	$parser->parse( $con );
	$parser->eof;
	$parser->done();

	if ( -e $out_file ) {

		my $ok = 0;

		open(CSV, $out_file);
		while( <CSV> ) {
			if ( $. == 1 ) {
				s/^\s+//g; s/\s+$//g;
				last unless ( $_ );
			}
			if ( $. > 1 && $. < 6 ) {
				my @fields = split /(?<!\\),/;

				return 0 if ( scalar(@fields) ==! 4 );
				return 0 if ( $fields[0] !~ m~\d+/\d+/\d+~ );
				return 0 if ( $fields[1] !~ m~\d+:\d+~ );

				$ok = 1;
			}
			return 1 if ( $ok);
		}
		close(CSV);

		return $ok;
	} else {
		return 0;
	}

	return 0;
};
#ok(ok_parse, 'parse');

# 9th TEST
sub ok_posttask() {

	my $ret = $config->{ 'ndtv' }->{'get_params'}->();

	my $out_file = "$ENV{OLIGONYCHUS_HOME}/devel/data/";
	$out_file .= $config->{ 'ndtv' }->{'schedules_csv'};

	if ( $ret->[0]->{'outf'} ) {
		$out_file = "$ENV{OLIGONYCHUS_HOME}/devel/data/";
		$out_file .= $ret->[0]->{'outf'} . $config->{ 'ndtv' }->{'schedules_csv'};
		#$out_file .= '_schedules.csv';
	}

	# Get a Post Parsing task object from PostTaskFactory
	my $posttask = PostTaskFactory::get_posttask(
		channel => 'ndtv',
		schedules_csv => $out_file,
	);
	unless ( $posttask->isa('AzTask::NdtvPostTask') ) {
		print "PostTask factory error!\n";
		return 0;
	}

	$posttask->do();
	$posttask->done();

	my $count = `wc -l $out_file | awk -F' ' '{print \$1}'`;
	my $last = `tail -1 $out_file | awk -F',' '{print \$2}'`;
	$count =~ s/\s+//g; $last =~ s/\s+//g;

	unless ( $count > 2 && $last eq '00:00' ) {
		return 1;
	}

	return 0;
};
#ok(ok_posttask, 'PostParseTask')
