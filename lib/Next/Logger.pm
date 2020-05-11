package Next::Logger;    # stolen from App::cpm::Logger

use Next::std;

use List::Util 'max';

use Exporter 'import';

$| = 1;

our @EXPORT    = qw{INFO OK DEBUG ERROR};
our @EXPORT_OK = (@EXPORT);

our $LOG_WITH_TIMESTAMP = 1;
our $LOG_ENABLE_DEBUG   = 1;
our $QUIET              = 0;

sub _log(@args) {
    return if $QUIET;

    my $header;

    if ($LOG_WITH_TIMESTAMP) {
        my $dt = DateTime->now;
        my $ts = $dt->ymd . ' ' . $dt->hms;
        $header = "[${ts}]";
    }

    unshift @args, $header if defined $header;

    my $msg = join( ' ', grep { defined $_ } @args );
    chomp $msg;
    $msg .= "\n";

    print STDERR $msg;
    ### .. log to an error file

    return $msg;
}

use constant COLOR_RED    => 31;
use constant COLOR_GREEN  => 32;
use constant COLOR_YELLOW => 33;
use constant COLOR_BLUE   => 34;
use constant COLOR_PURPLE => 35;
use constant COLOR_CYAN   => 36;
use constant COLOR_WHITE  => 7;

sub _with_color ( $color, $txt ) {
    return "\e[${color}m$txt\e[m";
}

sub TAG_with_color ( $tag, $color ) {
    return '[' . _with_color( $color, $tag ) . ']';
}

sub INFO (@what) {
    _log( TAG_with_color( INFO => COLOR_GREEN ), @what );
    return;
}

sub OK (@what) {
    _log( TAG_with_color( OK => COLOR_GREEN ), @what );
    return;
}

sub DEBUG (@what) {
    return unless $LOG_ENABLE_DEBUG;
    _log( TAG_with_color( DEBUG => COLOR_WHITE ), @what );
    return;
}

sub ERROR (@what) {
    _log( TAG_with_color( ERROR => COLOR_RED ), @what );
    return;
}

1;
