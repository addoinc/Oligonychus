use strict;
use warnings;

package spiderrdx_vars;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(
	$abort %script_url_counter %skipped_urls %skip_url_patterns %validated
	%db_visited %visited %bad_links $visited_size $moved_visited_todb %sid_map
);

our $VERSION = 0.01;

use vars qw(
	$abort %script_url_counter %skipped_urls %skip_url_patterns %validated
	%db_visited %visited %bad_links $visited_size $moved_visited_todb %sid_map
);

1;
