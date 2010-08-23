#!/usr/bin/perl
use strict;
use warnings;

BEGIN {
	$| = 1;

        if ( -e $ENV{OLIGONYCHUS_HOME} && -d $ENV{OLIGONYCHUS_HOME} ) {
		unshift(@INC, "$ENV{OLIGONYCHUS_HOME}/lib/engine/");
		unshift(@INC, "$ENV{OLIGONYCHUS_HOME}/conf/engine/");
	} else {
		print "Error(1): Environment variable OLIGONYCHUS_HOME incorrect/not set.\n";
		exit 1;
	}
};

use dbutils qw($dbh);
use spiderrdx_config qw( $spiderrdx_config );

use vars qw($dbh);

&dbutils::connect;
my $spider_cache_dir = $spiderrdx_config->{'spider_cache_location'};
opendir( CACHE, "$spider_cache_dir/" );
while ( my $file = readdir( CACHE ) ) {

	next if ( $file eq '.' );
	next if ( $file eq '..' );

	my $query = qq~
	select indexed_url
	from spiderrdx_indexed_urls
	where indexed_url_id = ?
	~;
	my $url = &dbutils::query(
		query => $query,
		param => [ $file ],
	);
	print "$file : $url->[0]->[0] \n";

	next if ( $url->[0]->[0] =~ m~download_file_new~ );

        open(CFILE, "<$spider_cache_dir/$file");
	my @lines = <CFILE>;
	my $lines = join("", @lines);
	close(CFILE);

	open(IFILE, ">/tmp/cache.idxf");
	print IFILE "url=" . $url->[0]->[0] . "\n";
	print IFILE "text=" . $lines . "\n";
	close(IFILE);

	## index file
	`/usr/local/bin/scriptindex /home/mrblue/perl/oligonychus/index/ /home/mrblue/perl/oligonychus/conf/omega.cnf /tmp/cache.idxf`;
}
closedir( CACHE );
&dbutils::disconnect;
