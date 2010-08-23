use strict;
use warnings;

package spiderrdx_config;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw( $spiderrdx_config );
our $VERSION = 0.01;

our $spiderrdx_config = {
	log_location => "$ENV{OLIGONYCHUS_HOME}/log/",
	spider_cache_location => "$ENV{OLIGONYCHUS_HOME}/cache/",
	max_visited_size => 10000,
};

1;
