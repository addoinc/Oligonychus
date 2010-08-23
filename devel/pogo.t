#!/usr/bin/perl
use strict;
use warnings;

# Total number of tests
use Test::More tests => 6;

BEGIN {
        if ( -e $ENV{OLIGONYCHUS_HOME} && -d $ENV{OLIGONYCHUS_HOME} ) {
                unshift(@INC, "$ENV{OLIGONYCHUS_HOME}/lib/");
                unshift(@INC, "$ENV{OLIGONYCHUS_HOME}/conf/");
        } else {
                print "Error(1): Environment variable OLIGONYCHUS_HOME incorrect/not set.\n";
        }

        ## FIRST TEST
        use_ok( 'TvgagaConf', qw($config $bot_conf) );
        use_ok('AzriSpider');
        use_ok('ParserFactory');
};

## THIRD TEST
sub ok_pogo() {
        my $ret = $config->{ 'Pogo' }->{'get_params'}->();
        foreach my $set ( @{ $ret } ) {
               print $set->{'qstr'}, " : ", $set->{'outf'}, " : ",  $set->{'args'}->[1], "\n";
        }
        print "Total urls returns: ", scalar( @{ $ret } ), "\n";
        return scalar( @{ $ret } );
};
 ok(ok_pogo, "Pogo");


sub ok_spider {

        my $ret_con = shift;
        $ret_con ||= 0;
        my $ret = $config->{ 'Pogo' }->{'get_params'}->();
        my $content = '';
        my $err = AzriSpider::spider(
                config => $bot_conf,
                url => $config->{'Pogo'}->{'schedules_url'} . $ret->[0]->{'qstr'},
                content => \$content,
        );

        if ( $err ) {
                print "Error spidering Pogo : ", $content, "\n";
                return 0;
        }

        #print $content, "\n";
        unless ( $ret_con ) {
                print "Content Length: ", length($content), "\n";
                return length( $content );
        } else {
                return $content;
        }
};
ok(ok_spider, 'spider');


sub ok_parse() {
      my $con = ok_spider(1);

      my $ret = $config->{ 'Pogo' }->{'get_params'}->();

        my $out_file = "$ENV{OLIGONYCHUS_HOME}/devel/data/";
        $out_file .= $config->{ 'Pogo' }->{'schedules_csv'};

        if ( $ret->[0]->{'outf'} ) {
                $out_file = "$ENV{OLIGONYCHUS_HOME}/devel/data/";
                $out_file .= $ret->[0]->{'outf'} . $config->{ 'Pogo' }->{'schedules_csv'};
        }

        my $parser = ParserFactory::get_parser(
                channel => 'Pogo',
                schedules_csv => $out_file,
                args => $ret->[0]->{'args'},
        );
        unless ( $parser->isa('AzParser::ParsePogo') ) {
                print "Parser factory error!\n";
                return 0;
        }

        # pass content to appropriate site parser module
        $parser->parse( $con );
        $parser->eof;
        $parser->done();
        return 1;
};
ok(ok_parse, 'parse');