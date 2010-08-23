package ParserFactory;

use strict;
use warnings;

our $VERSION = '0.01';

use base 'Exporter';

our @EXPORT = qw(get_parser);

use HTML::Parser;

sub get_parser {
        my %param = @_;

        my $p_obj;

        my $ch_parser_name;
        if ( $param{'channel'} eq 'HBO' ) {
                require AzParser::ParseHBO;
                $p_obj = AzParser::ParseHBO->new(
                        schedules_csv => $param{'schedules_csv'},
                        channel => $param{'channel'},
                        args => $param{'args'},
                );
                $ch_parser_name = 'AzParser::ParseHBO';
              } elsif ( $param{'channel'} eq 'Star' ) {
                require AzParser::ParseStar;
                $p_obj = AzParser::ParseStar->new(
                        schedules_csv => $param{'schedules_csv'},
                        channel => $param{'channel'},
                        args => $param{'args'},
                );
                $ch_parser_name = 'AzParser::ParseStar';
              } elsif ( $param{'channel'} eq 'Pogo' ) {
                require AzParser::ParsePogo;
                $p_obj = AzParser::ParsePogo->new(
                        schedules_csv => $param{'schedules_csv'},
                        channel => $param{'channel'},
                        args => $param{'args'},
                );
                $ch_parser_name = 'AzParser::ParsePogo';
              } else {
                $p_obj = new HTML::Parser;
              }

        no strict 'refs';
        push @{$ch_parser_name.'::ISA'}, 'HTML::Parser';
        use strict;
        return bless $p_obj, $ch_parser_name;
};

1;
