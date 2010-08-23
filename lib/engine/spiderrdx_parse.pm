use strict;
use warnings;

use HTML::Parser;

package spiderrdx_parse;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(get_text get_title);
our $VERSION = 0.01;

# Global variables to locate HTML tags and text betweeen tags.
use vars qw($getText $textBuffer $html_tags);

use constant OK_TAG => 1;

#########################################
# get-title - Use this subroutine to get the
# title from of an HTML page.
# PARAM:
# String containing the HTML
# OUTPUT:
# The title from the HTML if found
#########################################
sub get_title {

	my $content = shift;

	my $p = HTML::TokeParser->new( \$content );
	if ($p->get_tag("title")) {
		my $de_buf = $p->get_trimmed_text;
		$de_buf = demoronise($de_buf);
		chomp $de_buf;
		return $de_buf;
	}
}

#########################################
# get-text - Use this subroutine to strip out all
# html/JS tags/code from a string. Also removes anything
# that looks like ASCII art.
# This subroutine uses three callback subroutines defined in this
# module.
# PARAM:
# String containing contents of HTML file
# OUTPUT:
# Sring that contains the text sans markup from input param.
#########################################
sub get_text {

	my $content = shift;

	undef $textBuffer;
	undef $getText;
	undef $html_tags;
	my $parser = new HTML::Parser(
		start_h => [ \&tagStart, "tagname, attr" ],
		end_h   => [ \&tagStop, "tagname" ],
		text_h  => [ \&handleText, "dtext" ],
		);
	$parser->parse($content);

	if ( !$html_tags ) {
		# If no html tags were found, then return the content as it was given
		# This might happen if we got plain text file, with content-type: text/html
		$textBuffer = $content;
	}

	#REMOVE ASCII ART#
	$textBuffer =~ s/[\s=|#@^*_-]{2,}?/ /g;
	$textBuffer =~ s/\s+/ /g;

	return $textBuffer;
};

#########################################
# tagStart - Subroutine used within this module by &get_text()
# to identify starting HTML tags
# This is a callback subroutine.
#########################################
sub tagStart {
    my ($tagname,$attr) = @_;
    if ($tagname !~ m[^script$] && $tagname !~ m[^style$]) {
	$html_tags = OK_TAG;
	$getText = OK_TAG;
    } else {
	$getText = undef;
    }
};

#########################################
# tagStop -  Subroutine used within this module by &get_text()
# to identifye ending HTML tags
# This is a callback subroutine.
#########################################
sub tagStop {   $getText = OK_TAG; }

#########################################
# handleText - Subroutine used within this module by &get_text()
# to extract text between starting and ending HTML tags.
# This is a callback subroutine.
#########################################
sub handleText {
    if ( $getText ) {
	my $de_buf = shift;

	$de_buf = demoronise($de_buf);
	$textBuffer .= " ". $de_buf;
    }
};

#########################################
#
#De-moron-ise Text from Microsoft Applications
#by John Walker -- January 1998
#http://www.fourmilab.ch/
#
# demoronise - Subroutine to replace no-ascii
# characters, that occur in text that have been
# edit/created by applications like MS Word, with
# their ASCII equivalents.
# PARAM:
# String of text that may contain non-ascii chars.
# OUTPUT:
# String of text with non-ascii chars replaced with their
# ascii equivalents
#########################################
sub demoronise {
    my($s) = @_;
    my($i, $c);

    #   Eliminate idiot MS-DOS carriage returns from line terminator

    $s =~ s/\s+$//;
    $s .= "\n";

    #   Map strategically incompatible non-ISO characters in the
    #   range 0x82 -- 0x9F into plausible substitutes where
    #   possible.

    $s =~ s/\x82/,/g;
    $s =~ s-\x83-<em>f</em>-g;
    $s =~ s/\x84/,,/g;
    $s =~ s/\x85/.../g;

    $s =~ s/\x88/^/g;
    $s =~ s-\x89- °/°°-g;

    $s =~ s/\x8B/</g;
    $s =~ s/\x8C/Oe/g;

    $s =~ s/\x91/`/g;
    $s =~ s/\x92/'/g;
    $s =~ s/\x93/"/g;
    $s =~ s/\x94/"/g;
    $s =~ s/\x95/*/g;
    $s =~ s/\x96/-/g;
    $s =~ s/\x97/--/g;
    $s =~ s-\x98-<sup>~</sup>-g;
    $s =~ s-\x99-<sup>TM</sup>-g;

    $s =~ s/\x9B/>/g;
    $s =~ s/\x9C/oe/g;

    #   Now check for any remaining untranslated characters.

    if ($s =~ m/[\x00-\x08\x10-\x1F\x80-\x9F]/) {
        for ($i = 0; $i < length($s); $i++) {
            $c = substr($s, $i, 1);
            if ($c =~ m/[\x00-\x09\x10-\x1F\x80-\x9F]/) {
                printf(STDERR  "warning--untranslated character in input line");
            }
        }
    }
    #   Supply missing semicolon at end of numeric entity if
    #   Billy's bozos left it out.

    $s =~ s/(&#[0-2]\d\d)\s/$1; /g;

    #   Fix dimbulb obscure numeric rendering of &lt; &gt; &amp;

    $s =~ s/&#038;/&amp;/g;
    $s =~ s/&#060;/&lt;/g;
    $s =~ s/&#062;/&gt;/g;

    #   Fix unquoted non-alphanumeric characters in table tags

    $s =~ s/(<TABLE\s.*)(WIDTH=)(\d+%)(\D)/$1$2"$3"$4/gi;
    $s =~ s/(<TD\s.*)(WIDTH=)(\d+%)(\D)/$1$2"$3"$4/gi;
    $s =~ s/(<TH\s.*)(WIDTH=)(\d+%)(\D)/$1$2"$3"$4/gi;

    #   Correct PowerPoint mis-nesting of tags

    $s =~ s-(<Font .*>\s*<STRONG>.*)(</FONT>\s*</STRONG>)-$1</STRONG></Font>-gi;

    #   Translate bonehead PowerPoint misuse of <UL> to achieve
    #   paragraph breaks.

    $s =~ s-<P>\s*<UL>-<p>-gi;
    $s =~ s-</UL><UL>-<p>-gi;
    $s =~ s-</UL>\s*</P>--gi;

    #   Repair PowerPoint depredations in "text-only slides"

    $s =~ s-<P></P>--gi;
    $s =~ s- <TD HEIGHT=100- <tr><TD HEIGHT=100-ig;
    $s =~ s-<LI><H2>-<H2>-ig;
    
    #	Translate Unicode numeric punctuation characters
    #	into ISO equivalents

    $s =~ s/&#8208;/-/g;    	# 0x2010 Hyphen
    $s =~ s/&#8209;/-/g;    	# 0x2011 Non-breaking hyphen
    $s =~ s/&#8211;/--/g;   	# 0x2013 En dash
    $s =~ s/&#8212;/--/g;   	# 0x2014 Em dash
    $s =~ s/&#8213;/--/g;   	# 0x2015 Horizontal bar/quotation dash
    $s =~ s/&#8214;/||/g;   	# 0x2016 Double vertical line
    $s =~ s-&#8215;-<U>_</U>-g; # 0x2017 Double low line
    $s =~ s/&#8216;/`/g;    	# 0x2018 Left single quotation mark
    $s =~ s/&#8217;/'/g;    	# 0x2019 Right single quotation mark
    $s =~ s/&#8218;/,/g;    	# 0x201A Single low-9 quotation mark
    $s =~ s/&#8219;/`/g;    	# 0x201B Single high-reversed-9 quotation mark
    $s =~ s/&#8220;/"/g;    	# 0x201C Left double quotation mark
    $s =~ s/&#8221;/"/g;    	# 0x201D Right double quotation mark
    $s =~ s/&#8222;/,,/g;    	# 0x201E Double low-9 quotation mark
    $s =~ s/&#8223;/"/g;    	# 0x201F Double high-reversed-9 quotation mark
    $s =~ s/&#8226;/&#183;/g;  	# 0x2022 Bullet
    $s =~ s/&#8227;/&#183;/g;  	# 0x2023 Triangular bullet
    $s =~ s/&#8228;/&#183;/g;  	# 0x2024 One dot leader
    $s =~ s/&#8229;/../g;  	# 0x2026 Two dot leader
    $s =~ s/&#8230;/.../g;  	# 0x2026 Horizontal ellipsis
    $s =~ s/&#8231;/&#183;/g;  	# 0x2027 Hyphenation point

    return $s;
};

1;
