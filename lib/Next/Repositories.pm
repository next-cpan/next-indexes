package Next::Repositories;

use Next::std;

# idea use the .next directory with a flag ?
use constant INTERNAL_REPO => qw{next-indexes pause-monitor cnext};

sub is_internal ( $repository ) {
    state $_is_internal = { map { $_ => 1 } INTERNAL_REPO };

    return $_is_internal->{$repository};
}

1;
