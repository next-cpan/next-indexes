#!/usr/bin/env perl

package UpdateIndex;

use strict;
use warnings;

use Test::More; # for debugging

use FindBin;

BEGIN {
    unshift @INC, $FindBin::Bin . "/vendor/lib";
}

use Moose;
with 'MooseX::SimpleConfig';
with 'MooseX::Getopt';

use experimental 'signatures';

use LWP::UserAgent     ();
use File::Basename     ();
use CPAN::Meta::YAML   ();
use CPAN::DistnameInfo ();
use version            ();
use Net::GitHub::V3;

BEGIN {
    $Net::GitHub::V3::Orgs::VERSION == '2.0' or die("Need custom version of Net::GitHub::V3::Orgs to work!");
}

use YAML::Syck   ();
use Git::Wrapper ();

use Parallel::ForkManager  ();
use IO::Uncompress::Gunzip ();
use Data::Dumper;

# settings.ini
has 'base_dir'     => ( isa => 'Str', is => 'ro', required => 1, documentation => 'REQUIRED - The base directory where our data is stored.' );                     # = /root/projects/pause-monitor
has 'github_user'  => ( isa => 'Str', is => 'ro', required => 1, documentation => q{REQUIRED - The github username we'll use to create and update repos.} );       # = pause-parser
has 'github_token' => ( isa => 'Str', is => 'ro', required => 1, documentation => q{REQUIRED - The token we'll use to authenticate.} );
has 'github_org'   => ( isa => 'Str', is => 'ro', required => 1, documentation => q{REQUIRED - The github organization we'll be creating/updating repos in.} );    # = pause-play
has 'repo_user_name' => ( isa => 'Str', is => 'ro', required => 1, documentation => 'The name that will be on commits for this repo.' );
has 'repo_email'     => ( isa => 'Str', is => 'ro', required => 1, documentation => 'The email that will be on commits for this repo.' );

has 'git_binary'   => ( isa => 'Str',  is => 'ro', lazy => 1, default => '/usr/bin/git', documentation => 'The location of the git binary that should be used.' );

has 'gh'      => ( isa => 'Object', is => 'ro', lazy => 1, default => sub { Net::GitHub::V3->new( version => 3, login => $_[0]->github_user, access_token => $_[0]->github_token ) } );
has 'gh_org'  => ( isa => 'Object', is => 'ro', lazy => 1, default => sub { $_[0]->gh->org } );
has 'gh_repo' => ( isa => 'Object', is => 'ro', lazy => 1, default => sub { $_[0]->gh->repos } );

has 'github_repos' => (
    isa     => 'HashRef',
    is      => 'rw',
    lazy    => 1,
    default => sub ($self) {
        return { map { $_->{'name'} => $_ } $self->gh_org->list_repos( $self->github_org ) };
    },
);


sub run ($self) {

    my $base_dir = $self->base_dir;

    mkdir $base_dir unless -d $base_dir;

    my $repos = $self->github_repos;
    note explain $repos;

    return 0;
}

sub DEBUG ($msg) {
    chomp $msg;
    print $msg . "\n";
    return;
}

# sub sleep_until_not_throttled ($self) {
#     my $rate_remaining;

#     $loop++;
#     my $gh = $self->gh;

#     while ( ( $rate_remaining = $gh->rate_limit_remaining() ) < 50 ) {
#         my $time_to_wait = time - $gh->rate_limit_reset() + 1;
#         $time_to_wait > 0 or die("time_remaining == $time_to_wait");
#         $time_to_wait = int( $time_to_wait / 2 );
#         DEBUG("Only $rate_remaining API queries are allowed for the next $time_to_wait seconds.");
#         DEBUG("Sleeping until we can send more API queries");
#         sleep 10;
#         $gh->update_rate_limit();
#     }

#     DEBUG( "        Rate remaining is $rate_remaining. Resets at " . $gh->rate_limit_reset() ) if $loop % 10 == 0;

#     return;
# }


package main;

my $ptgr = UpdateIndex->new_with_options( configfile => "${FindBin::Bin}/settings.ini" );

exit( $ptgr->run );

